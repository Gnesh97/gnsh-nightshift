CREATE TABLE IF NOT EXISTS nightshift_worker_profiles (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    player_identifier VARCHAR(128) NOT NULL,
    character_id VARCHAR(128) NULL,
    display_name VARCHAR(80) NOT NULL,
    job_name VARCHAR(64) NULL,
    availability VARCHAR(32) NOT NULL DEFAULT 'offline',
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_worker_identity (player_identifier, character_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS nightshift_client_profiles (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    player_identifier VARCHAR(128) NOT NULL,
    character_id VARCHAR(128) NULL,
    display_name VARCHAR(80) NOT NULL,
    locale VARCHAR(16) NOT NULL DEFAULT 'en',
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_client_identity (player_identifier, character_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
