CREATE TABLE IF NOT EXISTS nightshift_venues (
  id varchar(96) NOT NULL, name varchar(160) DEFAULT NULL, category varchar(64) NOT NULL DEFAULT 'VENUE',
  capacity int unsigned NOT NULL DEFAULT 1, rooms_json longtext DEFAULT NULL, opening_hours_json longtext DEFAULT NULL,
  commission_rate decimal(5,2) NOT NULL DEFAULT 0, commission_fixed decimal(12,2) NOT NULL DEFAULT 0,
  available tinyint(1) NOT NULL DEFAULT 1, metadata_json longtext DEFAULT NULL,
  created_at timestamp NOT NULL DEFAULT current_timestamp(), updated_at timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (id), KEY idx_nightshift_venues_category_available (category, available)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS nightshift_venue_slots (
  id bigint unsigned NOT NULL AUTO_INCREMENT, venue_id varchar(96) NOT NULL, room_id varchar(96) DEFAULT NULL,
  booking_id varchar(96) NOT NULL, start_at bigint NOT NULL, end_at bigint NOT NULL, status varchar(24) NOT NULL DEFAULT 'RESERVED',
  created_at timestamp NOT NULL DEFAULT current_timestamp(), updated_at timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (id), UNIQUE KEY uq_nightshift_venue_slot_booking (venue_id, room_id, start_at, booking_id),
  KEY idx_nightshift_venue_slots_lookup (venue_id, room_id, start_at, end_at, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
