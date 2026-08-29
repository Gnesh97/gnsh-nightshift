ALTER TABLE nightshift_bookings
    ADD COLUMN IF NOT EXISTS quote_id VARCHAR(128) NULL,
    ADD COLUMN IF NOT EXISTS quote_expires_at DATETIME(3) NULL,
    ADD COLUMN IF NOT EXISTS agreed_quote_id VARCHAR(128) NULL;

CREATE INDEX IF NOT EXISTS idx_nightshift_booking_quote_id ON nightshift_bookings (quote_id);
