# PostgresBench: A Reproducible Benchmark for Postgres Services

## Overview

This benchmark evaluates the OLTP (Online Transaction Processing) performance of Postgres-compatible database management systems using the industry-standard `pgbench` tool. It measures transactional throughput, latency, and stability under sustained workload conditions.

The benchmark uses the TPC-B-like workload built into pgbench, which simulates a banking application with concurrent transactions that include SELECT, UPDATE, and INSERT operations across multiple tables.

## Goals

The main goals of this benchmark are:

### Reproducibility

The benchmark can be reproduced using the `run.sh` script, which automates the entire process including database initialization, workload execution, and results collection. Each benchmark run takes approximately 30-40 minutes depending on the scale factor and duration settings.

**Requirements:**
- PostgreSQL client tools version 18+ installed locally
- Access to a Postgres-compatible database instance
- Basic environment configuration (connection parameters)

### Standardization

The benchmark uses the built-in TPC-B-like workload from pgbench, which provides:
- Consistent workload across all tested systems
- Industry-standard transaction patterns
- Configurable scale factors for different data sizes
- Multiple concurrent clients to test scalability

### Realism

The pgbench workload simulates a realistic transactional scenario with:
- Mixed read-write operations
- Concurrent connections from multiple clients
- Sustained load over configurable duration
- Transaction consistency requirements
- Real-world latency and throughput metrics

## Limitations

Note these limitations:

1. **Single Workload Type**: The benchmark uses only the built-in TPC-B-like workload from pgbench. Real-world OLTP workloads may have different characteristics, query patterns, and data models.

2. **Synthetic Data**: The pgbench workload uses randomly generated data rather than real production data, which may not reflect actual data distributions and access patterns.

3. **Simple Schema**: The pgbench schema consists of four simple tables (accounts, branches, tellers, history). Real applications often have more complex schemas with many tables and relationships.

4. **Network Latency**: Results may vary significantly based on network latency between the client and database, especially for managed cloud services. We recommend running the benchmark on the same region as the database for the most accurate results.

5. **Configuration Sensitivity**: Database performance is highly dependent on tuning parameters. Default configurations are used unless otherwise noted, which may not be optimal for every system.

6. **Hardware Variability**: While we aim to use consistent hardware configurations, managed services may have underlying infrastructure differences that affect results.

Tl;dr: *Use these results as a general guide, not absolute truth*.

## How to run the benchmark

### Prerequisites

1. **PostgreSQL 18+**: Install PostgreSQL 18 by following the [official PostgreSQL installation guide](https://www.postgresql.org/download/). Verify `pgbench` is correctly installed by running:
   ```bash
   pgbench --version
   ```

2. **jq**: Required for JSON output generation:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install jq

   # macOS (via Homebrew)
   brew install jq
   ```

3. **Database Access**: You need connection details for your Postgres-compatible database:
   - Hostname/IP address
   - Port (default: 5432)
   - Database name
   - Username and password

### Running the benchmark

The `run.sh` script automates the entire benchmark process:

```bash
# Set connection parameters
export PGHOST="your-database-host"
export PGPORT=5432
export PGUSER="postgres"
export PGPASSWORD="your-password"
export PGDATABASE="postgres"

# Required: instance hardware details
export VCPUS=16
export RAM_GB=64

# Optional: instance metadata
export SYSTEM_NAME="Postgres by ClickHouse"
export INSTANCE_TYPE="m8gd.4xlarge"       # instance type identifier
export INSTANCE_STORAGE="950 GB - NVMe"  # local/instance storage; leave empty for N/A
export PRIMARY_STORAGE="NVMe"            # primary storage description; leave empty for N/A

# Optional: benchmark parameters
export SCALE_FACTOR=6849    # Database scale (default: 6849)
export CLIENTS=256          # Number of concurrent clients (default: 256)
export THREADS=16           # Number of threads (default: 16)
export DURATION=600         # Duration of each run in seconds (default: 600)

# Optional: output
export OUT_JSON="results.json"   # Output file name (default: oltpbench_result.json)

# Run the benchmark
./run.sh
```

The script will:
1. Detect the PostgreSQL server version
2. Initialize the database with pgbench (data loading)
3. Run the benchmark 3 times
4. Generate a JSON file with all results

### Results format

The output JSON file includes:
- System information and configuration
- PostgreSQL version
- Benchmark parameters (scale factor, clients, threads, duration)
- Load time (database initialization)
- Results from 3 benchmark runs including:
  - Transactions per second (TPS)
  - Average latency (ms)
  - P95 latency (ms)
  - P99 latency (ms)
  - Latency standard deviation (ms)
  - Failed transactions
  - Initial connection time (ms)

### Adding new results

To contribute results for a different system or configuration:

1. Clone the benchmark repository
2. Follow the documented infrastructure setup to match the tested instance specs
3. Run `run.sh` with the published parameters
4. Create a pull request to submit your results

## Benchmark methodology

### Client machine

The benchmark client must not be a bottleneck. We used a 16 vCPU / 64 GB EC2 instance for this purpose. All services were tested in us-east-2 alongside the client, so measured latency reflects only database behavior.

### Configuration

Each service should be tested using its out-of-the-box Postgres configuration. This reflects typical user behavior, where most expect good performance without manual tuning.

If configuration changes are made, they must be documented and submitted alongside the results. In that case, also include a vanilla (untuned) result so both can be compared (e.g. `MyService` and `MyService-tuned`).

### Data generation

The benchmark uses `pgbench -i` to initialize the database with synthetic data. The amount of data is controlled by the scale factor:

At a scale factor of 1, the tables contain the following number of rows (all multiplied by the scale factor):

```
table                   # of rows
---------------------------------
pgbench_branches        1
pgbench_tellers         10
pgbench_accounts        100000
pgbench_history         0
```

We tested two scale factors: 6849 (~100 GB) and 34247 (~500 GB). These correspond to dataset sizes typical of real Postgres deployments: one where the working set might partially warm in buffer cache over time, and one where it clearly cannot. 

For consistency, we recommend future contributions to use similar scale factors. 

### Multiple runs

The benchmark executes **3 consecutive runs** with the same parameters. This allows measurement of:
- Consistency across runs
- Effect of warm caches after the first run
- Statistical variation in performance

The database is not restarted between runs to reflect real-world steady-state performance. We publish rankings for both the best run and worst run.

### If the results cannot be published

Some vendors don't allow publishing benchmark results due to the infamous [DeWitt Clause](https://cube.dev/blog/dewitt-clause-or-can-you-benchmark-a-database).

Most of them still allow the use of the system for benchmarks.
In this case, please submit the full information about installation and reproduction, but without `results` directory.
A `.gitignore` file can be added to prevent accidental publishing.

We allow both open-source and proprietary systems in our benchmark, as well as managed services, even if registration, credit card, or salesperson call is required - you still can submit the testing description if you don't violate the TOS.

Please let us know if some results were published by mistake by opening an issue on GitHub.

### If a mistake Or misrepresentation is found

It is easy to accidentally misrepresent some systems. While acting in good faith, the authors admit their lack of deep knowledge of most systems.

Please send a pull request to correct the mistakes.

## Add a new database

We highly welcome additions of new entries in the benchmark! Please don't hesitate to contribute one. You don't have to be affiliated with the database engine to contribute to the benchmark.

We welcome all types of databases, including open-source and closed-source, commercial and experimental, distributed or embedded, except one-off customized builds for the benchmark.

- [x] Postgres by ClickHouse
- [x] AWS RDS
- [x] AWS Aurora
- [x] Neon
- [x] Crunchy
