-- IMDb Non-Commercial Dataset Schema
-- Source: https://developer.imdb.com/non-commercial-datasets/
--
-- Optimized for lookups by title, tconst (IMDb ID), and name
--
-- INDEX STRATEGY:
-- ===============
-- Key queries from imdb-lookup.sh:
--
-- 1. Title search: WHERE primaryTitle = 'X' or MATCH(primaryTitle) AGAINST('X')
--    -> Uses: idx_primaryTitle, ft_primaryTitle (FULLTEXT)
--
-- 2. Type filter: WHERE titleType IN ('movie', 'tvSeries', ...)
--    -> Uses: idx_titleType
--
-- 3. Character search: MATCH(characters) AGAINST('X')
--    -> Uses: ft_characters (FULLTEXT) - Much faster than LIKE '%X%'
--
-- 4. Actor lookup: WHERE primaryName IN ('X', 'Y') + JOIN on nconst
--    -> Uses: idx_primaryName, idx_nconst
--
-- 5. Episode lookup: WHERE parentTconst = 'X' ORDER BY season, episode
--    -> Uses: idx_parentTconst, idx_season_episode
--
-- PERFORMANCE NOTES:
-- - Always use FULLTEXT (MATCH AGAINST) instead of LIKE '%...%' for text search
-- - LIKE with leading wildcard cannot use B-tree indexes, causing full scans
-- - Character-only search: Use MATCH(characters) AGAINST() not IS NOT NULL

CREATE DATABASE IF NOT EXISTS imdb;
USE imdb;

-- title.basics - Core title information
CREATE TABLE IF NOT EXISTS title_basics (
    tconst VARCHAR(12) PRIMARY KEY,
    titleType VARCHAR(20),
    primaryTitle VARCHAR(500),
    originalTitle VARCHAR(500),
    isAdult TINYINT(1),
    startYear SMALLINT,
    endYear SMALLINT,
    runtimeMinutes INT,
    genres VARCHAR(255),
    INDEX idx_primaryTitle (primaryTitle(100)),
    INDEX idx_titleType (titleType),
    INDEX idx_startYear (startYear),
    FULLTEXT INDEX ft_primaryTitle (primaryTitle)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- title.akas - Alternative titles (localized names)
-- Primary key is (titleId, ordering) to support upsert on data refresh
CREATE TABLE IF NOT EXISTS title_akas (
    titleId VARCHAR(12),
    ordering INT,
    title VARCHAR(1000),
    region VARCHAR(10),
    language VARCHAR(10),
    types VARCHAR(100),
    attributes VARCHAR(255),
    isOriginalTitle TINYINT(1),
    PRIMARY KEY (titleId, ordering),
    INDEX idx_region (region),
    INDEX idx_title (title(100)),
    FULLTEXT INDEX ft_title (title)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- title.crew - Directors and writers
CREATE TABLE IF NOT EXISTS title_crew (
    tconst VARCHAR(12) PRIMARY KEY,
    directors TEXT,
    writers TEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- title.episode - TV episode to series mapping
CREATE TABLE IF NOT EXISTS title_episode (
    tconst VARCHAR(12) PRIMARY KEY,
    parentTconst VARCHAR(12),
    seasonNumber SMALLINT,
    episodeNumber INT,
    INDEX idx_parentTconst (parentTconst),
    INDEX idx_season_episode (parentTconst, seasonNumber, episodeNumber)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- title.principals - Cast and crew
-- Primary key is (tconst, ordering) to support upsert on data refresh
CREATE TABLE IF NOT EXISTS title_principals (
    tconst VARCHAR(12),
    ordering INT,
    nconst VARCHAR(12),
    category VARCHAR(50),
    job VARCHAR(500),
    characters TEXT,
    PRIMARY KEY (tconst, ordering),
    INDEX idx_nconst (nconst),
    INDEX idx_category (category),
    FULLTEXT INDEX ft_characters (characters)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- title.ratings - User ratings
CREATE TABLE IF NOT EXISTS title_ratings (
    tconst VARCHAR(12) PRIMARY KEY,
    averageRating DECIMAL(3,1),
    numVotes INT,
    INDEX idx_averageRating (averageRating),
    INDEX idx_numVotes (numVotes)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- name.basics - Person information
CREATE TABLE IF NOT EXISTS name_basics (
    nconst VARCHAR(12) PRIMARY KEY,
    primaryName VARCHAR(255),
    birthYear SMALLINT,
    deathYear SMALLINT,
    primaryProfession VARCHAR(255),
    knownForTitles VARCHAR(255),
    INDEX idx_primaryName (primaryName(100)),
    FULLTEXT INDEX ft_primaryName (primaryName)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Metadata table for tracking data freshness
CREATE TABLE IF NOT EXISTS imdb_metadata (
    id INT PRIMARY KEY DEFAULT 1,
    last_updated DATETIME,
    next_update DATETIME,
    update_interval_days INT DEFAULT 15,
    status VARCHAR(50),
    records_loaded BIGINT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO imdb_metadata (id, status, update_interval_days)
VALUES (1, 'pending', 15)
ON DUPLICATE KEY UPDATE id=id;
