CREATE TABLE IF NOT EXISTS nightshift_npc_profiles (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    profile_key VARCHAR(96) NOT NULL,
    display_name VARCHAR(80) NOT NULL,
    availability VARCHAR(32) NOT NULL DEFAULT 'available',
    traits LONGTEXT NULL,
    tags LONGTEXT NULL,
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_npc_profile_key (profile_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS nightshift_npc_workers (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    worker_key VARCHAR(96) NOT NULL,
    profile_id BIGINT UNSIGNED NOT NULL,
    state VARCHAR(32) NOT NULL DEFAULT 'available',
    current_location_id BIGINT UNSIGNED NULL,
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_npc_worker_key (worker_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
