# IMDb Data Loader
#
# Lightweight container that downloads and loads IMDb datasets into MariaDB.
# Runs periodic refresh checks to keep data up to date.

FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gzip \
    mariadb-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /scripts /data

# Copy scripts
COPY schema.sql /scripts/
COPY load-imdb-data.sh /scripts/
COPY entrypoint.sh /scripts/

# Make scripts executable
RUN chmod +x /scripts/*.sh

# Data volume
VOLUME /data

# Environment defaults
ENV MYSQL_HOST=imdb-mariadb \
    MYSQL_PORT=3306 \
    MYSQL_USER=imdb \
    DATA_DIR=/data \
    REFRESH_CHECK_INTERVAL=86400 \
    INITIAL_LOAD_DELAY=30

ENTRYPOINT ["/scripts/entrypoint.sh"]
