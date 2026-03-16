#!/usr/bin/env bash
set -euo pipefail

# oltpbench_pgbench.sh
#
# Automates:
# 1) pgbench init (load)
# 2) run pgbench benchmark 3 times
# 3) produce a JSON file matching the minimal template discussed
#
# Requirements:
# - pgbench >= 17 available in PATH
# - jq available in PATH
# - awk, psql available in PATH

############################
# Config (edit as needed)
############################
SYSTEM_NAME=${SYSTEM_NAME:-"Postgres by ClickHouse ☁️ (aws)"}
INSTANCE_LABEL=${INSTANCE_LABEL:-"Large"}        # e.g. "Small", "Large"
INSTANCE_TYPE=${INSTANCE_TYPE:-"m6id.4xlarge"}   # e.g. "m6id.4xlarge", "Serverless"
VCPUS=${VCPUS:?VCPUS is required (e.g. VCPUS=16)}
RAM_GB=${RAM_GB:?RAM_GB is required (e.g. RAM_GB=64)}
DISK_GB=${DISK_GB:-"950"}        # GB as integer; leave empty ("") for managed/serverless
STORAGE_TYPE=${STORAGE_TYPE:-"NVMe"}  # e.g. "NVMe", "GP3 (16K IOPS)"; leave empty ("") if unspecified
CLUSTER_SIZE=${CLUSTER_SIZE:-1}
TUNED=${TUNED:-"no"}
COMMENT=${COMMENT:-""}

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
# Get Postgres version
############################
echo "== Detecting Postgres version =="
PG_VERSION=$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -c "SHOW server_version;" | xargs)
if [ -z "$PG_VERSION" ]; then
  die "Failed to detect Postgres version"
fi
echo "Postgres version: $PG_VERSION"
echo

echo "== OLTPBench pgbench automation =="
echo "Target: ${PGHOST}:${PGPORT} db=${PGDATABASE} user=${PGUSER}"
echo "Init:   ${INIT_CMD[*]}"
echo "Run:    ${RUN_CMD[*]}"
echo "Runs:   3"
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

  # Parse summary metrics from pgbench output 
  # Field positions:
  #   "number of failed transactions: 0 (0.000%)"  -> $5  ($6 is "(0.000%)")
  #   "latency average = 12.602 ms"                -> $(NF-1)  (skip trailing "ms")
  #   "tps = 2491.4 (without initial ...)"         -> $3
  eval $(awk '
    /number of transactions actually processed:/ { print "TX="      $NF }
    /number of failed transactions:/             { print "FAILED="  $5  }
    /latency average/                            { print "LAT_AVG=" $(NF-1) }
    /latency stddev/                             { print "LAT_STD=" $(NF-1) }
    /initial connection time =/                    { print "CONN=" $(NF-1) }
    /tps =/ && /without/                         { print "TPS="     $3  }
  ' "$LOG")

  # Compute P95 and P99 from transaction log files using a streaming histogram.
  # Log format: client_id tx_no latency_us script_no epoch_s epoch_us [sched_lag_us]
  # Memory: O(unique latency values) rather than O(total transactions).
  read P95 P99 < <(awk '
    NF >= 3 { hist[$3]++; total++ }
    END {
      if (total == 0) { print "ERROR: no latency data" > "/dev/stderr"; exit 1 }
      t95 = int(total * 0.95)
      t99 = int(total * 0.99)
      n = asorti(hist, keys, "@ind_num_asc")
      cumulative = 0; p95 = 0; p99 = 0
      for (i = 1; i <= n; i++) {
        cumulative += hist[keys[i]]
        if (p95 == 0 && cumulative > t95) p95 = keys[i]
        if (cumulative > t99) { p99 = keys[i]; break }
      }
      printf "%.3f %.3f\n", p95 / 1000.0, p99 / 1000.0
    }
  ' "$TXLOG_PREFIX"*)

  echo "  TPS: $TPS  |  avg: ${LAT_AVG} ms  |  P95: ${P95} ms  |  P99: ${P99} ms"
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
    '{run: $run, tps: $tps, transactions: $tx, failed_transactions: $failed,
      latency_avg_ms: $avg, latency_stddev_ms: $std,
      initial_connection_time_ms: $conn, latency_p95_ms: $p95, latency_p99_ms: $p99}')")
done

############################
# 3) Assemble JSON
############################
RESULTS_JSON=$(printf '%s\n' "${RUN_JSONS[@]}" | jq -s '.')

jq -n \
  --arg     system        "$SYSTEM_NAME"       \
  --arg     date          "$DATE_STR"          \
  --arg     inst_label    "$INSTANCE_LABEL"    \
  --arg     inst_type     "$INSTANCE_TYPE"     \
  --argjson vcpus         "$VCPUS"             \
  --argjson ram_gb        "$RAM_GB"            \
  --arg     disk_gb       "$DISK_GB"           \
  --arg     storage_type  "$STORAGE_TYPE"      \
  --argjson cluster       "$CLUSTER_SIZE"      \
  --arg     tuned         "$TUNED"             \
  --arg     comment       "$COMMENT"           \
  --arg     pgver         "$PG_VERSION"        \
  --argjson scale         "$SCALE_FACTOR"      \
  --argjson clients       "$CLIENTS"           \
  --argjson threads       "$THREADS"           \
  --argjson duration      "$DURATION"          \
  --arg     qmode         "$QUERY_MODE"        \
  --argjson loadtime      "$LOAD_TIME_SECONDS" \
  --argjson results       "$RESULTS_JSON"      \
  '{
    system: $system, date: $date,
    instance: {
      label: $inst_label,
      type: $inst_type,
      vcpus: $vcpus,
      ram_gb: $ram_gb,
      disk_gb: (if $disk_gb == "" then null else ($disk_gb | tonumber) end),
      storage_type: (if $storage_type == "" then null else $storage_type end)
    },
    machine: "\($vcpus)vCPU, \($ram_gb)GB RAM",
    cluster_size: $cluster, tuned: $tuned, comment: $comment,
    postgres_version: $pgver,
    benchmark: {
      tool: "pgbench", workload: "TPC-B (built-in)",
      scale_factor: $scale, clients: $clients, threads: $threads,
      duration: $duration, query_mode: $qmode
    },
    load: {load_time_seconds: $loadtime},
    results: $results
  }' > "$OUT_JSON"

echo "== Done =="
echo "JSON: $OUT_JSON"
