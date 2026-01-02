# IMDb Local Database - Installation Guide

Local MariaDB database containing IMDb's non-commercial datasets (~202 million records) for title lookups and media identification.

## Prerequisites

- Docker and Docker Compose
- ~15GB disk space (downloads + database)
- Internet connection for initial data download

## Quick Start

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/imdb-local-db.git
cd imdb-local-db

# Start all services
docker compose up -d

# Monitor the initial load (~25 minutes for 202M records)
docker compose logs -f loader
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| mariadb | 3306 | MariaDB database |
| loader | - | Data downloader/importer |
| phpmyadmin | 8080 | Web-based database admin |

## Access

- **PHPMyAdmin**: http://localhost:8080
- **MySQL CLI**: `mysql -h localhost -P 3306 -u imdb -pimdb_pass imdb`
- **From application**: `mysql://imdb:imdb_pass@localhost:3306/imdb`

## Configuration

Create a `.env` file to customize settings:

```bash
# Database credentials
MYSQL_ROOT_PASSWORD=your_secure_root_password
MYSQL_PASSWORD=your_secure_password

# Ports (change if conflicts)
MYSQL_PORT=3306
PHPMYADMIN_PORT=8080

# Data refresh settings
MAX_AGE_DAYS=15                # Days before data refresh
REFRESH_CHECK_INTERVAL=86400   # Seconds between refresh checks (24h)
```

## Data Directory Structure

```
imdb-local-db/
├── data/
│   ├── downloads/          # IMDb TSV files (~5GB compressed)
│   │   ├── title.basics.tsv.gz
│   │   ├── title.akas.tsv.gz
│   │   └── ...
│   └── mysql/              # MariaDB data files (~10GB)
├── docker-compose.yml
├── Dockerfile
├── schema.sql
├── load-imdb-data.sh
├── entrypoint.sh
└── README.md
```

## Database Tables

| Table | Records | Description |
|-------|---------|-------------|
| `title_basics` | 12M | Core title info (type, title, year, runtime, genres) |
| `title_akas` | 55M | Alternative/localized titles |
| `title_episode` | 9M | TV episode to series mapping |
| `title_ratings` | 1.6M | User ratings and vote counts |
| `title_crew` | 12M | Directors and writers |
| `title_principals` | 97M | Cast and crew with roles |
| `name_basics` | 15M | Person information |

## Example Queries

```sql
-- Find a movie by title
SELECT tconst, primaryTitle, startYear, genres
FROM title_basics
WHERE primaryTitle LIKE '%Superman%'
  AND titleType = 'movie'
  AND startYear >= 2020;

-- Find a TV series
SELECT tconst, primaryTitle, startYear
FROM title_basics
WHERE primaryTitle = 'White Collar'
  AND titleType = 'tvSeries';

-- Get episodes for a series
SELECT e.seasonNumber, e.episodeNumber, b.primaryTitle
FROM title_episode e
JOIN title_basics b ON e.tconst = b.tconst
WHERE e.parentTconst = 'tt1358522'  -- White Collar
ORDER BY e.seasonNumber, e.episodeNumber;

-- Full-text search
SELECT tconst, primaryTitle, startYear
FROM title_basics
WHERE MATCH(primaryTitle) AGAINST('scooby doo' IN NATURAL LANGUAGE MODE)
  AND titleType IN ('movie', 'tvSeries')
LIMIT 10;
```

## Commands

```bash
# Start services
docker compose up -d

# Stop services
docker compose down

# View loader logs
docker compose logs -f loader

# Force data refresh
docker compose exec loader /scripts/load-imdb-data.sh --force

# Check data freshness
docker compose exec mariadb mariadb -uimdb -pimdb_pass imdb \
  -e "SELECT last_updated, next_update, status FROM imdb_metadata;"

# Restart just the loader
docker compose restart loader

# Full reset (delete all data)
docker compose down -v
rm -rf data/
docker compose up -d
```

## Performance

Initial load benchmark (202M records):

| Table | Rows | Load Time | Rate |
|-------|------|-----------|------|
| title_principals | 97M | 8 min | 567K/s |
| title_akas | 55M | 8.5 min | 303K/s |
| name_basics | 15M | 1.4 min | 384K/s |
| title_basics | 12M | 2 min | 290K/s |
| Others | 23M | 1 min | 500K+/s |
| **Total** | **202M** | **~22 min** | |

## How Data Refresh Works

The loader uses a **shadow table swap** strategy for zero-downtime updates:

1. Data loads into a `_new` shadow table (original remains queryable)
2. Secondary indexes are created after data load (faster)
3. Atomic `RENAME TABLE` swaps the tables instantly
4. Old table is dropped

This means:
- No query interruption during multi-hour refreshes
- Atomic cutover (instant)
- Safe rollback if load fails

## Automatic Refresh

The loader automatically checks for stale data:

- Checks file ages every 24 hours (configurable)
- Downloads new data if files are older than 15 days
- Reloads database with fresh data using shadow table swap
- Original data remains queryable during entire process

## Troubleshooting

**Loader not starting?**
```bash
# Check MariaDB is healthy
docker compose ps
docker compose logs mariadb
```

**Load failed or stuck?**
```bash
# Check for active transactions
docker compose exec mariadb mariadb -uimdb -pimdb_pass \
  -e "SHOW PROCESSLIST;"

# Restart loader
docker compose restart loader
```

**Out of disk space?**
```bash
# Check usage
du -sh data/downloads data/mysql

# Clean up old files
rm -rf data/downloads/*.tsv  # Keep .gz files
```

**Port conflict?**
```bash
# Use different ports in .env
MYSQL_PORT=3307
PHPMYADMIN_PORT=8081
```

**Reset everything**
```bash
docker compose down
rm -rf data/
docker compose up -d
```

## Data Source

IMDb Non-Commercial Datasets: https://developer.imdb.com/non-commercial-datasets/

Data is refreshed daily by IMDb. This project downloads and caches locally for fast queries.

## License

The IMDb data is subject to IMDb's non-commercial license terms.
