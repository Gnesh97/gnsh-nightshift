CREATE TABLE IF NOT EXISTS nightshift_locations (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    location_key VARCHAR(96) NOT NULL,
    category VARCHAR(32) NOT NULL,
    provider VARCHAR(64) NULL,
    coordinates_json LONGTEXT NULL,
    available TINYINT(1) NOT NULL DEFAULT 1,
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_location_key (location_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS nightshift_location_reservations (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    reservation_key VARCHAR(128) NOT NULL,
    location_id BIGINT UNSIGNED NOT NULL,
    booking_id BIGINT UNSIGNED NOT NULL,
    status VARCHAR(32) NOT NULL,
    hold_until DATETIME(3) NULL,
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_location_reservation_key (reservation_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS nightshift_room_reservations (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    reservation_key VARCHAR(128) NOT NULL,
    location_id BIGINT UNSIGNED NOT NULL,
    room_key VARCHAR(96) NOT NULL,
    booking_id BIGINT UNSIGNED NOT NULL,
    status VARCHAR(32) NOT NULL,
    hold_until DATETIME(3) NULL,
    version INT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_nightshift_room_reservation_key (reservation_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
