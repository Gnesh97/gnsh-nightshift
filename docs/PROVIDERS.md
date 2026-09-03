# Providers

Providers are optional capabilities resolved during bootstrap. The core remains usable when phone, housing/motel, dispatch, appearance, evidence, target, or notify integrations are absent.

Provider IDs are allowlisted. A provider must expose availability/capabilities and typed operations. Calls are server-side, input is copied/validated, and failures become typed results. Optional failures degrade the related feature; they never authorize a booking or payment.

Capability groups include framework identity/lifecycle/job/duty/money, location resolution/reservation, phone notifications/routes, target/notify interaction, and best-effort dispatch/appearance/evidence. See docs/LOCATIONS.md, docs/PHONE.md, and docs/API.md.
