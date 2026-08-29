ALTER TABLE nightshift_locations
    ADD COLUMN IF NOT EXISTS location_type VARCHAR(32) NOT NULL DEFAULT 'CONFIG_LOCATION',
    ADD COLUMN IF NOT EXISTS world_target_json LONGTEXT NULL,
    ADD COLUMN IF NOT EXISTS access_requirements_json LONGTEXT NULL,
    ADD COLUMN IF NOT EXISTS meeting_modes_json LONGTEXT NULL,
    ADD COLUMN IF NOT EXISTS max_travel_distance DOUBLE NULL,
    ADD COLUMN IF NOT EXISTS blocked_tags_json LONGTEXT NULL,
    ADD COLUMN IF NOT EXISTS reservable TINYINT(1) NOT NULL DEFAULT 1;

ALTER TABLE nightshift_location_reservations
    MODIFY reservation_key VARCHAR(256) NOT NULL,
    MODIFY location_id BIGINT UNSIGNED NULL,
    ADD COLUMN IF NOT EXISTS location_ref VARCHAR(160) NULL,
    ADD COLUMN IF NOT EXISTS active_key VARCHAR(256) NULL;

ALTER TABLE nightshift_location_reservations
    ADD UNIQUE KEY uq_nightshift_location_active_key (active_key);
