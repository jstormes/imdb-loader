# Prompt: Create IMDb Local Database for Media Identification

Create a MariaDB-based local cache of IMDb's non-commercial datasets for identifying ripped disc content. The setup should:

## Requirements

### 1. Docker Services (add to existing docker-compose.yml)
- MariaDB 11 container with persistent storage
- PHPMyAdmin for database management
- Data loader container that downloads and imports IMDb data

### 2. Data Source
URL: https://datasets.imdbws.com/

Files to download:
- title.basics.tsv.gz (12M titles)
- title.akas.tsv.gz (55M alternative titles)
- title.episode.tsv.gz (9M TV episodes)
- title.ratings.tsv.gz (1.6M ratings)
- title.crew.tsv.gz (directors/writers)
- title.principals.tsv.gz (97M cast/crew)
- name.basics.tsv.gz (15M people)

### 3. Download Logic (CRITICAL - be respectful of IMDb servers)
- ONLY download if files are **older than 15 days**
- Missing/corrupted files do NOT trigger download (require `--force`)
- Check file age using filesystem timestamp, not database

### 4. Database Load Logic (Shadow Table Swap)
- Use **shadow table swap** for zero-downtime updates:
  1. Create `table_new` shadow table (structure only, no indexes)
  2. Disable checks: `UNIQUE_CHECKS=0`, `FOREIGN_KEY_CHECKS=0`
  3. Load data into shadow table
  4. Add indexes to shadow table
  5. Atomic `RENAME TABLE table TO table_old, table_new TO table`
  6. Drop `table_old`
- Original table remains queryable during entire load
- Use `information_schema.table_rows` for fast row counts (not COUNT(*))
- Track metadata (last_updated, next_update, status)

### 4b. Performance Optimizations
- Disable unique/foreign key checks during bulk load (`UNIQUE_CHECKS=0`, `FOREIGN_KEY_CHECKS=0`)
- Create indexes AFTER data load (much faster than indexed inserts)
- Load into table with PRIMARY KEY only, add secondary indexes post-load

### 5. Schema Requirements
- Primary keys on tconst/nconst
- Indexes on primaryTitle, titleType, startYear, parentTconst
- FULLTEXT index on primaryTitle for search
- UTF8MB4 charset for international titles

### 6. Persistence
- Bind mount for MariaDB data: `./imdb-data/mysql`
- Bind mount for downloaded files: `./imdb-data/downloads`
- Data survives container restarts without re-downloading

### 7. Files to Create
```
imdb-data/
├── Dockerfile          # Debian-slim with curl, gzip, mariadb-client
├── schema.sql          # Database schema with indexes
├── load-imdb-data.sh   # Download and import script
├── entrypoint.sh       # Startup and periodic refresh check
└── README.md           # Documentation
```

### 8. Environment Variables
- `IMDB_MYSQL_PASSWORD` - database password
- `IMDB_MYSQL_PORT` - external port (default 3307)
- `MAX_AGE_DAYS` - refresh threshold (default 15)
- `REFRESH_CHECK_INTERVAL` - how often to check (default 86400s)

## Key Behaviors

| Scenario | Behavior |
|----------|----------|
| Startup with no files | Log "use --force to download" (don't auto-download) |
| Startup with fresh files (<15 days) | Skip download, load empty tables only |
| Startup with stale files (>=15 days) | Download all, reload all tables |
| Crash/restart | Resume by only loading tables with 0 rows |
| During load | Original tables remain queryable (shadow table swap) |
| Load completes | Atomic table swap (instant cutover) |

## Example Queries

```sql
-- Find a movie by title
SELECT tconst, primaryTitle, startYear, genres
FROM title_basics
WHERE primaryTitle LIKE '%Superman%'
  AND titleType = 'movie';

-- Get episodes for a TV series
SELECT e.seasonNumber, e.episodeNumber, b.primaryTitle
FROM title_episode e
JOIN title_basics b ON e.tconst = b.tconst
WHERE e.parentTconst = 'tt1358522'
ORDER BY e.seasonNumber, e.episodeNumber;

-- Full-text search
SELECT tconst, primaryTitle, startYear
FROM title_basics
WHERE MATCH(primaryTitle) AGAINST('scooby doo' IN NATURAL LANGUAGE MODE)
  AND titleType IN ('movie', 'tvSeries')
LIMIT 10;
```

## Usage

```bash
# Start services
docker compose up -d imdb-mariadb imdb-loader

# Monitor loading progress
docker logs -f imdb-loader

# Force a complete reload
docker exec imdb-loader /scripts/load-imdb-data.sh --force

# Access PHPMyAdmin
open http://localhost:8080
```
