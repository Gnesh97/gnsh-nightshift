CREATE TABLE IF NOT EXISTS nightshift_blacklist (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    scope_type VARCHAR(16) NOT NULL,
    scope_ref VARCHAR(160) NOT NULL,
    worker_profile_id BIGINT UNSIGNED NOT NULL,
    reason VARCHAR(32) NOT NULL,
    active TINYINT(1) NOT NULL DEFAULT 1,
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_blacklist_scope_worker (scope_type, scope_ref, worker_profile_id),
    INDEX idx_nightshift_blacklist_lookup (scope_type, scope_ref, active, worker_profile_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
