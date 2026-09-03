CREATE INDEX IF NOT EXISTS idx_nightshift_bookings_scheduled_due
    ON nightshift_bookings (status, scheduled_at, id);

CREATE INDEX IF NOT EXISTS idx_nightshift_bookings_no_show_due
    ON nightshift_bookings (status, updated_at, id);
