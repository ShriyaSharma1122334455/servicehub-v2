-- =============================================================================
-- 0003 — Scheduling and bookings
--   providers.time_zone, provider_working_hours, provider_time_off,
--   bookings (with the no-double-booking constraint), booking_events
-- Design notes: backend/docs/schema-design.md
-- =============================================================================


-- btree_gist lets an exclusion constraint combine "same provider" (=) with
-- "overlapping time" (&&) in one index.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Postgres has ranges for timestamps and dates but not for time-of-day.
CREATE TYPE timerange AS RANGE (subtype = time);

CREATE TYPE booking_status AS ENUM ('pending', 'confirmed', 'completed', 'cancelled', 'declined');

-- =============================================================================
-- providers.time_zone — working hours are local times, so we need the zone
-- =============================================================================

-- True when Postgres recognises the name (e.g. 'America/New_York').
-- Marked IMMUTABLE so it can be used in a CHECK constraint.
CREATE FUNCTION is_valid_time_zone(tz text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  PERFORM now() AT TIME ZONE tz;
  RETURN true;
EXCEPTION WHEN invalid_parameter_value THEN
  RETURN false;
END;
$$;

ALTER TABLE providers
  ADD COLUMN time_zone text NOT NULL DEFAULT 'America/New_York'
    CHECK (is_valid_time_zone(time_zone));

-- Target for the bookings (provider_service_id, provider_id) foreign key.
ALTER TABLE provider_services
  ADD CONSTRAINT provider_services_id_provider_key UNIQUE (id, provider_id);

-- =============================================================================
-- provider_working_hours — regular weekly schedule (local time)
-- =============================================================================
CREATE TABLE provider_working_hours (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  provider_id uuid     NOT NULL REFERENCES providers (user_id) ON DELETE CASCADE,
  day_of_week smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),   -- ISO: 1 = Monday
  start_time  time     NOT NULL,
  end_time    time     NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT provider_working_hours_order CHECK (end_time > start_time),

  -- Two ranges on the same day for the same provider can't overlap.
  CONSTRAINT provider_working_hours_no_overlap
    EXCLUDE USING gist (
      provider_id WITH =,
      day_of_week WITH =,
      timerange(start_time, end_time) WITH &&
    )
);

CREATE TRIGGER provider_working_hours_set_updated_at
  BEFORE UPDATE ON provider_working_hours
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- provider_time_off — vacations, sick days, blocked afternoons
-- =============================================================================
CREATE TABLE provider_time_off (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  provider_id uuid      NOT NULL REFERENCES providers (user_id) ON DELETE CASCADE,
  period      tstzrange NOT NULL,
  reason      text CHECK (char_length(reason) <= 200),
  created_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT provider_time_off_finite
    CHECK (NOT isempty(period) AND NOT lower_inf(period) AND NOT upper_inf(period)),

  CONSTRAINT provider_time_off_no_overlap
    EXCLUDE USING gist (provider_id WITH =, period WITH &&)
);

-- =============================================================================
-- bookings — the core transaction
-- =============================================================================
CREATE TABLE bookings (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  customer_id          uuid NOT NULL REFERENCES users (id),
  provider_id          uuid NOT NULL REFERENCES providers (user_id),
  provider_service_id  uuid NOT NULL,
  status               booking_status NOT NULL DEFAULT 'pending',
  scheduled_period     tstzrange NOT NULL,

  -- Snapshots: copied at booking time so later edits never change this booking.
  price_cents          integer    NOT NULL CHECK (price_cents > 0),
  price_unit           price_unit NOT NULL,
  address_line1        text    NOT NULL CHECK (char_length(btrim(address_line1)) BETWEEN 1 AND 200),
  address_line2        text    CHECK (char_length(address_line2) <= 200),
  address_city         text    NOT NULL CHECK (char_length(btrim(address_city)) BETWEEN 1 AND 100),
  address_state        char(2) NOT NULL CHECK (address_state ~ '^[A-Z]{2}$'),
  address_postal_code  text    NOT NULL CHECK (address_postal_code ~ '^[0-9]{5}(-[0-9]{4})?$'),
  address_latitude     numeric(9, 6) CHECK (address_latitude  BETWEEN -90  AND 90),
  address_longitude    numeric(9, 6) CHECK (address_longitude BETWEEN -180 AND 180),
  address_id           uuid REFERENCES addresses (id) ON DELETE SET NULL,

  customer_notes       text CHECK (char_length(customer_notes) <= 1000),
  cancellation_reason  text CHECK (char_length(cancellation_reason) <= 500),

  confirmed_at         timestamptz,
  completed_at         timestamptz,
  cancelled_at         timestamptz,
  reminder_sent_at     timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  -- The offer must belong to the same provider.
  CONSTRAINT bookings_offer_fk
    FOREIGN KEY (provider_service_id, provider_id)
    REFERENCES provider_services (id, provider_id),

  -- Targets for the reviews composite foreign keys (0004).
  CONSTRAINT bookings_id_customer_key UNIQUE (id, customer_id),
  CONSTRAINT bookings_id_provider_key UNIQUE (id, provider_id),

  CONSTRAINT bookings_not_self CHECK (customer_id <> provider_id),

  -- A real, finite period that includes its start and excludes its end, so a
  -- 9:00–10:00 job and a 10:00–11:00 job don't count as overlapping.
  CONSTRAINT bookings_period_valid CHECK (
    NOT isempty(scheduled_period)
    AND NOT lower_inf(scheduled_period) AND NOT upper_inf(scheduled_period)
    AND lower_inc(scheduled_period) AND NOT upper_inc(scheduled_period)
  ),

  CONSTRAINT bookings_coordinates_pair
    CHECK ((address_latitude IS NULL) = (address_longitude IS NULL)),

  -- Status timestamps must match the status (the trigger below fills them in).
  CONSTRAINT bookings_status_timestamps CHECK (
        (status <> 'confirmed' OR confirmed_at IS NOT NULL)
    AND (status <> 'completed' OR (confirmed_at IS NOT NULL AND completed_at IS NOT NULL))
    AND (status NOT IN ('cancelled', 'declined')
         OR (cancelled_at IS NOT NULL AND cancellation_reason IS NOT NULL))
  ),

  -- ── No double booking ──────────────────────────────────────────────────
  -- Two active bookings of the same provider can't overlap in time.
  -- Cancelled, declined and completed bookings don't block the slot.
  CONSTRAINT bookings_no_overlap
    EXCLUDE USING gist (provider_id WITH =, scheduled_period WITH &&)
    WHERE (status IN ('pending', 'confirmed'))
);

-- "My bookings" for customers, newest first.
CREATE INDEX bookings_customer_idx ON bookings (customer_id, lower(scheduled_period) DESC);

-- Provider calendar / dashboard.
CREATE INDEX bookings_provider_start_idx ON bookings (provider_id, lower(scheduled_period));

-- Reminder job: confirmed bookings starting soon that haven't had a reminder.
CREATE INDEX bookings_reminder_due_idx ON bookings (lower(scheduled_period))
  WHERE status = 'confirmed' AND reminder_sent_at IS NULL;

CREATE TRIGGER bookings_set_updated_at
  BEFORE UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- booking_events — append-only status history
-- =============================================================================
CREATE TABLE booking_events (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  booking_id    uuid NOT NULL REFERENCES bookings (id),
  from_status   booking_status,                 -- null for the creation event
  to_status     booking_status NOT NULL,
  actor_user_id uuid REFERENCES users (id),     -- null = the system
  note          text CHECK (char_length(note) <= 500),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX booking_events_booking_idx ON booking_events (booking_id, id);

-- History is never edited or deleted.
CREATE FUNCTION booking_events_block_changes() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'booking_events is append-only'
    USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER booking_events_append_only
  BEFORE UPDATE OR DELETE ON booking_events
  FOR EACH ROW EXECUTE FUNCTION booking_events_block_changes();

-- =============================================================================
-- Booking status rules
-- =============================================================================

-- Who is acting, as told by the app with:  SET LOCAL app.actor_id = '<user id>';
-- Returns null when unset (the system is acting).
CREATE FUNCTION current_actor_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.actor_id', true), '')::uuid
$$;

-- BEFORE trigger: new bookings start as 'pending'; status changes must follow
-- the allowed transitions; transition timestamps are filled in automatically.
CREATE FUNCTION bookings_check_status() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' THEN
      RAISE EXCEPTION 'new bookings must start as pending, got %', NEW.status
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT (
       (OLD.status = 'pending'   AND NEW.status IN ('confirmed', 'declined', 'cancelled'))
    OR (OLD.status = 'confirmed' AND NEW.status IN ('completed', 'cancelled'))
  ) THEN
    RAISE EXCEPTION 'booking cannot go from % to %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  CASE NEW.status
    WHEN 'confirmed' THEN NEW.confirmed_at := coalesce(NEW.confirmed_at, now());
    WHEN 'completed' THEN NEW.completed_at := coalesce(NEW.completed_at, now());
    WHEN 'cancelled', 'declined' THEN NEW.cancelled_at := coalesce(NEW.cancelled_at, now());
    ELSE NULL;
  END CASE;

  RETURN NEW;
END;
$$;

CREATE TRIGGER bookings_check_status
  BEFORE INSERT OR UPDATE OF status ON bookings
  FOR EACH ROW EXECUTE FUNCTION bookings_check_status();

-- AFTER trigger: record every creation and status change in booking_events.
CREATE FUNCTION bookings_log_status() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO booking_events (booking_id, from_status, to_status, actor_user_id)
    VALUES (
      NEW.id,
      CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END,
      NEW.status,
      current_actor_id()
    );
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER bookings_log_status
  AFTER INSERT OR UPDATE OF status ON bookings
  FOR EACH ROW EXECUTE FUNCTION bookings_log_status();

