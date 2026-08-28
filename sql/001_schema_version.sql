CREATE TABLE IF NOT EXISTS nightshift_schema_migrations (
    version INT UNSIGNED NOT NULL,
    name VARCHAR(128) NOT NULL,
    checksum CHAR(8) NOT NULL,
    applied_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (version),
    UNIQUE KEY uq_nightshift_schema_migrations_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
