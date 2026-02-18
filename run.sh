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
# - pgbench available in PATH
# - python3 available
#
# Notes:
# - This script parses standard pgbench output (no -l percentile parsing).
# - If a run fails or parsing fails, the script exits with a clear error.

############################
# Config (edit as needed)
############################
SYSTEM_NAME=${SYSTEM_NAME:-"Postgres by ClickHouse ☁️ (aws)"}
MACHINE_DESC=${MACHINE_DESC:-"8 GiB, aws"}
CLUSTER_SIZE=${CLUSTER_SIZE:-1}
PROPRIETARY=${PROPRIETARY:-"yes"}
TUNED=${TUNED:-"no"}
COMMENT=${COMMENT:-""}

# Tags as a comma-separated list (no spaces unless you quote it)
TAGS=${TAGS:-"PostgreSQL-compatible,OLTP,managed,aws"}

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
DURATION_SECONDS=${DURATION_SECONDS:-600}
QUERY_MODE=${QUERY_MODE:-prepared}
PROGRESS_SECONDS=${PROGRESS_SECONDS:-30}

# Output
OUT_JSON=${OUT_JSON:-"oltpbench_result.json"}
WORKDIR=${WORKDIR:-"./oltpbench_tmp"}

############################
# Derived commands
############################
INIT_CMD=(pgbench -i -s "$SCALE_FACTOR" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
RUN_CMD=(pgbench -c "$CLIENTS" -j "$THREADS" -T "$DURATION_SECONDS" -M "$QUERY_MODE" -P "$PROGRESS_SECONDS"
         -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")

mkdir -p "$WORKDIR"

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
need_cmd python3

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
START_NS=$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)
PGPASSWORD="$PGPASSWORD" "${INIT_CMD[@]}" | tee "$INIT_LOG"
END_NS=$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)

LOAD_TIME_SECONDS=$(python3 - <<PY
start_ns = int("$START_NS")
end_ns = int("$END_NS")
print((end_ns - start_ns) / 1e9)
PY
)
echo "Load time: ${LOAD_TIME_SECONDS}s"
echo

############################
# 2) Run benchmark 3 times
############################
RUN_LOGS=()
for i in 1 2 3; do
  echo "== Run #$i =="
  LOG="$WORKDIR/run_${i}.log"
  PGPASSWORD="$PGPASSWORD" "${RUN_CMD[@]}"  | tee "$LOG"
  RUN_LOGS+=("$LOG")
  echo
done

############################
# 3) Parse outputs + write JSON
############################
python3 - "$OUT_JSON" "$SYSTEM_NAME" "$DATE_STR" "$MACHINE_DESC" "$CLUSTER_SIZE" "$PROPRIETARY" "$TUNED" "$COMMENT" "$TAGS" \
  "$SCALE_FACTOR" "$CLIENTS" "$THREADS" "$DURATION_SECONDS" "$QUERY_MODE" \
  "$LOAD_TIME_SECONDS" "$PG_VERSION" "${RUN_LOGS[@]}" <<'PY'
import json
import re
import sys
from pathlib import Path

def parse_pgbench_output(text: str) -> dict:
    """
    Parse metrics from pgbench output similar to:
      number of transactions actually processed: 1494662
      number of failed transactions: 0 (0.000%)
      latency average = 12.602 ms
      latency stddev = 2.472 ms
      initial connection time = 90.044 ms
      tps = 2491.437593 (without initial connection time)
    """
    def m(pattern):
        return re.search(pattern, text, re.MULTILINE)

    tx = m(r"number of transactions actually processed:\s*([0-9]+)")
    failed = m(r"number of failed transactions:\s*([0-9]+)")
    lat_avg = m(r"latency average\s*=\s*([0-9.]+)\s*ms")
    lat_std = m(r"latency stddev\s*=\s*([0-9.]+)\s*ms")
    conn = m(r"initial connection time\s*=\s*([0-9.]+)\s*ms")
    tps = m(r"tps\s*=\s*([0-9.]+)\s*\(without initial connection time\)")

    missing = []
    for name, match in [
        ("transactions", tx),
        ("failed_transactions", failed),
        ("latency_avg_ms", lat_avg),
        ("latency_stddev_ms", lat_std),
        ("initial_connection_time_ms", conn),
        ("tps", tps),
    ]:
        if not match:
            missing.append(name)

    if missing:
        # Provide a helpful snippet for debugging parsing mismatches
        snippet = "\n".join(text.splitlines()[-40:])
        raise ValueError(f"Failed to parse pgbench output fields: {', '.join(missing)}\n"
                         f"Last lines of output:\n{snippet}")

    return {
        "tps": float(tps.group(1)),
        "transactions": int(tx.group(1)),
        "failed_transactions": int(failed.group(1)),
        "latency_avg_ms": float(lat_avg.group(1)),
        "latency_stddev_ms": float(lat_std.group(1)),
        "initial_connection_time_ms": float(conn.group(1)),
    }

def main():
    if len(sys.argv) < 16:
        raise SystemExit("Unexpected argv length.")

    out_json = sys.argv[1]
    system_name = sys.argv[2]
    date_str = sys.argv[3]
    machine_desc = sys.argv[4]
    cluster_size = int(sys.argv[5])
    proprietary = sys.argv[6]
    tuned = sys.argv[7]
    comment = sys.argv[8]
    tags_csv = sys.argv[9]

    scale_factor = int(sys.argv[10])
    clients = int(sys.argv[11])
    threads = int(sys.argv[12])
    duration_seconds = int(sys.argv[13])
    query_mode = sys.argv[14]

    load_time_seconds = float(sys.argv[15])
    postgres_version = sys.argv[16]

    run_logs = [Path(p) for p in sys.argv[17:]]
    if len(run_logs) != 3:
        raise SystemExit(f"Expected 3 run logs, got {len(run_logs)}")

    tags = [t.strip() for t in tags_csv.split(",") if t.strip()]

    results = []
    for idx, log_path in enumerate(run_logs, start=1):
        text = log_path.read_text(encoding="utf-8", errors="replace")
        parsed = parse_pgbench_output(text)
        results.append({
            "run": idx,
            **parsed
        })

    payload = {
        "system": system_name,
        "date": date_str,
        "machine": machine_desc,
        "cluster_size": cluster_size,
        "proprietary": proprietary,
        "tuned": tuned,
        "comment": comment,
        "tags": tags,
        "postgres_version": postgres_version,
        "benchmark": {
            "tool": "pgbench",
            "workload": "TPC-B (built-in)",
            "scale_factor": scale_factor,
            "clients": clients,
            "threads": threads,
            "duration_seconds": duration_seconds,
            "query_mode": query_mode
        },
        "load": {
            "load_time_seconds": load_time_seconds
        },
        "results": results
    }

    Path(out_json).write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(f"Wrote {out_json}")

if __name__ == "__main__":
    main()
PY

echo "== Done =="
echo "JSON: $OUT_JSON"
