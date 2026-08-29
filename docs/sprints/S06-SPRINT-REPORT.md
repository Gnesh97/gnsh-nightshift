# S06 Sprint Report — Pricing, Settlement, Deposit & Refund

**Date:** 2026-08-29

**Status:** PASS (local contracts, schema/migration wiring, and static verification; live provider-money smoke deferred)

**Scope:** NS-060, NS-061, NS-062, NS-063, NS-064, NS-065 only

## Completed tasks

- **NS-060 — Service Catalog:** added a configurable abstract package catalog with SHORT/STANDARD/PREMIUM/PRIVATE/VIP defaults, positive minor-unit prices, duration and reputation requirements, meeting-mode/location compatibility, and feature-aware BookingService resolution. Client package price fields are projected into a server catalog snapshot.
- **NS-061 — Pricing Engine:** added server-authoritative quote calculation from package base price, NPC class, district, time, demand, reputation, travel fee, and location fee. Modifiers are bounded, totals are clamped, line items are returned for explanation, quote IDs are unique per service instance, and quotes carry a server-clock expiry. Client `amountMinor` values are never trusted.
- **NS-062 — Price Freeze:** added the immutable PriceQuote domain with booking binding, expiry, accepted snapshots, and no post-acceptance recalculation. BookingService accepts package IDs, applies server quotes, rejects expired quotes, and persists quote ID/expiry/agreed quote ID through migration `012_pricing_snapshots.sql`.
- **NS-063 — Deposit Service:** added validated HELD/PENDING/UNKNOWN/REFUNDED/PARTIALLY_REFUNDED/RETAINED states, repository persistence, server-derived hold amounts, stable `deposit:{booking_id}` intent keys, idempotent replay, insufficient-funds checks, and debit compensation when validation or persistence fails.
- **NS-064 — Settlement Service:** added payment intent persistence and frozen-price fingerprint validation. Settlement requires COMPLETED, persists the unique intent before the provider call, requires explicit atomic-transfer plus durable idempotency capability, supports an optional commission hook, finalizes deposits, and calls the canonical BookingService transition only after financial success. Failed/unknown outcomes never mark a booking SETTLED.
- **Post-commit recovery:** retries of a SUCCEEDED payment intent resume deposit/commission finalization before transitioning the booking, so a post-provider failure does not issue a second transfer or skip required finalization.
- **NS-065 — Cancellation & Refund Policy:** added configurable state-aware percentages for pre-assignment, scheduled, assigned, en-route, travelling, arrived, active, completed, and settled states. Refunds use the server clock and frozen booking price, ignore client amount/account fields, persist idempotent refund intents, and retain deposits when no automatic refund is due.
- **Money boundary hardening:** extended the normalized money adapter methods to forward stable idempotency keys (and debit/credit/reverse suffixes for any future compensatable split-leg implementation) without exposing provider-native objects to the services.

## Changed files

- `config/services.lua`
- `config/pricing.lua`
- `config/cancellation.lua`
- `config/config.lua`
- `config/features.lua`
- `shared/errors.lua`
- `shared/validators.lua`
- `server/domain/price_quote.lua`
- `server/domain/deposit.lua`
- `server/domain/booking.lua`
- `server/repositories/booking_repository.lua`
- `server/repositories/deposit_repository.lua`
- `server/repositories/payment_repository.lua`
- `server/services/service_catalog.lua`
- `server/services/pricing_service.lua`
- `server/services/booking_service.lua`
- `server/services/deposit_service.lua`
- `server/services/settlement_service.lua`
- `server/services/refund_service.lua`
- `server/adapters/money/interface.lua`
- `server/bootstrap.lua`
- `server/core/migrations.lua`
- `fxmanifest.lua`
- `sql/012_pricing_snapshots.sql`
- `tests/s06_financial_contracts.lua`
- `tests/provider_contracts.lua`
- `tests/run.lua`
- `tests/migrations_contracts.lua`
- `tests/schema_contracts.lua`
- `CHANGELOG.md`

## Tests and verification

- `C:\Users\Gnesh\AppData\Local\Programs\Lua\5.5.1\lua.exe tests/run.lua` passes NS-010/011, NS-020/023, NS-030..037, NS-040..043, NS-050..054, and NS-060..065 contracts.
- S06 coverage includes package compatibility/requirements, deterministic pricing, client-total rejection, modifier clamping, quote expiry/immutability, booking snapshot round-trip, double deposit capture, insufficient funds, compensation paths, settlement replay/failure/canonical-transition/post-commit recovery checks, commission hook behavior, and server-computed double refunds.
- All 80 Lua files parse with `luac -p`; `git diff --check` passes.
- Migration/schema contracts verify that `012_pricing_snapshots.sql` is registered as migration 12 and preserves existing migration checksums.

## Live FiveM / provider-money smoke

- The previously verified runtime persistence gate remains healthy at migration 11. S06 adds migration 12, so the running FXServer must be restarted with `nightshift_persistence=true` to apply it and should then report `migration=12`.
- No live financial charge/refund was executed. The current framework money adapters do not advertise durable idempotency and atomic transfer capabilities; S06 services therefore fail closed for those operations until a provider-specific implementation supplies them. This is intentional and prevents unsafe duplicate or partial money effects.

## Security / recovery

- Package, price, currency, quote expiry, deposit amount, settlement amount/account, and refund amount are server-owned; request payloads are copied and client financial fields are ignored.
- Durable intent keys are persisted before external money calls. Replay uses the same key, and payment/deposit/refund services reject providers without the capability contract needed for safe idempotency.
- Booking status changes to SETTLED only after a successful financial result and canonical BookingService transition. Unknown/declined/persistence-failure outcomes remain recoverable markers.
- Deposit hold persistence failures compensate the debit where possible and return an explicit unknown outcome when compensation itself cannot be confirmed.

## Known issues and deferred work

- Provider-specific idempotency/atomic-transfer implementations, public network handlers, client UI, and live player financial flows remain scheduled for later phases.
- A financial commit followed by a booking/timeline persistence failure returns `paymentCommitted=true` for reconciliation; a future cross-table transaction/reconciliation worker can close that boundary.
- Migration 012 has not yet been applied to the running user server in this turn; apply it through the normal controlled resource restart before exercising persistent quote snapshots.

## Exit Gate

- [x] Service catalog and BookingService package authority.
- [x] Dynamic server quote with line-item explanation and expiry.
- [x] Immutable accepted price snapshot and migration 012 persistence.
- [x] Deposit hold/release/refund/retain idempotency and compensation.
- [x] Settlement intent, frozen-price use, canonical transition, and failure markers.
- [x] State-aware server-computed refund and idempotent replay.
- [x] Local contracts, parser, schema/migration, and diff verification.
- [ ] Live provider-money smoke (blocked intentionally by missing provider capability contract, not by a code/test failure).

**S06 Exit Gate: PASS for local implementation and safety contracts. Live financial/provider smoke remains deferred until the adapters expose durable idempotency and atomic-transfer support; S07 remains pending.**
