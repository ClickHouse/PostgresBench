#!/usr/bin/env bash
set -euo pipefail

# oltpbench_pgbench.sh
#
# Automates:
# 1) pgbench init (load)
# 2) run pgbench benchmark 3 times
# 3) produce a JSON file matching the minimal template discussed
#
# Each run now reports:
#   - a per-interval "timeseries" array (default 30s buckets) with tps, latency
#     avg/stddev/p95/p99, and transaction/failure counts for that window
#   - top-level whole-run metrics (tps, latency avg/stddev/p95/p99, ...) computed
#     exactly over the full per-transaction log
#
# Requirements:
# - pgbench >= 17 available in PATH
# - jq available in PATH
# - awk, psql available in PATH

############################
# Config (edit as needed)
############################
SYSTEM_NAME=${SYSTEM_NAME:-"ClickHouse Managed Postgres ☁️ (aws)"}
INSTANCE_TYPE=${INSTANCE_TYPE:-"m6id.4xlarge"}   # e.g. "m6id.4xlarge", "Serverless"
VCPUS=${VCPUS:?VCPUS is required (e.g. VCPUS=16)}
RAM_GB=${RAM_GB:?RAM_GB is required (e.g. RAM_GB=64)}
INSTANCE_STORAGE=${INSTANCE_STORAGE:-"950 GB - NVMe"}  # e.g. "950 GB - NVMe"; leave empty ("") for serverless/N/A
PRIMARY_STORAGE=${PRIMARY_STORAGE:-"NVMe"}             # e.g. "NVMe", "1000 GB - GP3 (16K IOPS)", "Aurora storage"; leave empty ("") for N/A
CLUSTER_SIZE=${CLUSTER_SIZE:-1}
TUNED=${TUNED:-"no"}
COMMENT=${COMMENT:-""}
CLOUD=${CLOUD:-"aws"}
REGION=${REGION:-"us-east-2"}

# High-availability configuration (recorded in output for comparison)
#   STANDBYS   number of standby replicas (0 = No HA)
#   HA_MODE    replication mode. One of:
#                off   -> No HA (no standby; implies STANDBYS=0)
#                async -> asynchronous replication (primary does not wait for
#                         standby ack; equivalent to synchronous_commit=off/local)
#                sync  -> synchronous replication (primary waits for standby ack;
#                         equivalent to synchronous_commit=on/remote_apply/...)
#              These are recorded as metadata; provisioning the standbys and
#              setting synchronous_commit on the server is done per-vendor
#              before pointing this script at the endpoint.
STANDBYS=${STANDBYS:-0}
HA_MODE=${HA_MODE:-"off"}

# Connection
PGHOST=${PGHOST:-"localhost"}
PGPORT=${PGPORT:-5432}
PGUSER=${PGUSER:-postgres}
PGPASSWORD=${PGPASSWORD:-""}
PGDATABASE=${PGDATABASE:-postgres}

# Benchmark parameters
SCALE_FACTOR=${SCALE_FACTOR:-6849}
CLIENTS=${CLIENTS:-256}
THREADS=${THREADS:-16}
DURATION=${DURATION:-600}
QUERY_MODE=${QUERY_MODE:-prepared}
PROGRESS_SECONDS=${PROGRESS_SECONDS:-30}
# Width (seconds) of each timeseries bucket. Defaults to the progress interval.
INTERVAL_SECONDS=${INTERVAL_SECONDS:-$PROGRESS_SECONDS}

# Output
OUT_JSON=${OUT_JSON:-"oltpbench_result.json"}
WORKDIR=${WORKDIR:-"./oltpbench_tmp"}

# Transaction logs are isolated in a timestamped subdirectory so repeated runs
# (with different OUT_JSON names) never overwrite each other's raw log files.
RUN_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TXLOG_DIR="$WORKDIR/txlogs_${RUN_TIMESTAMP}"

############################
# Derived commands
############################
INIT_CMD=(pgbench -i -s "$SCALE_FACTOR" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
RUN_CMD=(pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -M "$QUERY_MODE" -P "$PROGRESS_SECONDS"
         -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE"
         -l)

mkdir -p "$WORKDIR"
mkdir -p "$TXLOG_DIR"

############################
# Helpers
############################
die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_cmd pgbench
need_cmd jq
need_cmd awk
need_cmd psql

# ISO date (UTC is fine for reporting)
DATE_STR=$(date +"%Y-%m-%d")

############################
# Validate HA config + derive label
############################
HA_MODE=$(printf '%s' "$HA_MODE" | tr '[:upper:]' '[:lower:]')
case "$HA_MODE" in
  off|async|sync) ;;
  *) die "HA_MODE must be one of: off, async, sync (got '$HA_MODE')" ;;
esac

# Reconcile HA_MODE with STANDBYS so the two can't disagree.
if [ "$HA_MODE" = "off" ]; then
  if [ "$STANDBYS" -ne 0 ]; then
    echo "Note: HA_MODE=off implies no standby; overriding STANDBYS=$STANDBYS -> 0."
    STANDBYS=0
  fi
  HA_LABEL="No HA"
else
  if [ "$STANDBYS" -le 0 ]; then
    die "HA_MODE=$HA_MODE requires STANDBYS>=1 (got STANDBYS=$STANDBYS)"
  fi
  if [ "$STANDBYS" -eq 1 ]; then
    HA_LABEL="HA – 1 standby – $HA_MODE"
  else
    HA_LABEL="HA – $STANDBYS standbys – $HA_MODE"
  fi
fi
echo "HA:     $HA_LABEL (mode=$HA_MODE, standbys=$STANDBYS)"

############################
# Get Postgres version + live replication settings
############################
echo "== Detecting Postgres version =="
PG_VERSION=$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -c "SHOW server_version;" | xargs)
if [ -z "$PG_VERSION" ]; then
  die "Failed to detect Postgres version"
fi
echo "Postgres version: $PG_VERSION"

# Capture the actual server-side replication settings so the result records the
# HA config that was really in effect (not just what was passed to this script).
# synchronous_standby_names is commonly empty (no sync standbys) — that empty
# value is meaningful and preserved as null in the JSON.
echo "== Capturing live replication settings =="
SC_LIVE=$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -A -c "SHOW synchronous_commit;" 2>/dev/null | head -n1 | xargs)
SSN_LIVE=$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -A -c "SHOW synchronous_standby_names;" 2>/dev/null | head -n1)
# Trim only surrounding whitespace; keep internal content verbatim.
SSN_LIVE=$(printf '%s' "$SSN_LIVE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
echo "synchronous_commit: ${SC_LIVE:-<unknown>}"
echo "synchronous_standby_names: ${SSN_LIVE:-<empty>}"
echo

echo "== OLTPBench pgbench automation =="
echo "Target: ${PGHOST}:${PGPORT} db=${PGDATABASE} user=${PGUSER}"
echo "Init:   ${INIT_CMD[*]}"
echo "Run:    ${RUN_CMD[*]}"
echo "Runs:   3"
echo "Timeseries bucket: ${INTERVAL_SECONDS}s"
echo

############################
# 1) Init (load) and time it
############################
echo "== Initializing database (pgbench -i) =="
INIT_LOG="$WORKDIR/init.log"
LOAD_START=$(date +%s%N)
PGPASSWORD="$PGPASSWORD" "${INIT_CMD[@]}" | tee "$INIT_LOG"
LOAD_END=$(date +%s%N)
LOAD_TIME_SECONDS=$(awk "BEGIN {printf \"%.3f\", ($LOAD_END - $LOAD_START) / 1e9}")
echo "Load time: ${LOAD_TIME_SECONDS}s"
echo

############################
# 2) Run benchmark 3 times
############################
# pgbench needs ~1 fd per client + 1 per thread log file; raise the limit to be safe.
ulimit -n 4096 2>/dev/null || echo "Warning: could not raise open-file limit (ulimit -n 4096); proceeding anyway."

RUN_JSONS=()
for i in 1 2 3; do
  echo "== Run #$i (output -> $WORKDIR/run_${i}.log) =="
  LOG="$WORKDIR/run_${i}.log"
  TXLOG_PREFIX="$TXLOG_DIR/txlog_${i}"
  PGPASSWORD="$PGPASSWORD" "${RUN_CMD[@]}" --log-prefix "$TXLOG_PREFIX" > "$LOG"

  # Parse summary-only metrics that are not derivable from the tx log.
  #   "number of failed transactions: 0 (0.000%)"  -> $5
  #   "initial connection time = ... ms"            -> $(NF-1)
  eval $(awk '
    /number of failed transactions:/ { print "FAILED="  $5  }
    /initial connection time =/      { print "CONN=" $(NF-1) }
  ' "$LOG")
  FAILED=${FAILED:-0}
  CONN=${CONN:-0}

  # --------------------------------------------------------------------------
  # Single pass over ALL thread logs ("$TXLOG_PREFIX"*) producing two things:
  #   1) per-interval buckets (timeseries)
  #   2) whole-run aggregates (exact, over the full population)
  #
  # pgbench -l log line format:
  #   client_id  tx_no  latency_us  script_no  epoch_s  epoch_us  [schedule_lag_us]
  # Buckets are keyed by floor((epoch - first_epoch) / INTERVAL), using the
  # absolute timestamp so the 16 independently-ordered thread logs align.
  #
  # Percentiles use a frequency histogram keyed by latency value: O(unique
  # latencies) memory, exact result. Per-bucket histograms are kept separately.
  # Output: first line = whole-run aggregate, following lines = one per bucket,
  # all tab-separated, consumed below by jq.
  # --------------------------------------------------------------------------
  TS_TSV="$WORKDIR/timeseries_${i}.tsv"
  awk -v interval="$INTERVAL_SECONDS" '
    function pct(arr, total, frac,   keys, n, j, cum, thresh, val) {
      # returns the latency (us) at the requested percentile of arr (hist)
      thresh = int(total * frac)
      n = asorti(arr, keys, "@ind_num_asc")
      cum = 0; val = 0
      for (j = 1; j <= n; j++) {
        cum += arr[keys[j]]
        if (cum > thresh) { val = keys[j]; break }
      }
      return val
    }
    NF >= 6 {
      lat = $3 + 0
      ts  = $5 + 0
      if (first_ts == 0 || ts < first_ts) first_ts = ts
      # whole-run accumulators (exact, over the full population)
      g_total++; g_sum += lat; g_sumsq += lat*lat; g_hist[lat]++
      # store rows so buckets can be assigned in END, once first_ts is known
      rows_lat[NR] = lat; rows_ts[NR] = ts
    }
    END {
      if (g_total == 0) { print "ERROR: no latency data" > "/dev/stderr"; exit 1 }

      # ---- whole-run aggregates ----
      # latencies are in microseconds; convert all latency outputs to ms.
      mean = (g_sum / g_total) / 1000.0
      var  = (g_sumsq / g_total) - ((g_sum / g_total) * (g_sum / g_total))
      if (var < 0) var = 0
      std  = sqrt(var) / 1000.0
      gp95 = pct(g_hist, g_total, 0.95)
      gp99 = pct(g_hist, g_total, 0.99)
      # run wall-clock span: max - min epoch (floored at 1s to avoid divide-by-zero)
      maxts = first_ts
      for (r = 1; r <= NR; r++) if (rows_ts[r] > maxts) maxts = rows_ts[r]
      span = maxts - first_ts
      if (span <= 0) span = 1
      gtps = g_total / span
      printf "RUN\t%.4f\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t%.3f\n", \
             gtps, g_total, mean, std, gp95/1000.0, gp99/1000.0, span

      # ---- per-interval buckets ----
      for (r = 1; r <= NR; r++) {
        if (rows_ts[r] == 0) continue
        b = int((rows_ts[r] - first_ts) / interval)
        bcount[b]++
        bsum[b]   += rows_lat[r]
        bsumsq[b] += rows_lat[r] * rows_lat[r]
        bhist[b SUBSEP rows_lat[r]]++
        if (b > maxb) maxb = b
      }
      for (b = 0; b <= maxb; b++) {
        c = bcount[b] + 0
        if (c == 0) {
          printf "BUCKET\t%d\t%d\t0\t0\t0\t0\t0\t0\n", b, b*interval
          continue
        }
        bmean = (bsum[b] / c) / 1000.0
        bvar  = (bsumsq[b] / c) - ((bsum[b] / c) * (bsum[b] / c))
        if (bvar < 0) bvar = 0
        bstd  = sqrt(bvar) / 1000.0
        # rebuild this bucket histogram into a local array for pct()
        delete lh
        for (k in bhist) {
          split(k, parts, SUBSEP)
          if (parts[1] == b) lh[parts[2]] = bhist[k]
        }
        bp95 = pct(lh, c, 0.95)
        bp99 = pct(lh, c, 0.99)
        btps = c / interval
        printf "BUCKET\t%d\t%d\t%.4f\t%d\t%.4f\t%.4f\t%.4f\t%.4f\n", \
               b, b*interval, btps, c, bmean, bstd, bp95/1000.0, bp99/1000.0
      }
    }
  ' "$TXLOG_PREFIX"* > "$TS_TSV"

  # Pull whole-run aggregates from the RUN line.
  read TPS TX LAT_AVG LAT_STD P95 P99 SPAN < <(
    awk -F'\t' '$1=="RUN"{print $2,$3,$4,$5,$6,$7,$8}' "$TS_TSV"
  )

  # Build the timeseries JSON array from BUCKET lines.
  TS_JSON=$(awk -F'\t' '$1=="BUCKET"{
      printf "{\"interval\":%d,\"elapsed_s\":%d,\"tps\":%s,\"transactions\":%s,\"latency_avg_ms\":%s,\"latency_stddev_ms\":%s,\"latency_p95_ms\":%s,\"latency_p99_ms\":%s}\n",
             $2,$3,$4,$5,$6,$7,$8,$9
    }' "$TS_TSV" | jq -s '.')

  echo "  TPS: $TPS  |  avg: ${LAT_AVG} ms  |  P95: ${P95} ms  |  P99: ${P99} ms  |  buckets: $(echo "$TS_JSON" | jq 'length')"
  echo

  RUN_JSONS+=("$(jq -n \
    --argjson run    "$i"       \
    --argjson tps    "$TPS"     \
    --argjson tx     "$TX"      \
    --argjson failed "$FAILED"  \
    --argjson avg    "$LAT_AVG" \
    --argjson std    "$LAT_STD" \
    --argjson conn   "$CONN"    \
    --argjson p95    "$P95"     \
    --argjson p99    "$P99"     \
    --argjson ts     "$TS_JSON" \
    --argjson interval "$INTERVAL_SECONDS" \
    '{run: $run, tps: $tps, transactions: $tx, failed_transactions: $failed,
      latency_avg_ms: $avg, latency_stddev_ms: $std,
      initial_connection_time_ms: $conn, latency_p95_ms: $p95, latency_p99_ms: $p99,
      interval_seconds: $interval, timeseries: $ts}')")
done

############################
# 3) Assemble JSON
############################
RESULTS_JSON=$(printf '%s\n' "${RUN_JSONS[@]}" | jq -s '.')

jq -n \
  --arg     system        "$SYSTEM_NAME"       \
  --arg     date          "$DATE_STR"          \
  --arg     inst_type     "$INSTANCE_TYPE"     \
  --argjson vcpus         "$VCPUS"             \
  --argjson ram_gb        "$RAM_GB"            \
  --arg     inst_storage   "$INSTANCE_STORAGE"  \
  --arg     prim_storage  "$PRIMARY_STORAGE"   \
  --argjson cluster       "$CLUSTER_SIZE"      \
  --argjson standbys      "$STANDBYS"          \
  --arg     hamode        "$HA_MODE"           \
  --arg     halabel       "$HA_LABEL"          \
  --arg     sclive        "$SC_LIVE"           \
  --arg     ssnlive       "$SSN_LIVE"          \
  --arg     tuned         "$TUNED"             \
  --arg     comment       "$COMMENT"           \
  --arg     cloud         "$CLOUD"             \
  --arg     region        "$REGION"            \
  --arg     pgver         "$PG_VERSION"        \
  --argjson scale         "$SCALE_FACTOR"      \
  --argjson clients       "$CLIENTS"           \
  --argjson threads       "$THREADS"           \
  --argjson duration      "$DURATION"          \
  --arg     qmode         "$QUERY_MODE"        \
  --argjson interval      "$INTERVAL_SECONDS"  \
  --argjson loadtime      "$LOAD_TIME_SECONDS" \
  --argjson results       "$RESULTS_JSON"      \
  '{
    system: $system, date: $date,
    instance: {
      type: $inst_type,
      vcpus: $vcpus,
      ram_gb: $ram_gb,
      instance_storage: (if $inst_storage == "" then null else $inst_storage end),
      primary_storage: (if $prim_storage == "" then null else $prim_storage end)
    },
    machine: "\($vcpus)vCPU, \($ram_gb)GB RAM",
    cluster_size: $cluster, tuned: $tuned, comment: $comment,
    cloud: $cloud,
    region: $region,
    ha: {
      label: $halabel,
      mode: $hamode,
      standbys: $standbys,
      live_settings: {
        synchronous_commit: (if $sclive == "" then null else $sclive end),
        synchronous_standby_names: (if $ssnlive == "" then null else $ssnlive end)
      }
    },
    postgres_version: $pgver,
    benchmark: {
      tool: "pgbench", workload: "TPC-B (built-in)",
      scale_factor: $scale, clients: $clients, threads: $threads,
      duration: $duration, query_mode: $qmode, interval_seconds: $interval
    },
    load: {load_time_seconds: $loadtime},
    results: $results
  }' > "$OUT_JSON"

echo "== Done =="
echo "JSON: $OUT_JSON"
