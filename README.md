# OLTPBench: a Benchmark For Postgres-Compatible Databases

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

### Compatibility

The benchmark uses the standard `pgbench` tool that comes with PostgreSQL, ensuring compatibility with:
- PostgreSQL and its forks
- Postgres-compatible managed services (AWS RDS, Aurora, Google Cloud SQL, Azure Database for PostgreSQL, etc.)
- Postgres wire protocol-compatible databases (CockroachDB, YugabyteDB, etc.)

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

## How to Run the Benchmark

### Prerequisites

1. **PostgreSQL Client Tools 18+**: Install the PostgreSQL client tools including `pgbench` and `psql`:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install postgresql-client-18
   
   # macOS (via Homebrew)
   brew install postgresql@18
   ```

2. **Database Access**: You need connection details for your Postgres-compatible database:
   - Hostname/IP address
   - Port (default: 5432)
   - Database name
   - Username and password

### Running the Benchmark

The `run.sh` script automates the entire benchmark process:

```bash
# Set connection parameters
export PGHOST="your-database-host"
export PGPORT=5432
export PGUSER="postgres"
export PGPASSWORD="your-password"
export PGDATABASE="postgres"

# Optional: Configure benchmark parameters
export SCALE_FACTOR=6849        # Database scale (default: 6849)
export CLIENTS=256              # Number of concurrent clients (default: 256)
export THREADS=16              # Number of threads (default: 16)
export DURATION_SECONDS=600    # Duration of each run in seconds (default: 600)

# Optional: Configure metadata
export SYSTEM_NAME="Postgres by ClickHouse"
export MACHINE_DESC="16vCPU, 32GB RAM"

# Run the benchmark
./run.sh
```

The script will:
1. Detect the PostgreSQL server version
2. Initialize the database with pgbench (data loading)
3. Run the benchmark 3 times
4. Generate a JSON file with all results

### Results Format

The output JSON file includes:
- System information and configuration
- PostgreSQL version
- Benchmark parameters (scale factor, clients, threads, duration)
- Load time (database initialization)
- Results from 3 benchmark runs including:
  - Transactions per second (TPS)
  - Average latency (ms)
  - Latency standard deviation (ms)
  - Failed transactions
  - Initial connection time (ms)

### Adding New Results

To contribute results for a different system or configuration:

1. Create a directory for your system (e.g., `postgresql/`, `aurora/`, `yugabyte/`)
2. Add a `README.md` with setup instructions
3. Place result JSON files in a `results/` subdirectory
4. Name files descriptively: `<system>_<hardware>_<scale>.json`

### Installation And Fine-Tuning

The systems can be installed or used in any reasonable way: from a binary distribution, from a Docker container, from the package manager, or compiled - whatever is more natural and simple or gives better results.

It's better to use the default settings and avoid fine-tuning. Configuration changes can be applied if it is considered strictly necessary and documented.

Fine-tuning and optimization for the benchmark are not recommended but allowed.
In this case, add results for the vanilla configuration and tunes results separately (e.g. 'MyDatabase' and 'MyDatabase-tuned')

## Benchmark Methodology

### Data Generation

The benchmark uses `pgbench -i` to initialize the database with synthetic data. The amount of data is controlled by the scale factor:

- **Scale Factor**: Determines the number of rows in the main table
  - Scale 1 = 100,000 accounts
  - Scale 100 = 10,000,000 accounts
  - Total database size is roughly equals to scale × 16 MB

The schema consists of four tables:
- `pgbench_accounts`: Main table with account balances
- `pgbench_branches`: Branch information
- `pgbench_tellers`: Teller information
- `pgbench_history`: Transaction history

### Workload

The pgbench TPC-B workload performs the following operations in each transaction:
1. UPDATE accounts - debit an account
2. SELECT account balance
3. UPDATE tellers - update teller balance
4. UPDATE branches - update branch balance
5. INSERT into history - record the transaction

Each benchmark run executes this transaction pattern with configurable:
- **Clients**: Number of concurrent database connections
- **Threads**: Number of worker threads (should typically equal available CPU cores)
- **Duration**: How long to run the benchmark (in seconds)

### Multiple Runs

The benchmark executes **3 consecutive runs** with the same parameters. This allows measurement of:
- Consistency across runs
- Effect of warm caches after the first run
- Statistical variation in performance

The database is not restarted between runs to reflect real-world steady-state performance.

### If The Results Cannot Be Published

Some vendors don't allow publishing benchmark results due to the infamous [DeWitt Clause](https://cube.dev/blog/dewitt-clause-or-can-you-benchmark-a-database).
Most of them still allow the use of the system for benchmarks.
In this case, please submit the full information about installation and reproduction, but without `results` directory.
A `.gitignore` file can be added to prevent accidental publishing.

We allow both open-source and proprietary systems in our benchmark, as well as managed services, even if registration, credit card, or salesperson call is required - you still can submit the testing description if you don't violate the TOS.

Please let us know if some results were published by mistake by opening an issue on GitHub.

### If a Mistake Or Misrepresentation Is Found

It is easy to accidentally misrepresent some systems.
While acting in good faith, the authors admit their lack of deep knowledge of most systems.
Please send a pull request to correct the mistakes.

## Add a new database

We highly welcome additions of new entries in the benchmark! Please don't hesitate to contribute one. You don't have to be affiliated with the database engine to contribute to the benchmark.

We welcome all types of databases, including open-source and closed-source, commercial and experimental, distributed or embedded, except one-off customized builds for the benchmark.

- [x] Postgres by ClickHouse
- [x] AWS RDS
- [x] AWS Aurora


