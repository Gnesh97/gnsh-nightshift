# Worker Mode

Worker Mode lets a worker opt in to customer opportunities, negotiate a quote, accept a booking, travel, attend an appointment, and complete settlement.

The server flow is AVAILABLE -> customer opportunity -> OFFERED -> COUNTERED (optional) -> ACCEPTED -> RESERVED -> TRAVELLING -> ARRIVED -> ACTIVE -> SETTLED.

The server owns worker identity, patience/round limits, quote expiry, booking/location locks, appointment tokens, duration, and settlement. A worker must explicitly opt in before receiving customers. Accepted prices are frozen snapshots.

Expired quotes, invalid negotiation IDs, missing booking IDs, unavailable settlement, invalid worker mode, and replayed tokens return typed errors. Retry only with a fresh server result; never fabricate IDs or reuse expired quotes. Development settlement is dry-run only.
