# ServiceHub — Database Schema Design

Working design for the Postgres schema rebuild. Tables are agreed here first,
then turned into migrations. Status: **in progress**.

## Conventions

- Primary keys: `UUID` for user-generated data; hand-assigned `smallint` for fixed lookup tables.
- Every table has `created_at` / `updated_at` (`timestamptz`) unless noted.
- Status-like columns use Postgres enums, lowercase values.
- Passwords are stored only as argon2id hashes.

---

## users — everyone who logs in

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `email` | citext | UNIQUE, case-insensitive |
| `email_verified_at` | timestamptz | null until verified |
| `password_hash` | text | argon2id |
| `full_name` | text | |
| `phone` | text | E.164 format |
| `dob` | date | sensitive data — never returned except to the owner |
| `role` | enum | `customer`, `provider`, `admin` |
| `verification_status` | enum | `unverified`, `pending`, `verified`, `rejected` |
| `avatar_url` | text | |
| `created_at`, `updated_at` | timestamptz | |
| `deleted_at` | timestamptz | soft delete |

Decisions:
- Email is unique but **not** the PK (emails change; avoids spreading personal data through foreign keys).
- Role (account type) is separate from trade (category).
- Addresses live in their own table.

## categories — predefined trade list

| Column | Type | Notes |
|---|---|---|
| `id` | smallint | PK, **hand-assigned** (stable across all environments) |
| `slug` | text | UNIQUE, URL-safe (`plumbing`) |
| `name` | text | display name |
| `icon` | text | |
| `description` | text | |

Decisions:
- IDs are assigned manually in the seed/migration, never auto-generated.
- `soc_code` dropped (not needed yet).

## providers — business details, one per provider user

| Column | Type | Notes |
|---|---|---|
| `user_id` | UUID | PK + FK → `users.id` (enforces 1:1) |
| `business_name` | text | |
| `description` | text | |
| `years_experience` | smallint | |
| `license_number` | text | optional |
| `service_radius_km` | smallint | |
| `is_active` | boolean | provider can pause taking jobs |
| `created_at`, `updated_at` | timestamptz | |

## provider_categories — trades per provider

| Column | Type | Notes |
|---|---|---|
| `provider_id` | UUID | FK → `providers.user_id` |
| `category_id` | smallint | FK → `categories.id` |

PK: (`provider_id`, `category_id`).

> **Open question:** one trade per provider, or many? If one, drop this table
> and add `category_id` to `providers`.

---

## Still to design

- addresses
- services / provider offers (catalog + provider pricing)
- availability (weekly hours + exceptions)
- bookings (time range + no-overlap constraint, address snapshot, price in cents)
- reviews
- complaints
- verifications (attempt history)
- auth: sessions / refresh tokens, email-verification & password-reset tokens
- payments, booking_events (audit)
