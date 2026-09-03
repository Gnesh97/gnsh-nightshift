ALTER TABLE nightshift_payments
    ADD COLUMN commission_snapshot JSON NULL AFTER provider_reference;
