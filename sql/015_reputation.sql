ALTER TABLE nightshift_client_profiles
    ADD COLUMN IF NOT EXISTS reliability TINYINT UNSIGNED NOT NULL DEFAULT 50;

ALTER TABLE nightshift_npc_profiles
    ADD COLUMN IF NOT EXISTS review_count INT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE nightshift_client_worker_relationships
    ADD COLUMN IF NOT EXISTS trust_score TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_booking_id BIGINT UNSIGNED NULL;

CREATE INDEX IF NOT EXISTS idx_nightshift_relationship_last_booking
    ON nightshift_client_worker_relationships (last_booking_id);
