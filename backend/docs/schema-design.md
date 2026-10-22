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
| `email` | citext | UNIQUE among active (non-deleted) accounts, case-insensitive |
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
| `role` | enum | always `provider`; with FK (`user_id`, `role`) → `users` it guarantees the user really is a provider |
| `business_name` | text | |
| `description` | text | |
| `years_experience` | smallint | |
| `license_number` | text | optional |
| `service_radius_km` | smallint | |
| `is_active` | boolean | provider can pause taking jobs |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- A provider profile can only exist for a user with role `provider`, and that user can't be
  demoted while the profile exists (enforced by the database).

## provider_categories — trades per provider

| Column | Type | Notes |
|---|---|---|
| `provider_id` | UUID | FK → `providers.user_id` |
| `category_id` | smallint | FK → `categories.id` |

PK: (`provider_id`, `category_id`).

Decision: providers can work in **many** trades.

## addresses — a user's saved addresses (US only for now)

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `user_id` | UUID | FK → `users.id`, cascade on delete |
| `label` | text | "Home", "Parents"; 1–50 chars |
| `line1` | text | street and number |
| `line2` | text | apt / unit, optional |
| `city` | text | |
| `state` | char(2) | `NJ`, `NY` (uppercase) |
| `postal_code` | text | `07102` or `07102-1234` — text, not a number |
| `country` | char(2) | `US` only for now |
| `latitude`, `longitude` | numeric(9,6) | both set or both null |
| `is_default` | boolean | at most one default per user |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- At most one default address per user (partial unique index).
- Bookings copy the address at booking time, so editing or deleting an address never changes past bookings.
- Coordinates stored now for "providers near me"; can move to PostGIS later.

## services — the shared catalog of bookable jobs

| Column | Type | Notes |
|---|---|---|
| `id` | smallint | PK, **hand-assigned**: `category_id * 100 + n` (101, 102, … 201, …) |
| `category_id` | smallint | FK → `categories.id` |
| `slug` | text | UNIQUE, URL-safe (`drain-cleaning`) |
| `name` | text | "Drain cleaning" |
| `description` | text | |
| `default_duration_minutes` | smallint | suggested starting value; 15-minute steps |
| `price_unit` | enum | `fixed`, `hourly` |
| `is_active` | boolean | retire a service without deleting it |
| `sort_order` | smallint | display order in the UI |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- `(category_id, name)` is unique — no duplicate names within a trade.
- Catalog is reference data, seeded in a migration (`0002_seed_catalog.sql`).

## provider_services — a provider's offer for a catalog service

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK; bookings will reference this |
| `provider_id` | UUID | FK → `providers.user_id` |
| `service_id` | smallint | FK → `services.id` |
| `category_id` | smallint | copied from the service; used by the trade check |
| `price_cents` | integer | > 0, max $100k |
| `duration_minutes` | smallint | > 0, max 24h, 15-minute steps |
| `description` | text | optional, max 1000 chars |
| `is_active` | boolean | pause one offer without deleting it |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- One offer per provider per service: UNIQUE (`provider_id`, `service_id`).
- Providers can only offer services in their own trades, enforced by two composite FKs:
  (`service_id`, `category_id`) → `services`, and (`provider_id`, `category_id`) → `provider_categories`.
- Bookings copy the price, so later price changes never affect past bookings.

Implemented in `backend/db/migrations/0001_core_schema.sql` and `0002_seed_catalog.sql`;
constraint tests in `backend/db/tests/0001_core_schema.test.sql`.

---

---

# Scheduling, bookings, trust, auth and payments

Implemented in `backend/db/migrations/0003_scheduling_and_bookings.sql`,
`0004_reviews_complaints_verifications.sql` and `0005_auth_payments_ai_outbox.sql`.
Not run or tested yet.

## Change to providers — add a time zone

| Column | Type | Notes |
|---|---|---|
| `time_zone` | text | IANA name, e.g. `America/New_York`; default `America/New_York` |

Decisions:
- Working hours are **local wall-clock times** ("9 AM"), so we need the provider's time zone
  to turn them into real moments. Bookings themselves are stored as absolute times (`timestamptz`).

## provider_working_hours — a provider's regular weekly schedule

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `provider_id` | UUID | FK → `providers.user_id`, cascade on delete |
| `day_of_week` | smallint | ISO: 1 = Monday … 7 = Sunday |
| `start_time` | time | local time, e.g. `09:00` |
| `end_time` | time | local time, must be after `start_time` |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- Several rows per day are allowed, so a lunch break is just two rows (09:00–12:00, 13:00–17:00).
- Ranges on the same day can't overlap (exclusion constraint).
- No overnight shifts for now: `end_time > start_time`.
- No row for a day = not working that day.

## provider_time_off — exceptions to the weekly schedule

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `provider_id` | UUID | FK → `providers.user_id`, cascade on delete |
| `period` | tstzrange | absolute start/end, e.g. a vacation week or one afternoon |
| `reason` | text | optional, private to the provider |
| `created_at` | timestamptz | |

Decisions:
- One table covers vacations, sick days and blocked afternoons.
- A provider's time-off periods can't overlap each other (exclusion constraint).
- Available slots = working hours − time off − existing bookings, computed by a query, never stored.
  This replaces the old `availability_slots` table, which went stale and was never linked to bookings.

## bookings — the core transaction

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `customer_id` | UUID | FK → `users.id` (any user can book, providers included) |
| `provider_id` | UUID | FK → `providers.user_id` |
| `provider_service_id` | UUID | FK → `provider_services.id`; must belong to `provider_id` |
| `status` | enum | `pending`, `confirmed`, `completed`, `cancelled`, `declined` |
| `scheduled_period` | tstzrange | start and end of the job |
| `price_cents` | integer | **snapshot** of the offer price at booking time |
| `price_unit` | enum | snapshot: `fixed` or `hourly` |
| `address_line1`, `address_line2`, `address_city`, `address_state`, `address_postal_code` | text | **snapshot** of the job address |
| `address_latitude`, `address_longitude` | numeric(9,6) | snapshot, optional |
| `address_id` | UUID | FK → `addresses.id`, set null if that address is later deleted |
| `customer_notes` | text | "Gate code 1234", max 1000 chars |
| `cancellation_reason` | text | required when cancelled or declined |
| `confirmed_at`, `completed_at`, `cancelled_at` | timestamptz | when each transition happened |
| `reminder_sent_at` | timestamptz | so the reminder job sends each reminder once, even with many servers |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- **No double booking, enforced by Postgres:** an exclusion constraint rejects any two
  `pending`/`confirmed` bookings of the same provider whose `scheduled_period`s overlap.
  Cancelled/declined bookings free the slot automatically.
- `provider_service_id` must belong to `provider_id` (composite FK, same trick as provider_services).
- A user can't book themselves (`customer_id <> provider_id`).
- Price and address are copied in, so later edits never change a past booking.
- Status timestamps must match the status (e.g. `completed` ⇒ `completed_at` is set).
- Payment fields are left out; they'll live in a separate `payments` table later.
- Checking against working hours and time off happens in the booking transaction
  (Postgres can't express a constraint across those tables).

## booking_events — status history (append-only audit log)

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | PK, auto-increment (sequential is fine for a log) |
| `booking_id` | UUID | FK → `bookings.id` |
| `from_status` | enum | null for the creation event |
| `to_status` | enum | |
| `actor_user_id` | UUID | FK → `users.id`; null = the system (e.g. auto-complete job) |
| `note` | text | optional |
| `created_at` | timestamptz | |

Decisions:
- Rows are written **by a trigger** on `bookings`, so no code path can change a status without leaving a record.
- The same trigger enforces the allowed transitions:
  `pending → confirmed | declined | cancelled`, `confirmed → completed | cancelled`.
  `completed`, `cancelled` and `declined` are final.
- The app tells the trigger who is acting with `SET LOCAL app.actor_id = '<user id>'` inside the transaction.
- Never updated or deleted — it's a history.

## reviews — a customer's rating of a completed booking

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `booking_id` | UUID | FK → `bookings.id`, UNIQUE (one review per booking) |
| `reviewer_id` | UUID | must be that booking's customer |
| `provider_id` | UUID | copied from the booking; must match it |
| `rating` | smallint | 1–5 |
| `comment` | text | optional, max 2000 chars |
| `provider_reply` | text | optional public reply, max 2000 chars |
| `provider_replied_at` | timestamptz | set when the provider replies |
| `is_hidden` | boolean | moderation: hidden by an admin, kept for the record |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- Reviewer and provider are checked against the booking with composite FKs
  (`booking_id`, `reviewer_id`) → `bookings` (`id`, `customer_id`) and
  (`booking_id`, `provider_id`) → `bookings` (`id`, `provider_id`), so nobody can review a booking that isn't theirs.
- Only `completed` bookings can be reviewed (checked by a trigger, since it depends on the booking's status).
- **Add to `providers`:** `rating_count` (int) and `rating_sum` (int), kept up to date by a trigger on
  `reviews` in the same transaction. The average is `rating_sum / rating_count`. This replaces the old
  read-calculate-write in JavaScript, where two reviews at once could lose an update. Hidden reviews don't count.

## complaints — support tickets

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `ref_no` | bigint | auto-increment, internal |
| `reference` | text | generated from `ref_no`: `CMP-000123`; UNIQUE, shown to users |
| `user_id` | UUID | FK → `users.id`, who filed it |
| `booking_id` | UUID | FK → `bookings.id`, optional |
| `type` | enum | `complaint`, `incident`, `feedback` |
| `subject` | text | 5–200 chars, free-form |
| `description` | text | 10–5000 chars |
| `priority` | enum | `low`, `medium`, `high`, `urgent` |
| `status` | enum | `open`, `in_progress`, `resolved`, `closed` |
| `assigned_to` | UUID | FK → `users.id` (an admin), optional |
| `resolution_note` | text | required when resolved |
| `resolved_at` | timestamptz | set when resolved |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- The `CMP-000123` reference is a generated column, not app code, so it can never be missing or duplicated.
- If a booking is attached, the complainant must be that booking's customer or provider (checked by a trigger).
- All enums are lowercase, unlike the old `OPEN` / `MEDIUM` values.
- `resolved` / `closed` ⇒ `resolved_at` is set (CHECK).
- A conversation thread (messages between user and support) can be added later as `complaint_messages`.

## verifications — identity verification attempts (full history)

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `user_id` | UUID | FK → `users.id` |
| `document_type` | enum | `passport`, `drivers_license`, `state_id` |
| `document_key` | text | storage key of the ID image in a **private** bucket (not a public URL) |
| `selfie_key` | text | storage key of the selfie, private |
| `status` | enum | `in_progress`, `pending_review`, `approved`, `rejected`, `expired` |
| `extracted_full_name` | text | from OCR |
| `extracted_dob` | date | from OCR; sensitive data |
| `document_number_last4` | text | only the last 4 digits, never the full number |
| `document_expires_on` | date | from OCR |
| `face_match_score` | numeric(5,2) | 0–100 |
| `registry_check_status` | enum | `clear`, `match_found`, `unavailable` |
| `ocr_result`, `face_match_result`, `registry_check_result` | jsonb | raw responses from the AI service, kept for audit |
| `rejection_reason` | text | required when rejected |
| `submitted_at` | timestamptz | when the user finished uploading |
| `reviewed_at` | timestamptz | when approved/rejected |
| `reviewed_by` | UUID | FK → `users.id`; null = decided automatically |
| `images_deleted_at` | timestamptz | when the ID/selfie images were purged |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- **Every attempt is a new row,** never overwritten. This fixes the old bug where a retry wiped the previous result.
- Only one open attempt per user (`in_progress` or `pending_review`), enforced by a partial unique index.
- **`users.verification_status` is updated by a trigger** when an attempt is approved or rejected, so the
  two can never disagree. This replaces the three separate status fields in the old schema.
- Key results (name, DOB, score, registry status) are **real columns with fixed names**. The old code broke
  because the UI read `similarity_score` while the data said `similarity`. Raw JSON is kept only as an audit trail.
- Privacy: images are stored by key in a private bucket, only the last 4 digits of the document number
  are kept, and images are purged after a retention period (`images_deleted_at`).

---

## sessions — active logins (refresh tokens)

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `user_id` | UUID | FK → `users.id`, cascade on delete |
| `refresh_token_hash` | text | UNIQUE; SHA-256 of the token — the raw token is never stored |
| `family_id` | UUID | shared by every rotated token from the same login |
| `user_agent` | text | "Chrome on Windows", for a "your devices" page |
| `ip_address` | inet | |
| `created_at` | timestamptz | |
| `last_used_at` | timestamptz | |
| `expires_at` | timestamptz | e.g. 30 days |
| `revoked_at` | timestamptz | set on logout, password change or reuse detection |
| `revoked_reason` | text | `logout`, `password_change`, `reuse_detected`, … |

Decisions:
- Short-lived access tokens (about 15 min, not stored) + long-lived refresh tokens (stored here, hashed).
- **Rotation:** every refresh issues a new token and revokes the old one. If a revoked token is ever
  used again, it was probably stolen, so the whole `family_id` is revoked.
- "Log out of all devices" = revoke every row for the user.
- Tokens are long random values, so a fast hash (SHA-256) is enough; passwords use argon2id.

## auth_tokens — one-time links for email verification and password reset

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `user_id` | UUID | FK → `users.id`, cascade on delete |
| `purpose` | enum | `email_verification`, `password_reset` |
| `token_hash` | text | UNIQUE; SHA-256 of the token in the emailed link |
| `expires_at` | timestamptz | 24 h for email verification, 1 h for password reset |
| `used_at` | timestamptz | set when used — each token works once |
| `created_at` | timestamptz | |

Decisions:
- One table, distinguished by `purpose`.
- At most one unused token per user per purpose (partial unique index); requesting a new link
  invalidates the old one.
- A successful password reset also revokes all of the user's `sessions`.

## Change to providers — Stripe payouts

| Column | Type | Notes |
|---|---|---|
| `stripe_account_id` | text | UNIQUE; the provider's Stripe Connect account (`acct_…`) |
| `payouts_enabled` | boolean | mirrored from Stripe; can't receive bookings with payment until true |

## payments — money movement for a booking (Stripe, test mode)

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `booking_id` | UUID | FK → `bookings.id` |
| `stripe_payment_intent_id` | text | UNIQUE (`pi_…`) |
| `amount_cents` | integer | > 0; equals the booking price at creation |
| `platform_fee_cents` | integer | ServiceHub's cut; between 0 and `amount_cents` |
| `currency` | char(3) | `usd` |
| `status` | enum | `requires_payment`, `authorized`, `captured`, `cancelled`, `refunded`, `partially_refunded`, `failed` |
| `refunded_cents` | integer | 0 … `amount_cents` |
| `failure_reason` | text | e.g. `card_declined` |
| `authorized_at`, `captured_at`, `cancelled_at` | timestamptz | |
| `created_at`, `updated_at` | timestamptz | |

Decisions:
- **Authorize at booking, capture at completion.** The card is held when the customer books, released
  if the booking is declined or cancelled, and charged only when the job is completed.
- Only one live payment per booking (partial unique index, ignoring `cancelled` / `failed` attempts).
- Status changes come from **verified Stripe webhooks**, never from the browser.
- Every call to Stripe sends an **idempotency key**, so retries never charge twice.
- Card details never touch our servers (Stripe Payment Element).
- Stripe is stubbed during load tests.

## stripe_events — webhook log, so each event is processed exactly once

| Column | Type | Notes |
|---|---|---|
| `id` | text | PK — Stripe's event ID (`evt_…`) |
| `type` | text | e.g. `payment_intent.succeeded` |
| `payload` | jsonb | the full event, for debugging |
| `received_at` | timestamptz | |
| `processed_at` | timestamptz | null until handled successfully |

Decisions:
- Stripe can deliver the same event more than once. Inserting its ID first (PK conflict = already seen)
  makes the webhook handler safe to run twice.

## damage_assessments — results from the photo damage assessment (VDA)

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `user_id` | UUID | FK → `users.id` |
| `image_key` | text | storage key of the uploaded photo, private bucket |
| `status` | enum | `pending`, `completed`, `failed` |
| `detected_category_id` | smallint | FK → `categories.id`, null if unsure |
| `severity` | enum | `low`, `medium`, `high`, `emergency` |
| `confidence` | numeric(4,3) | 0–1 |
| `summary` | text | the AI's short description of the damage |
| `model_name` | text | which model produced it, e.g. `gemma-4-31b` |
| `latency_ms` | integer | how long the AI call took |
| `raw_result` | jsonb | full response, for audit and tuning |
| `error_message` | text | when `failed` |
| `created_at`, `completed_at` | timestamptz | |

## damage_assessment_services — recommended services for an assessment

| Column | Type | Notes |
|---|---|---|
| `assessment_id` | UUID | FK → `damage_assessments.id`, cascade on delete |
| `service_id` | smallint | FK → `services.id` |
| `rank` | smallint | 1 = best match |

Decisions:
- PK (`assessment_id`, `service_id`), and `rank` unique per assessment.
- **Add to `bookings`:** `damage_assessment_id` (UUID, optional FK). Linking bookings to assessments
  shows how often the AI's suggestion leads to a booking, which is real data on how well it works.
- Storing `model_name` and `latency_ms` lets you compare models and track AI performance under load.

## outbox — reliable emails and notifications

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | PK, auto-increment |
| `topic` | text | e.g. `email.booking_confirmed`, `email.password_reset` |
| `payload` | jsonb | what the worker needs (booking ID, recipient, …) |
| `status` | enum | `pending`, `processing`, `sent`, `failed` |
| `attempts` | smallint | how many sends were tried |
| `available_at` | timestamptz | don't process before this — used for retry backoff |
| `last_error` | text | |
| `created_at`, `sent_at` | timestamptz | |

Decisions:
- **Outbox pattern:** the booking and its "send confirmation email" row are written in the **same
  transaction**, so an email is never lost and never sent for a booking that rolled back.
- A separate worker sends pending rows and retries failures with growing delays.
- Several workers can run at once without sending duplicates: each claims rows with
  `SELECT … FOR UPDATE SKIP LOCKED`.
- Rows are marked `failed` after a maximum number of attempts, for someone to inspect.

---

## Later — add when a feature needs it

| Table | Purpose |
|---|---|
| `complaint_messages` | back-and-forth thread on a support ticket |
| `favorites` | customers saving providers |
| `chat_conversations` | saved chatbot history (the chatbot is stateless today) |
| `admin_audit_log` | record of admin actions (hiding reviews, approving verifications, …) |

## Table count

- **SQL + tests written (tests not run yet):** users, categories, providers, provider_categories, addresses,
  services, provider_services — 7
- **SQL written, tests still to write:** provider_working_hours, provider_time_off, bookings, booking_events,
  reviews, complaints, verifications, sessions, auth_tokens, payments, stripe_events, damage_assessments,
  damage_assessment_services, outbox — 14
- **Dev seed data:** `backend/db/seeds/dev_seed.sql`
