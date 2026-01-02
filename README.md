# IMDb Local Database

A Docker-based local cache of IMDb's non-commercial datasets (~202 million records) for fast title lookups and media identification.

## Features

- **202M records** from 7 IMDb datasets loaded locally
- **Zero-downtime updates** using shadow table swap
- **Fast queries** with optimized indexes and full-text search
- **Auto-refresh** checks for stale data daily
- **PHPMyAdmin** included for easy database management
- **~22 minute initial load** with optimized bulk loading

## Quick Start

```bash
# Clone and start
git clone https://github.com/YOUR_USERNAME/imdb-local-db.git
cd imdb-local-db
docker compose up -d

# Monitor initial load (~22 minutes)
docker compose logs -f loader

# Access PHPMyAdmin
open http://localhost:8080
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| mariadb | 3306 | MariaDB 11 database |
| loader | - | Data downloader/importer |
| phpmyadmin | 8080 | Web-based admin interface |

## Database Connection

```
Host: localhost
Port: 3306
Database: imdb
Username: imdb
Password: imdb_pass
```

## Example Queries

```sql
-- Find a movie
SELECT tconst, primaryTitle, startYear, genres
FROM title_basics
WHERE primaryTitle LIKE '%Superman%'
  AND titleType = 'movie';

-- Get TV episodes
SELECT e.seasonNumber, e.episodeNumber, b.primaryTitle
FROM title_episode e
JOIN title_basics b ON e.tconst = b.tconst
WHERE e.parentTconst = 'tt1358522'
ORDER BY e.seasonNumber, e.episodeNumber;

-- Full-text search
SELECT tconst, primaryTitle, startYear
FROM title_basics
WHERE MATCH(primaryTitle) AGAINST('scooby doo' IN NATURAL LANGUAGE MODE)
LIMIT 10;
```

## Tables

| Table | Records | Description |
|-------|---------|-------------|
| title_basics | 12M | Title info (type, year, runtime, genres) |
| title_akas | 55M | Alternative/localized titles |
| title_episode | 9M | TV episode mappings |
| title_ratings | 1.6M | User ratings |
| title_crew | 12M | Directors/writers |
| title_principals | 97M | Cast and crew |
| name_basics | 15M | Person information |

## Configuration

Copy `.env.example` to `.env` and customize:

```bash
MYSQL_ROOT_PASSWORD=your_secure_password
MYSQL_PASSWORD=your_secure_password
MYSQL_PORT=3306
PHPMYADMIN_PORT=8080
MAX_AGE_DAYS=15
```

## Commands

```bash
docker compose up -d              # Start
docker compose down               # Stop
docker compose logs -f loader     # View logs
docker compose exec loader /scripts/load-imdb-data.sh --force  # Force refresh
```

## Data Source

[IMDb Non-Commercial Datasets](https://developer.imdb.com/non-commercial-datasets/)

## Documentation

- [INSTALL.md](INSTALL.md) - Detailed installation guide
- [SETUP-PROMPT.md](SETUP-PROMPT.md) - Prompt to recreate this project

## License

The IMDb data is subject to IMDb's non-commercial license terms.
