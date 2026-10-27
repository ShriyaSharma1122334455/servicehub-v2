-- =============================================================================
-- 0004 — Reviews, complaints and identity verifications
--   providers rating counters, reviews, complaints, verifications
-- Design notes: backend/docs/schema-design.md
-- =============================================================================


CREATE TYPE complaint_type     AS ENUM ('complaint', 'incident', 'feedback');
CREATE TYPE complaint_priority AS ENUM ('low', 'medium', 'high', 'urgent');
CREATE TYPE complaint_status   AS ENUM ('open', 'in_progress', 'resolved', 'closed');

CREATE TYPE document_type               AS ENUM ('passport', 'drivers_license', 'state_id');
CREATE TYPE verification_attempt_status AS ENUM ('in_progress', 'pending_review', 'approved', 'rejected', 'expired');
CREATE TYPE registry_check_status       AS ENUM ('clear', 'match_found', 'unavailable');

-- =============================================================================
-- providers — rating counters, maintained by the reviews trigger below
-- =============================================================================
ALTER TABLE providers
  ADD COLUMN rating_count integer NOT NULL DEFAULT 0 CHECK (rating_count >= 0),
  ADD COLUMN rating_sum   integer NOT NULL DEFAULT 0 CHECK (rating_sum >= 0);

-- =============================================================================
-- reviews — a customer's rating of a completed booking
-- =============================================================================
CREATE TABLE reviews (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  booking_id          uuid NOT NULL UNIQUE,                -- one review per booking
  reviewer_id         uuid NOT NULL,
  provider_id         uuid NOT NULL,
  rating              smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment             text CHECK (char_length(comment) <= 2000),
  provider_reply      text CHECK (char_length(provider_reply) <= 2000),
  provider_replied_at timestamptz,
  is_hidden           boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  -- The reviewer must be the booking's customer ...
  CONSTRAINT reviews_reviewer_fk
    FOREIGN KEY (booking_id, reviewer_id) REFERENCES bookings (id, customer_id),
  -- ... and provider_id must be the booking's provider.
  CONSTRAINT reviews_provider_fk
    FOREIGN KEY (booking_id, provider_id) REFERENCES bookings (id, provider_id),

  CONSTRAINT reviews_reply_pair
    CHECK ((provider_reply IS NULL) = (provider_replied_at IS NULL))
);

-- Provider profile page: visible reviews, newest first.
CREATE INDEX reviews_provider_visible_idx
  ON reviews (provider_id, created_at DESC) WHERE NOT is_hidden;

CREATE TRIGGER reviews_set_updated_at
  BEFORE UPDATE ON reviews
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Only completed bookings can be reviewed.
CREATE FUNCTION reviews_require_completed_booking() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM bookings WHERE id = NEW.booking_id AND status = 'completed'
  ) THEN
    RAISE EXCEPTION 'only completed bookings can be reviewed'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER reviews_require_completed_booking
  BEFORE INSERT ON reviews
  FOR EACH ROW EXECUTE FUNCTION reviews_require_completed_booking();

-- Keep providers.rating_count / rating_sum in step with visible reviews.
-- Uses "count = count + 1" style updates, which Postgres applies atomically,
-- so two reviews arriving at once can't lose an update.
CREATE FUNCTION reviews_update_provider_rating() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Remove the old row's contribution.
  IF TG_OP IN ('UPDATE', 'DELETE') AND NOT OLD.is_hidden THEN
    UPDATE providers
       SET rating_count = rating_count - 1,
           rating_sum   = rating_sum - OLD.rating
     WHERE user_id = OLD.provider_id;
  END IF;

  -- Add the new row's contribution.
  IF TG_OP IN ('INSERT', 'UPDATE') AND NOT NEW.is_hidden THEN
    UPDATE providers
       SET rating_count = rating_count + 1,
           rating_sum   = rating_sum + NEW.rating
     WHERE user_id = NEW.provider_id;
  END IF;

  RETURN NULL;
END;
$$;

CREATE TRIGGER reviews_update_provider_rating
  AFTER INSERT OR DELETE OR UPDATE OF rating, is_hidden ON reviews
  FOR EACH ROW EXECUTE FUNCTION reviews_update_provider_rating();

-- =============================================================================
-- complaints — support tickets
-- =============================================================================
CREATE TABLE complaints (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  ref_no          bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  -- CMP-000123; grows past 6 digits instead of truncating.
  reference       text GENERATED ALWAYS AS (
                    'CMP-' || CASE WHEN ref_no < 1000000
                                   THEN lpad(ref_no::text, 6, '0')
                                   ELSE ref_no::text END
                  ) STORED UNIQUE,
  user_id         uuid NOT NULL REFERENCES users (id),
  booking_id      uuid REFERENCES bookings (id),
  type            complaint_type     NOT NULL DEFAULT 'complaint',
  subject         text NOT NULL CHECK (char_length(btrim(subject)) BETWEEN 5 AND 200),
  description     text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 10 AND 5000),
  priority        complaint_priority NOT NULL DEFAULT 'medium',
  status          complaint_status   NOT NULL DEFAULT 'open',
  assigned_to     uuid REFERENCES users (id),
  resolution_note text CHECK (char_length(resolution_note) <= 2000),
  resolved_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT complaints_resolution CHECK (
    status NOT IN ('resolved', 'closed')
    OR (resolved_at IS NOT NULL AND resolution_note IS NOT NULL)
  )
);

-- "My tickets", newest first.
CREATE INDEX complaints_user_idx ON complaints (user_id, created_at DESC);

-- Support queue: open work only.
CREATE INDEX complaints_queue_idx
  ON complaints (priority, created_at) WHERE status IN ('open', 'in_progress');

CREATE TRIGGER complaints_set_updated_at
  BEFORE UPDATE ON complaints
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- An attached booking must involve the person filing; resolved_at is filled in
-- automatically when a ticket is resolved or closed.
CREATE FUNCTION complaints_check() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.booking_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM bookings
     WHERE id = NEW.booking_id
       AND NEW.user_id IN (customer_id, provider_id)
  ) THEN
    RAISE EXCEPTION 'complaint booking must belong to the person filing it'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status IN ('resolved', 'closed') AND NEW.resolved_at IS NULL THEN
    NEW.resolved_at := now();
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER complaints_check
  BEFORE INSERT OR UPDATE OF booking_id, user_id, status ON complaints
  FOR EACH ROW EXECUTE FUNCTION complaints_check();

-- =============================================================================
-- verifications — every identity-verification attempt, never overwritten
-- =============================================================================
CREATE TABLE verifications (
  id                     uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id                uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  document_type          document_type NOT NULL,
  document_key           text,                      -- private storage key, not a URL
  selfie_key             text,
  status                 verification_attempt_status NOT NULL DEFAULT 'in_progress',
  extracted_full_name    text CHECK (char_length(extracted_full_name) <= 200),
  extracted_dob          date,
  document_number_last4  text CHECK (document_number_last4 ~ '^[0-9A-Z]{4}$'),
  document_expires_on    date,
  face_match_score       numeric(5, 2) CHECK (face_match_score BETWEEN 0 AND 100),
  registry_check_status  registry_check_status,
  ocr_result             jsonb,
  face_match_result      jsonb,
  registry_check_result  jsonb,
  rejection_reason       text CHECK (char_length(rejection_reason) <= 500),
  submitted_at           timestamptz,
  reviewed_at            timestamptz,
  reviewed_by            uuid REFERENCES users (id),   -- null = decided automatically
  images_deleted_at      timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT verifications_rejection_reason
    CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL),
  CONSTRAINT verifications_reviewed
    CHECK (status NOT IN ('approved', 'rejected') OR reviewed_at IS NOT NULL)
);

-- A user's attempt history, newest first.
CREATE INDEX verifications_user_idx ON verifications (user_id, created_at DESC);

-- Only one open attempt per user at a time.
CREATE UNIQUE INDEX verifications_one_open_per_user
  ON verifications (user_id) WHERE status IN ('in_progress', 'pending_review');

-- Admin review queue.
CREATE INDEX verifications_review_queue_idx
  ON verifications (submitted_at) WHERE status = 'pending_review';

CREATE TRIGGER verifications_set_updated_at
  BEFORE UPDATE ON verifications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Fill in reviewed_at when a decision is made.
CREATE FUNCTION verifications_stamp_review() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IN ('approved', 'rejected') AND NEW.reviewed_at IS NULL THEN
    NEW.reviewed_at := now();
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER verifications_stamp_review
  BEFORE INSERT OR UPDATE OF status ON verifications
  FOR EACH ROW EXECUTE FUNCTION verifications_stamp_review();

-- Keep users.verification_status in step with the latest attempt, so the two
-- can never disagree.
CREATE FUNCTION verifications_sync_user_status() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  new_user_status verification_status;
BEGIN
  new_user_status := CASE NEW.status
    WHEN 'in_progress'    THEN 'pending'
    WHEN 'pending_review' THEN 'pending'
    WHEN 'approved'       THEN 'verified'
    WHEN 'rejected'       THEN 'rejected'
    ELSE NULL                              -- 'expired' leaves the user as they were
  END;

  IF new_user_status IS NOT NULL THEN
    UPDATE users
       SET verification_status = new_user_status
     WHERE id = NEW.user_id
       AND verification_status IS DISTINCT FROM new_user_status;
  END IF;

  RETURN NULL;
END;
$$;

CREATE TRIGGER verifications_sync_user_status
  AFTER INSERT OR UPDATE OF status ON verifications
  FOR EACH ROW EXECUTE FUNCTION verifications_sync_user_status();

