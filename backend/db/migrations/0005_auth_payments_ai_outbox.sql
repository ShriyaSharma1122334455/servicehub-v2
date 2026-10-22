-- =============================================================================
-- 0005 — Auth, payments, AI damage assessments and the outbox
--   sessions, auth_tokens, providers Stripe columns, payments, stripe_events,
--   damage_assessments, damage_assessment_services, bookings.damage_assessment_id,
--   outbox
-- Design notes: backend/docs/schema-design.md
-- =============================================================================

BEGIN;

CREATE TYPE auth_token_purpose AS ENUM ('email_verification', 'password_reset');
CREATE TYPE payment_status     AS ENUM ('requires_payment', 'authorized', 'captured', 'cancelled',
                                        'refunded', 'partially_refunded', 'failed');
CREATE TYPE assessment_status  AS ENUM ('pending', 'completed', 'failed');
CREATE TYPE damage_severity    AS ENUM ('low', 'medium', 'high', 'emergency');
CREATE TYPE outbox_status      AS ENUM ('pending', 'processing', 'sent', 'failed');

-- =============================================================================
-- sessions — active logins (refresh tokens, stored hashed)
-- =============================================================================
CREATE TABLE sessions (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id            uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  refresh_token_hash text NOT NULL UNIQUE,              -- SHA-256 hex of the token
  family_id          uuid NOT NULL,                      -- shared across rotations of one login
  user_agent         text CHECK (char_length(user_agent) <= 500),
  ip_address         inet,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_used_at       timestamptz,
  expires_at         timestamptz NOT NULL,
  revoked_at         timestamptz,
  revoked_reason     text CHECK (revoked_reason IN
                       ('logout', 'logout_all', 'password_change', 'reuse_detected', 'rotated', 'admin')),

  CONSTRAINT sessions_expiry_after_creation CHECK (expires_at > created_at),
  CONSTRAINT sessions_revoked_reason_pair
    CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);

-- "Your devices" page and "log out everywhere".
CREATE INDEX sessions_user_active_idx ON sessions (user_id) WHERE revoked_at IS NULL;

-- Reuse detection revokes a whole family at once.
CREATE INDEX sessions_family_idx ON sessions (family_id);

-- =============================================================================
-- auth_tokens — one-time links for email verification and password reset
-- =============================================================================
CREATE TABLE auth_tokens (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  purpose    auth_token_purpose NOT NULL,
  token_hash text NOT NULL UNIQUE,                       -- SHA-256 hex of the emailed token
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT auth_tokens_expiry_after_creation CHECK (expires_at > created_at)
);

-- At most one unused token per user per purpose; a new link replaces the old.
CREATE UNIQUE INDEX auth_tokens_one_active
  ON auth_tokens (user_id, purpose) WHERE used_at IS NULL;

-- =============================================================================
-- providers — Stripe Connect account for payouts
-- =============================================================================
ALTER TABLE providers
  ADD COLUMN stripe_account_id text UNIQUE CHECK (stripe_account_id ~ '^acct_[A-Za-z0-9]+$'),
  ADD COLUMN payouts_enabled   boolean NOT NULL DEFAULT false;

-- =============================================================================
-- payments — money movement for a booking (Stripe)
-- =============================================================================
CREATE TABLE payments (
  id                       uuid PRIMARY KEY DEFAULT uuidv7(),
  booking_id               uuid NOT NULL REFERENCES bookings (id),
  stripe_payment_intent_id text NOT NULL UNIQUE CHECK (stripe_payment_intent_id ~ '^pi_[A-Za-z0-9_]+$'),
  amount_cents             integer NOT NULL CHECK (amount_cents > 0),
  platform_fee_cents       integer NOT NULL DEFAULT 0,
  currency                 char(3) NOT NULL DEFAULT 'usd' CHECK (currency ~ '^[a-z]{3}$'),
  status                   payment_status NOT NULL DEFAULT 'requires_payment',
  refunded_cents           integer NOT NULL DEFAULT 0,
  failure_reason           text CHECK (char_length(failure_reason) <= 200),
  authorized_at            timestamptz,
  captured_at              timestamptz,
  cancelled_at             timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT payments_fee_range
    CHECK (platform_fee_cents BETWEEN 0 AND amount_cents),
  CONSTRAINT payments_refund_range
    CHECK (refunded_cents BETWEEN 0 AND amount_cents),

  -- Status and amounts must agree.
  CONSTRAINT payments_status_consistent CHECK (
        (status NOT IN ('authorized', 'captured', 'refunded', 'partially_refunded')
         OR authorized_at IS NOT NULL)
    AND (status NOT IN ('captured', 'refunded', 'partially_refunded') OR captured_at IS NOT NULL)
    AND (status <> 'cancelled'          OR cancelled_at IS NOT NULL)
    AND (status <> 'refunded'           OR refunded_cents = amount_cents)
    AND (status <> 'partially_refunded' OR refunded_cents BETWEEN 1 AND amount_cents - 1)
    AND (status <> 'failed'             OR failure_reason IS NOT NULL)
  )
);

-- Only one live payment per booking; cancelled/failed attempts don't count.
CREATE UNIQUE INDEX payments_one_live_per_booking
  ON payments (booking_id) WHERE status NOT IN ('cancelled', 'failed');

CREATE TRIGGER payments_set_updated_at
  BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- stripe_events — each webhook event is processed exactly once
-- =============================================================================
CREATE TABLE stripe_events (
  id           text PRIMARY KEY CHECK (id ~ '^evt_[A-Za-z0-9_]+$'),
  type         text NOT NULL,
  payload      jsonb NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);

-- Events that arrived but haven't been handled successfully yet.
CREATE INDEX stripe_events_unprocessed_idx
  ON stripe_events (received_at) WHERE processed_at IS NULL;

-- =============================================================================
-- damage_assessments — results from the photo damage assessment (VDA)
-- =============================================================================
CREATE TABLE damage_assessments (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id              uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  image_key            text NOT NULL,                     -- private storage key
  status               assessment_status NOT NULL DEFAULT 'pending',
  detected_category_id smallint REFERENCES categories (id),
  severity             damage_severity,
  confidence           numeric(4, 3) CHECK (confidence BETWEEN 0 AND 1),
  summary              text CHECK (char_length(summary) <= 2000),
  model_name           text CHECK (char_length(model_name) <= 100),
  latency_ms           integer CHECK (latency_ms >= 0),
  raw_result           jsonb,
  error_message        text CHECK (char_length(error_message) <= 1000),
  created_at           timestamptz NOT NULL DEFAULT now(),
  completed_at         timestamptz,

  CONSTRAINT damage_assessments_status_consistent CHECK (
        (status <> 'completed' OR completed_at IS NOT NULL)
    AND (status <> 'failed'    OR error_message IS NOT NULL)
  )
);

CREATE INDEX damage_assessments_user_idx ON damage_assessments (user_id, created_at DESC);

-- =============================================================================
-- damage_assessment_services — ranked service recommendations
-- =============================================================================
CREATE TABLE damage_assessment_services (
  assessment_id uuid     NOT NULL REFERENCES damage_assessments (id) ON DELETE CASCADE,
  service_id    smallint NOT NULL REFERENCES services (id),
  rank          smallint NOT NULL CHECK (rank BETWEEN 1 AND 10),

  PRIMARY KEY (assessment_id, service_id),
  CONSTRAINT damage_assessment_services_rank_key UNIQUE (assessment_id, rank)
);

-- Which assessment (if any) led to a booking.
ALTER TABLE bookings
  ADD COLUMN damage_assessment_id uuid REFERENCES damage_assessments (id) ON DELETE SET NULL;

CREATE INDEX bookings_damage_assessment_idx
  ON bookings (damage_assessment_id) WHERE damage_assessment_id IS NOT NULL;

-- =============================================================================
-- outbox — reliable emails and notifications (outbox pattern)
-- =============================================================================
CREATE TABLE outbox (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  topic        text NOT NULL CHECK (topic ~ '^[a-z]+(\.[a-z_]+)+$'),   -- e.g. email.booking_confirmed
  payload      jsonb NOT NULL,
  status       outbox_status NOT NULL DEFAULT 'pending',
  attempts     smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at timestamptz NOT NULL DEFAULT now(),
  last_error   text CHECK (char_length(last_error) <= 2000),
  created_at   timestamptz NOT NULL DEFAULT now(),
  sent_at      timestamptz,

  CONSTRAINT outbox_sent_at CHECK (status <> 'sent' OR sent_at IS NOT NULL)
);

-- Workers poll for due work:
--   SELECT … FROM outbox WHERE status = 'pending' AND available_at <= now()
--   ORDER BY available_at LIMIT 50 FOR UPDATE SKIP LOCKED;
CREATE INDEX outbox_due_idx ON outbox (available_at) WHERE status = 'pending';

COMMIT;
