#!/bin/bash
#
# IMDb Database Container Entrypoint
#
# Handles:
# 1. Initial data load on first startup
# 2. Periodic refresh check (every 24 hours)
# 3. Keeps container running for database access
#
# Environment:
#   REFRESH_CHECK_INTERVAL - How often to check for refresh (default: 86400 = 24h)
#   INITIAL_LOAD_DELAY     - Delay before first load (default: 10 seconds)

set -e

REFRESH_CHECK_INTERVAL="${REFRESH_CHECK_INTERVAL:-86400}"
INITIAL_LOAD_DELAY="${INITIAL_LOAD_DELAY:-10}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [entrypoint] $*"
}

# Initial load
log "Starting IMDb data service..."
log "Waiting ${INITIAL_LOAD_DELAY}s for MariaDB to fully initialize..."
sleep "$INITIAL_LOAD_DELAY"

log "Running initial data load..."
/scripts/load-imdb-data.sh || {
    log "Initial load failed, will retry on next cycle"
}

# Periodic refresh loop
log "Starting refresh check loop (interval: ${REFRESH_CHECK_INTERVAL}s)"
while true; do
    sleep "$REFRESH_CHECK_INTERVAL"
    log "Checking if data refresh is needed..."
    /scripts/load-imdb-data.sh || {
        log "Refresh check failed, will retry next cycle"
    }
done
