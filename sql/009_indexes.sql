CREATE INDEX idx_nightshift_bookings_status_created
    ON nightshift_bookings (status, created_at);
CREATE INDEX idx_nightshift_bookings_client_status
    ON nightshift_bookings (client_profile_id, status);
CREATE INDEX idx_nightshift_bookings_worker_status
    ON nightshift_bookings (worker_profile_id, status);
CREATE INDEX idx_nightshift_booking_events_booking_time
    ON nightshift_booking_events (booking_id, occurred_at);
CREATE INDEX idx_nightshift_booking_events_type
    ON nightshift_booking_events (event_type, occurred_at);
CREATE INDEX idx_nightshift_npc_profiles_availability
    ON nightshift_npc_profiles (availability);
CREATE INDEX idx_nightshift_npc_workers_state
    ON nightshift_npc_workers (state, profile_id);
CREATE INDEX idx_nightshift_locations_category_available
    ON nightshift_locations (category, available);
CREATE INDEX idx_nightshift_location_reservations_location_status
    ON nightshift_location_reservations (location_id, status);
CREATE INDEX idx_nightshift_location_reservations_booking_status
    ON nightshift_location_reservations (booking_id, status);
CREATE INDEX idx_nightshift_room_reservations_room_status
    ON nightshift_room_reservations (location_id, room_key, status);
CREATE INDEX idx_nightshift_deposits_booking_status
    ON nightshift_booking_deposits (booking_id, status);
CREATE INDEX idx_nightshift_payments_booking_status
    ON nightshift_payments (booking_id, status);
CREATE INDEX idx_nightshift_reviews_worker_created
    ON nightshift_reviews (worker_profile_id, created_at);
CREATE INDEX idx_nightshift_favorites_client
    ON nightshift_favorites (client_profile_id, created_at);
CREATE INDEX idx_nightshift_relationships_worker
    ON nightshift_client_worker_relationships (worker_profile_id, relationship_type);
