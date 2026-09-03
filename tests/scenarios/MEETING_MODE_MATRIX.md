# S16 Meeting Mode Regression Matrix

Every meeting mode must use the same booking, quote, identity, travel,
appointment, settlement, and replay contracts while keeping its own movement
rules.

| Check | COME_TO_ME | PICKUP | MEET_THERE |
| --- | --- | --- | --- |
| Server-owned typed location | NPC destination | Safe roadside pickup | Shared meeting destination |
| First travel | NPC → client | NPC → pickup | NPC → meeting point |
| Arrival barrier | NPC arrival | Client claims NPC, then destination leg | Client + NPC both arrived |
| Session gate | \`ARRIVED\` only | \`ARRIVED\` only | \`ARRIVED\` only after both sides |
| Settlement | Unified appointment settlement | Unified appointment settlement | Unified appointment settlement |
| Cancellation cleanup | Worker/location/deposit/travel | Worker/location/vehicle/travel | Worker/location/deposit/travel |
| Disconnect cleanup | Interrupt and release | Interrupt and release | Interrupt and release |
| Invalid location behavior | Fail closed | Fail closed | Fail closed |

## Regression assertions

- Each mode rejects an actor that does not own the player side of the booking.
- Each mode rejects arbitrary coordinates, mismatched typed references, stale
  versions, stale quotes, invalid generation tokens, and replayed session
  tokens.
- Only one settlement idempotency key is committed per booking.
- A single arrival never starts an appointment session.
- Cancellation and disconnect release every mode-specific reservation.

## Automated coverage

- \`tests/s13_client_mode_contracts.lua\` — COME_TO_ME.
- \`tests/s14_pickup_contracts.lua\` — PICKUP, vehicle binding, and dual-leg
  progression.
- \`tests/s15_dual_travel_contracts.lua\` — MEET_THERE dual arrival, grace,
  no-show, session, settlement, and retry behavior.

Run the matrix contracts with:

\`\`\`text
lua tests/run.lua
\`\`\`
