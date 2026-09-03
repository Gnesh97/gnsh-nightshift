CREATE TABLE IF NOT EXISTS nightshift_idempotency (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    scope VARCHAR(96) NOT NULL,
    idempotency_key VARCHAR(160) NOT NULL,
    fingerprint CHAR(8) NOT NULL,
    status ENUM('PENDING', 'COMPLETED') NOT NULL,
    result_json JSON NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    expires_at DATETIME(3) NOT NULL,
    version INT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_idempotency_scope_key (scope, idempotency_key),
    KEY idx_nightshift_idempotency_expires (expires_at),
    KEY idx_nightshift_idempotency_status (status, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
