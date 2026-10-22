# ServiceHub database

PostgreSQL 18+ schema for ServiceHub. The design and the reasoning behind each table
are in [`../docs/schema-design.md`](../docs/schema-design.md).

> **Status:** the SQL has not been run yet. Testing (and running it in Docker) is the next step.

## Layout

| Path | What it is |
|---|---|
| `migrations/0001_core_schema.sql` | users, categories, providers, provider_categories, addresses, services, provider_services |
| `migrations/0002_seed_catalog.sql` | Reference data: the 4 trade categories and the 14-service catalog (fixed IDs) |
| `migrations/0003_scheduling_and_bookings.sql` | providers.time_zone, working hours, time off, bookings (no double booking), booking_events |
| `migrations/0004_reviews_complaints_verifications.sql` | Rating counters, reviews, complaints, verification attempts |
| `migrations/0005_auth_payments_ai_outbox.sql` | sessions, auth_tokens, Stripe columns, payments, stripe_events, damage assessments, outbox |
| `seeds/dev_seed.sql` | Sample marketplace data for local development (**never production**) |
| `tests/0001_core_schema.test.sql` | Constraint tests for 0001–0002 (tests for 0003–0005 still to write) |

Migrations run **in number order**, and each one is a single transaction: it either
applies completely or not at all. Never edit a migration that has already been applied
somewhere; add a new numbered file instead.

## Running it (once a database is available)

Create an empty database, then apply the migrations, the seed and the tests in order:

```bash
createdb servicehub_dev
for f in migrations/*.sql; do psql -v ON_ERROR_STOP=1 -d servicehub_dev -f "$f"; done
psql -v ON_ERROR_STOP=1 -d servicehub_dev -f seeds/dev_seed.sql
psql -v ON_ERROR_STOP=1 -d servicehub_dev -f tests/0001_core_schema.test.sql
```

`ON_ERROR_STOP=1` makes `psql` stop at the first error instead of carrying on.

## Conventions

- IDs: `uuidv7()` for user-generated rows; hand-assigned `smallint` for lookup tables
  (categories `1–4`, services `category_id * 100 + n`).
- Money is integer cents (`price_cents`). Times are `timestamptz`; booking slots are
  `tstzrange` with `[start, end)` bounds.
- Status columns are Postgres enums with lowercase values.
- Every table with `updated_at` has a trigger that sets it.
- The app identifies who is acting for audit triggers with
  `SET LOCAL app.actor_id = '<user id>'` inside the transaction.
