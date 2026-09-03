# S16 Client Mode Vertical Slice

This is the release-test scenario for the client-facing marketplace flow. The
server owns the worker selection, location, quote, booking state, travel,
session, settlement, and history records. The NUI only submits bounded
identifiers and receives privacy-safe DTOs.

## Preconditions

- The resource is running in a development environment with the settlement
  dry-run adapter or a configured idempotent settlement provider.
- At least three active NPC worker profiles are available in the selected
  district, and one worker is marked persistent/available.
- \`standard\` is present in the service catalog and supports the selected
  meeting mode and typed location.
- A server-registered motel or configured location is available.
- The player identity and client profile repository are available.

## COME_TO_ME flow

1. Open the NUI and load the marketplace list.
2. Confirm that at least three NPC worker cards are returned and that private
   profile fields are absent.
3. Select one persistent worker and the \`standard\` package.
4. Choose \`COME_TO_ME\` and a registered motel/config location. Never submit
   client coordinates as a location selector.
5. Request a quote. Verify the server returns a bounded amount, currency,
   duration, quote ID, and expiry/ETA data.
6. Confirm with the quote ID only. Verify the booking is \`RESERVED\`, the NPC
   worker is reserved, the typed location is held, and the configured deposit
   policy is applied.
7. Start travel and verify the booking enters \`TRAVELLING\` with one
   server-owned travel key.
8. Request and confirm the NPC spawn using the returned generation token.
   Physical spawn must remain bound to the travel key, booking, worker profile,
   and server-selected candidate.
9. Submit the arrival payload. The server validates entity generation,
   travel context, and proximity before moving the booking to \`ARRIVED\`.
10. Start the appointment session and retain the one-time session token.
11. Complete before accepting a result only after the configured minimum
    duration has elapsed. The server performs \`COMPLETED -> SETTLED\`.
12. Refresh client history and verify one settled entry with no internal
    worker/profile/quote secrets.
13. Retry completion and repeat the read after a service restart. Both must
    return the existing outcome and must not create a second settlement.

## Expected result

- The critical scenario reaches \`SETTLED\` once.
- Invalid location, quote, owner, generation, proximity, duration, token, and
  replay requests fail with typed errors.
- The worker and location locks are released after settlement.
- History is scoped to the requesting client and contains only the safe read
  model.

## Automated coverage

The COME_TO_ME orchestration contracts live in
\`tests/s13_client_mode_contracts.lua\`; client booking, NUI routing, and read
model coverage live in \`tests/s12_client_booking_commands.lua\`,
\`tests/s12_client_booking_contracts.lua\`, and
\`tests/s13_client_mode_contracts.lua\`. The full suite is run with
\`lua tests/run.lua\`.
