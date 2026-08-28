# Repository Conventions

Repositories are the only persistence-facing domain boundary. They receive a normalized database adapter and return `NightShift.Result` values; services must not depend on oxmysql globals or SQL strings.

## Row mapping

- `findById` and `findAll` copy database rows before invoking the repository mapper.
- Mappers return a domain table. Mapper exceptions, nil results, and malformed values return `MAPPING_FAILED`.
- Database column names are not exposed as authority decisions; mapping is structural only.

## Query and identifiers

- Table, ID, and selected-column identifiers must match `[A-Za-z_][A-Za-z0-9_]*` and are quoted by the base repository.
- Values always travel through adapter parameters (`?` placeholders). No value interpolation is allowed.
- Update fields are sorted before SQL generation for deterministic statements.

## Versioned updates

Mutable aggregate updates use:

```sql
UPDATE <table>
SET <changes>, version = version + 1, updated_at = CURRENT_TIMESTAMP(3)
WHERE <id_column> = ? AND version = ?
```

An affected-row count greater than zero returns the next version. A zero count is followed by an existence read so the repository distinguishes:

- `REPOSITORY_NOT_FOUND` — no row exists for the ID.
- `VERSION_CONFLICT` — row exists, but expected version is stale.
- `REPOSITORY_STATE_UNKNOWN` — existence could not be verified.

This conditional update reduces lost-update risk. Higher-level services own retries, state transitions, and business policy.

## Transaction and business boundaries

- Repositories map rows and perform persistence operations only.
- Services own business invariants, authorization, idempotency policy, and multi-repository transaction composition.
- Repository errors preserve stable codes and never expose driver credentials or raw SQL values.
