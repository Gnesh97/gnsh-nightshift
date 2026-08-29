ALTER TABLE nightshift_bookings
    ADD COLUMN IF NOT EXISTS initiator_type VARCHAR(16) NULL,
    ADD COLUMN IF NOT EXISTS client_type VARCHAR(16) NULL,
    ADD COLUMN IF NOT EXISTS client_ref VARCHAR(160) NULL,
    ADD COLUMN IF NOT EXISTS worker_type VARCHAR(16) NULL,
    ADD COLUMN IF NOT EXISTS worker_ref VARCHAR(160) NULL,
    ADD COLUMN IF NOT EXISTS meeting_mode VARCHAR(32) NULL,
    ADD COLUMN IF NOT EXISTS location_type VARCHAR(32) NULL,
    ADD COLUMN IF NOT EXISTS location_ref VARCHAR(160) NULL,
    ADD COLUMN IF NOT EXISTS quote_minor BIGINT UNSIGNED NULL,
    ADD COLUMN IF NOT EXISTS quote_currency CHAR(3) NULL,
    ADD COLUMN IF NOT EXISTS quoted_at DATETIME(3) NULL,
    ADD COLUMN IF NOT EXISTS agreed_price_minor BIGINT UNSIGNED NULL,
    ADD COLUMN IF NOT EXISTS agreed_currency CHAR(3) NULL,
    ADD COLUMN IF NOT EXISTS agreed_at DATETIME(3) NULL,
    ADD COLUMN IF NOT EXISTS external_reference VARCHAR(160) NULL,
    ADD COLUMN IF NOT EXISTS started_at DATETIME(3) NULL,
    ADD COLUMN IF NOT EXISTS ended_at DATETIME(3) NULL;

ALTER TABLE nightshift_booking_events
    ADD COLUMN IF NOT EXISTS actor_type VARCHAR(16) NULL,
    ADD COLUMN IF NOT EXISTS actor_ref VARCHAR(160) NULL,
    ADD COLUMN IF NOT EXISTS old_state VARCHAR(32) NULL,
    ADD COLUMN IF NOT EXISTS new_state VARCHAR(32) NULL,
    ADD COLUMN IF NOT EXISTS reason VARCHAR(160) NULL,
    ADD COLUMN IF NOT EXISTS metadata_json LONGTEXT NULL;

CREATE INDEX IF NOT EXISTS idx_nightshift_booking_state ON nightshift_bookings (status, updated_at);
CREATE INDEX IF NOT EXISTS idx_nightshift_booking_external_reference ON nightshift_bookings (external_reference);
CREATE INDEX IF NOT EXISTS idx_nightshift_booking_events_timeline ON nightshift_booking_events (booking_id, id);
