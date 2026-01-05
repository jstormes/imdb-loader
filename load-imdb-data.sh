#!/bin/bash
#
# Load IMDb datasets into MariaDB
#
# Downloads data from IMDb ONLY if local files are missing or over 15 days old.
# Loads into database if tables are empty or data was refreshed.
#
# Usage: ./load-imdb-data.sh [--force]
#
# Environment:
#   MYSQL_HOST     - MariaDB host (default: localhost)
#   MYSQL_PORT     - MariaDB port (default: 3306)
#   MYSQL_USER     - Database user (default: imdb)
#   MYSQL_PASSWORD - Database password (required)
#   DATA_DIR       - Directory for downloaded files (default: /data)
#   MAX_AGE_DAYS   - Maximum age of data files before refresh (default: 15)

set -e

# Configuration
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-imdb}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
DATA_DIR="${DATA_DIR:-/data}"
BASE_URL="https://datasets.imdbws.com"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-15}"
FORCE_UPDATE="${1:-}"

# Files to download and their target tables
declare -A FILES_TO_TABLES=(
    ["title.basics.tsv.gz"]="title_basics"
    ["title.akas.tsv.gz"]="title_akas"
    ["title.crew.tsv.gz"]="title_crew"
    ["title.episode.tsv.gz"]="title_episode"
    ["title.principals.tsv.gz"]="title_principals"
    ["title.ratings.tsv.gz"]="title_ratings"
    ["name.basics.tsv.gz"]="name_basics"
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# MySQL command helper
mysql_cmd() {
    mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$@"
}

# Check if a file exists and is less than MAX_AGE_DAYS old
file_is_fresh() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1  # File doesn't exist
    fi

    local file_age_days
    file_age_days=$(( ($(date +%s) - $(stat -c %Y "$file")) / 86400 ))

    if [ "$file_age_days" -lt "$MAX_AGE_DAYS" ]; then
        return 0  # File is fresh
    else
        return 1  # File is stale
    fi
}

# Check if a gzip file is valid
file_is_valid() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    # Test gzip integrity
    if ! gzip -t "$file" 2>/dev/null; then
        return 1
    fi
    return 0
}

# Check if download is needed - if files are missing, corrupted, or > MAX_AGE_DAYS old
check_download_needed() {
    if [ "$FORCE_UPDATE" = "--force" ]; then
        log "Force update requested"
        return 0
    fi

    local need_download=0

    for file in "${!FILES_TO_TABLES[@]}"; do
        local filepath="$DATA_DIR/$file"

        # If file doesn't exist, download needed
        if [ ! -f "$filepath" ]; then
            log "File missing: $file - will download"
            need_download=1
            continue
        fi

        # If file is corrupted, download needed
        if ! file_is_valid "$filepath"; then
            log "File corrupted: $file - will download"
            need_download=1
            continue
        fi

        # Check file age
        local file_age_days
        file_age_days=$(( ($(date +%s) - $(stat -c %Y "$filepath")) / 86400 ))

        if [ "$file_age_days" -ge "$MAX_AGE_DAYS" ]; then
            log "File $file is $file_age_days days old (max: $MAX_AGE_DAYS) - will download"
            need_download=1
        else
            log "File $file is $file_age_days days old - OK"
        fi
    done

    if [ $need_download -eq 1 ]; then
        log "Download needed"
        return 0
    fi

    log "All files are fresh (less than $MAX_AGE_DAYS days old) - no download needed"
    return 1
}

# Check if database load is needed
check_load_needed() {
    # Check if any table is empty
    for table in "${FILES_TO_TABLES[@]}"; do
        local count
        count=$(mysql_cmd -N -e "SELECT COUNT(*) FROM imdb.$table" 2>/dev/null || echo "0")
        if [ "$count" -eq 0 ]; then
            log "Table $table is empty - load needed"
            return 0
        fi
    done

    log "All tables have data - no load needed"
    return 1
}

# Download a single file with retry
download_file() {
    local file="$1"
    local url="$BASE_URL/$file"
    local output="$DATA_DIR/$file"
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        log "Downloading $file (attempt $((retry + 1))/$max_retries)..."
        if curl -f -L -o "$output" "$url" --progress-bar; then
            local size
            size=$(ls -lh "$output" | awk '{print $5}')
            log "Downloaded $file ($size)"
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $max_retries ] && sleep $((retry * 5))
    done

    error "Failed to download $file after $max_retries attempts"
    return 1
}

# Load a TSV file into its table using optimized shadow table swap
# Performance optimizations:
#   - Create shadow table WITHOUT indexes (much faster inserts)
#   - Disable unique/foreign key checks during load
#   - Set InnoDB for maximum write speed
#   - Add indexes AFTER data load
#   - Atomic table swap at the end
load_table() {
    local file="$1"
    local table="$2"
    local tsv_file="$DATA_DIR/${file%.gz}"
    local shadow_table="${table}_new"
    local old_table="${table}_old"

    log "Loading $file into $table (optimized shadow table mode)..."

    # Get row count in current table
    local before_count
    before_count=$(mysql_cmd -N -e "SELECT COUNT(*) FROM imdb.$table" 2>/dev/null || echo "0")
    log "  Current table has $before_count rows (remains queryable during load)"

    # Decompress
    log "  Decompressing..."
    gunzip -f -k "$DATA_DIR/$file"

    # Get column count from first line
    local columns
    columns=$(head -1 "$tsv_file" | tr '\t' '\n' | wc -l)
    log "  Found $columns columns"

    # Count rows (minus header)
    local row_count
    row_count=$(($(wc -l < "$tsv_file") - 1))
    log "  Processing $row_count rows into shadow table..."

    # Get index definitions from original table (to recreate after load)
    local index_defs
    index_defs=$(mysql_cmd -N imdb -e "
        SELECT CONCAT(
            IF(NON_UNIQUE = 0 AND INDEX_NAME != 'PRIMARY', 'UNIQUE ', ''),
            IF(INDEX_TYPE = 'FULLTEXT', 'FULLTEXT ', ''),
            'INDEX \`', INDEX_NAME, '\` (',
            GROUP_CONCAT('\`', COLUMN_NAME, '\`' ORDER BY SEQ_IN_INDEX SEPARATOR ', '),
            ')'
        )
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = 'imdb'
          AND TABLE_NAME = '$table'
          AND INDEX_NAME != 'PRIMARY'
        GROUP BY INDEX_NAME, NON_UNIQUE, INDEX_TYPE
    " 2>/dev/null || echo "")

    # Create shadow table - structure only, NO indexes except primary key
    log "  Creating shadow table (no secondary indexes)..."
    mysql_cmd imdb -e "DROP TABLE IF EXISTS $shadow_table"

    # Get CREATE TABLE statement and strip out non-primary indexes for faster load
    local create_stmt
    create_stmt=$(mysql_cmd -N imdb -e "SHOW CREATE TABLE $table" 2>/dev/null | tail -1)

    # Create basic table structure
    mysql_cmd imdb -e "CREATE TABLE $shadow_table LIKE $table"

    # Drop secondary indexes from shadow table (keep PRIMARY KEY)
    local indexes_to_drop
    indexes_to_drop=$(mysql_cmd -N imdb -e "
        SELECT INDEX_NAME
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = 'imdb'
          AND TABLE_NAME = '$shadow_table'
          AND INDEX_NAME != 'PRIMARY'
        GROUP BY INDEX_NAME
    " 2>/dev/null || echo "")

    for idx in $indexes_to_drop; do
        mysql_cmd imdb -e "ALTER TABLE $shadow_table DROP INDEX \`$idx\`" 2>/dev/null || true
    done

    # Bulk load with performance optimizations
    log "  Loading data (optimized: checks disabled, no secondary indexes)..."
    local load_start=$(date +%s)

    mysql_cmd imdb --local-infile=1 -e "
        SET SESSION UNIQUE_CHECKS = 0;
        SET SESSION FOREIGN_KEY_CHECKS = 0;

        LOAD DATA LOCAL INFILE '$tsv_file'
        INTO TABLE $shadow_table
        FIELDS TERMINATED BY '\t'
        LINES TERMINATED BY '\n'
        IGNORE 1 ROWS;
    " 2>&1 | grep -v "Warning" || true

    local load_end=$(date +%s)
    local load_time=$((load_end - load_start))

    # Get loaded count
    local after_count
    after_count=$(mysql_cmd -N -e "SELECT COUNT(*) FROM imdb.$shadow_table" 2>/dev/null)
    local rows_per_sec=$((after_count / (load_time + 1)))
    log "  Data loaded: $after_count rows in ${load_time}s (~$rows_per_sec rows/sec)"

    # Recreate indexes (this is faster than loading with indexes)
    if [ -n "$index_defs" ]; then
        log "  Creating indexes (post-load optimization)..."
        local idx_start=$(date +%s)

        echo "$index_defs" | while read -r idx_def; do
            if [ -n "$idx_def" ]; then
                mysql_cmd imdb -e "ALTER TABLE $shadow_table ADD $idx_def" 2>/dev/null || true
            fi
        done

        local idx_end=$(date +%s)
        log "  Indexes created in $((idx_end - idx_start))s"
    fi

    # Atomic swap: rename tables
    log "  Swapping tables (atomic)..."
    mysql_cmd imdb -e "
        DROP TABLE IF EXISTS $old_table;
        RENAME TABLE $table TO $old_table, $shadow_table TO $table;
        DROP TABLE IF EXISTS $old_table;
    "

    log "  Result: $after_count rows now live (total time: $(($(date +%s) - load_start))s)"

    # Cleanup decompressed file
    rm -f "$tsv_file"

    echo "$after_count"
}

# Main execution
main() {
    log "=========================================="
    log "IMDb Data Loader"
    log "=========================================="
    log "Host: $MYSQL_HOST:$MYSQL_PORT"
    log "Data directory: $DATA_DIR"
    log "Max data age: $MAX_AGE_DAYS days"

    # Validate password
    if [ -z "$MYSQL_PASSWORD" ]; then
        error "MYSQL_PASSWORD environment variable is required"
        exit 1
    fi

    # Wait for MariaDB to be ready
    log "Waiting for MariaDB..."
    local retries=30
    while ! mysql_cmd -e "SELECT 1" >/dev/null 2>&1; do
        retries=$((retries - 1))
        if [ $retries -le 0 ]; then
            error "MariaDB not available after 30 attempts"
            exit 1
        fi
        sleep 2
    done
    log "MariaDB is ready"

    # Initialize schema
    log "Initializing schema..."
    mysql_cmd < /scripts/schema.sql

    # Create data directory
    mkdir -p "$DATA_DIR"

    # Check if download is needed (files missing or older than MAX_AGE_DAYS)
    local did_download=0
    if check_download_needed; then
        log ""
        log "Downloading datasets..."
        mysql_cmd imdb -e "UPDATE imdb_metadata SET status = 'downloading' WHERE id = 1"

        local download_failed=0
        for file in "${!FILES_TO_TABLES[@]}"; do
            if ! download_file "$file"; then
                download_failed=1
            fi
        done

        if [ $download_failed -eq 1 ]; then
            mysql_cmd imdb -e "UPDATE imdb_metadata SET status = 'download_failed' WHERE id = 1"
            error "Some downloads failed"
            exit 1
        fi
        did_download=1
    fi

    # Check if database load is needed (tables empty or just downloaded fresh data)
    local need_load=0
    if [ $did_download -eq 1 ]; then
        need_load=1
        log "Fresh download - will reload all tables"
    fi

    # Count total records and load only empty tables
    local total_records=0
    local tables_loaded=0

    for file in "${!FILES_TO_TABLES[@]}"; do
        local table="${FILES_TO_TABLES[$file]}"
        local current_count

        # Use information_schema for fast row count estimate (avoids slow COUNT(*) on large tables)
        current_count=$(mysql_cmd -N -e "SELECT COALESCE(table_rows, 0) FROM information_schema.tables WHERE table_schema='imdb' AND table_name='$table'" 2>/dev/null || echo "0")

        # Handle empty result
        if [ -z "$current_count" ]; then
            current_count=0
        fi

        log "Table $table has ~$current_count rows"

        if [ $did_download -eq 1 ] || [ "$current_count" -eq 0 ]; then
            # Table is empty or we have fresh data - load it
            if [ $tables_loaded -eq 0 ]; then
                log ""
                log "Loading data into database..."
                mysql_cmd imdb -e "UPDATE imdb_metadata SET status = 'loading' WHERE id = 1"
            fi

            local count
            count=$(load_table "$file" "$table")
            total_records=$((total_records + count))
            tables_loaded=$((tables_loaded + 1))
        else
            log "Table $table already has $current_count rows - skipping"
            total_records=$((total_records + current_count))
        fi
    done

    if [ $tables_loaded -gt 0 ]; then

        # Update metadata
        mysql_cmd imdb -e "
            UPDATE imdb_metadata SET
                last_updated = NOW(),
                next_update = DATE_ADD(NOW(), INTERVAL $MAX_AGE_DAYS DAY),
                status = 'complete',
                records_loaded = $total_records
            WHERE id = 1
        "

        log ""
        log "=========================================="
        log "Load Complete"
        log "=========================================="
        log "Total records loaded: $total_records"
        log "Next update: $(mysql_cmd -N -e "SELECT next_update FROM imdb.imdb_metadata WHERE id = 1" 2>/dev/null)"
    else
        log ""
        log "=========================================="
        log "No Action Needed"
        log "=========================================="
        log "Data files are fresh and database is populated."

        # Show file ages
        log ""
        log "File ages:"
        for file in "${!FILES_TO_TABLES[@]}"; do
            local filepath="$DATA_DIR/$file"
            if [ -f "$filepath" ]; then
                local age_days=$(( ($(date +%s) - $(stat -c %Y "$filepath")) / 86400 ))
                log "  $file: $age_days days old"
            fi
        done
    fi
}

main "$@"
