# Security

NightShift is server-authoritative and fail-closed at trust boundaries.

- Validate and bound every NUI, event, export, provider, and framework input.
- Use normalized identity and ownership checks; never trust client source claims beyond runtime source.
- Use idempotency keys for economic and state-changing operations.
- Use short-lived, booking/actor/location-bound action tokens where enforced.
- Apply source/method rate limits before NUI dispatch.
- Expose public worker DTOs only; do not leak traits, appearance internals, payment data, credentials, or tokens.
- Treat logs, external providers, target systems, dispatch, and evidence integrations as non-authoritative.

Security defaults are in config/security.lua. Production payment/deposit enablement requires a durable, atomic provider with idempotency support. Do not enable development settlement for real-money flows.
