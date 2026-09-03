# Security

NightShift is server-authoritative and fail-closed at trust boundaries.

- Validate and bound every NUI, event, export, provider, and framework input.
- Use normalized identity and ownership checks; never trust client source claims beyond runtime source.
- Use idempotency keys for economic and state-changing operations.
- Use short-lived, booking/actor/action-bound action tokens for every critical
  transition. Tokens are one-time, may include an entity generation binding,
  and are consumed server-side before dispatch. Generation-bound refreshes are
  accepted only after the server NPC registry confirms the booking, travel,
  profile, and generation tuple; the browser cannot mint entity generations.
- Action-token enforcement is on by default. The only opt-out is the explicit
  `developmentOptOut` flag while runtime environment is `development`; this
  flag is ignored in production.
- Review reads are participant-scoped. Favorite, relationship, history,
  profile, and entity reads must return sanitized DTOs and never accept a
  client-supplied actor identity.
- Apply source/method rate limits before NUI dispatch.
- Expose public worker DTOs only; do not leak traits, appearance internals, payment data, credentials, or tokens.
- Treat logs, external providers, target systems, dispatch, and evidence integrations as non-authoritative.

Security defaults are in config/security.lua. Production payment/deposit enablement requires a durable, atomic provider with idempotency support. Do not enable development settlement for real-money flows.
