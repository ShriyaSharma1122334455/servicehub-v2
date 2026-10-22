-- =============================================================================
-- 0001 — Core schema: users, providers, trades, addresses, service catalog
-- Requires PostgreSQL 18+ (uses the built-in uuidv7() function).
-- Design notes: backend/docs/schema-design.md
-- =============================================================================

BEGIN;

-- ── Extensions ───────────────────────────────────────────────────────────────
-- citext: case-insensitive text, so 'Shriya@Gmail.com' = 'shriya@gmail.com'
CREATE EXTENSION IF NOT EXISTS citext;

-- ── Enums ────────────────────────────────────────────────────────────────────
CREATE TYPE user_role           AS ENUM ('customer', 'provider', 'admin');
CREATE TYPE verification_status AS ENUM ('unverified', 'pending', 'verified', 'rejected');
CREATE TYPE price_unit          AS ENUM ('fixed', 'hourly');

-- ── updated_at helper ────────────────────────────────────────────────────────
-- Attached to every table with an updated_at column, so the app never has to
-- remember to set it.
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- =============================================================================
-- users — everyone who logs in
-- =============================================================================
CREATE TABLE users (
  -- uuidv7 is time-ordered, so new rows land at the end of the index
  -- (faster inserts than random v4 UUIDs at high volume).
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  email               citext NOT NULL
                        CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  email_verified_at   timestamptz,
  password_hash       text NOT NULL,
  full_name           text NOT NULL
                        CHECK (char_length(btrim(full_name)) BETWEEN 1 AND 100),
  phone               text
                        CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),   -- E.164
  dob                 date
                        CHECK (dob >= DATE '1900-01-01'),
  role                user_role NOT NULL DEFAULT 'customer',
  verification_status verification_status NOT NULL DEFAULT 'unverified',
  avatar_url          text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,

  -- Target for the providers (user_id, role) foreign key below.
  CONSTRAINT users_id_role_key UNIQUE (id, role)
);

-- Email is unique among *active* accounts only, so a soft-deleted user's
-- email can register again.
CREATE UNIQUE INDEX users_email_active_key
  ON users (email) WHERE deleted_at IS NULL;

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- categories — the trade list (Plumbing, Electrical, ...). IDs hand-assigned.
-- =============================================================================
CREATE TABLE categories (
  id          smallint PRIMARY KEY,                      -- no default: assigned by hand
  slug        text NOT NULL UNIQUE
                CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text NOT NULL UNIQUE,
  icon        text,
  description text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER categories_set_updated_at
  BEFORE UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- providers — business details, exactly one per provider user
-- =============================================================================
CREATE TABLE providers (
  user_id           uuid PRIMARY KEY,
  -- Always 'provider'. Together with the FK below, this guarantees a providers
  -- row can only belong to a user whose role is 'provider': changing that
  -- user's role cascades here and fails the CHECK.
  role              user_role NOT NULL DEFAULT 'provider'
                      CHECK (role = 'provider'),
  business_name     text NOT NULL
                      CHECK (char_length(btrim(business_name)) BETWEEN 2 AND 120),
  description       text,
  years_experience  smallint CHECK (years_experience BETWEEN 0 AND 80),
  license_number    text,
  service_radius_km smallint NOT NULL DEFAULT 25
                      CHECK (service_radius_km BETWEEN 1 AND 500),
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT providers_user_fk
    FOREIGN KEY (user_id, role) REFERENCES users (id, role)
    ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TRIGGER providers_set_updated_at
  BEFORE UPDATE ON providers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- provider_categories — which trades each provider works in (many-to-many)
-- =============================================================================
CREATE TABLE provider_categories (
  provider_id uuid     NOT NULL REFERENCES providers (user_id) ON DELETE CASCADE,
  category_id smallint NOT NULL REFERENCES categories (id),
  created_at  timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (provider_id, category_id)
);

-- "All providers in category X" (the PK only helps lookups by provider).
CREATE INDEX provider_categories_category_idx
  ON provider_categories (category_id, provider_id);

-- =============================================================================
-- addresses — a user's saved addresses (US only for now)
-- =============================================================================
CREATE TABLE addresses (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id     uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  label       text NOT NULL DEFAULT 'Home'
                CHECK (char_length(btrim(label)) BETWEEN 1 AND 50),
  line1       text NOT NULL CHECK (char_length(btrim(line1)) BETWEEN 1 AND 200),
  line2       text CHECK (char_length(line2) <= 200),
  city        text NOT NULL CHECK (char_length(btrim(city)) BETWEEN 1 AND 100),
  state       char(2) NOT NULL CHECK (state ~ '^[A-Z]{2}$'),
  -- text, not a number: ZIPs can start with 0 and have a +4 suffix
  postal_code text NOT NULL CHECK (postal_code ~ '^[0-9]{5}(-[0-9]{4})?$'),
  country     char(2) NOT NULL DEFAULT 'US' CHECK (country = 'US'),
  latitude    numeric(9, 6) CHECK (latitude  BETWEEN -90  AND 90),
  longitude   numeric(9, 6) CHECK (longitude BETWEEN -180 AND 180),
  is_default  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  -- Coordinates come as a pair or not at all.
  CONSTRAINT addresses_coordinates_pair
    CHECK ((latitude IS NULL) = (longitude IS NULL))
);

CREATE INDEX addresses_user_idx ON addresses (user_id);

-- At most one default address per user.
CREATE UNIQUE INDEX addresses_one_default_per_user
  ON addresses (user_id) WHERE is_default;

CREATE TRIGGER addresses_set_updated_at
  BEFORE UPDATE ON addresses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- services — the shared catalog of bookable jobs. IDs hand-assigned.
-- =============================================================================
CREATE TABLE services (
  id                       smallint PRIMARY KEY,         -- no default: assigned by hand
  category_id              smallint NOT NULL REFERENCES categories (id),
  slug                     text NOT NULL UNIQUE
                             CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name                     text NOT NULL,
  description              text,
  default_duration_minutes smallint NOT NULL
                             CHECK (default_duration_minutes > 0
                                    AND default_duration_minutes % 15 = 0),
  price_unit               price_unit NOT NULL DEFAULT 'fixed',
  is_active                boolean NOT NULL DEFAULT true,
  sort_order               smallint NOT NULL DEFAULT 0,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT services_category_name_key UNIQUE (category_id, name),
  -- Target for the provider_services (service_id, category_id) foreign key.
  CONSTRAINT services_id_category_key   UNIQUE (id, category_id)
);

CREATE TRIGGER services_set_updated_at
  BEFORE UPDATE ON services
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- provider_services — a provider's offer (price + duration) for a catalog service
-- =============================================================================
CREATE TABLE provider_services (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  provider_id      uuid     NOT NULL REFERENCES providers (user_id) ON DELETE CASCADE,
  service_id       smallint NOT NULL,
  -- Copied from the service so the two composite FKs below can check that
  -- the provider actually works in this service's trade.
  category_id      smallint NOT NULL,
  price_cents      integer  NOT NULL
                     CHECK (price_cents > 0 AND price_cents <= 10000000),   -- max $100k
  duration_minutes smallint NOT NULL
                     CHECK (duration_minutes > 0
                            AND duration_minutes <= 1440
                            AND duration_minutes % 15 = 0),
  description      text CHECK (char_length(description) <= 1000),
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT provider_services_provider_service_key
    UNIQUE (provider_id, service_id),

  -- The (service, category) pair must be real ...
  CONSTRAINT provider_services_service_fk
    FOREIGN KEY (service_id, category_id) REFERENCES services (id, category_id),

  -- ... and the provider must be registered in that category.
  CONSTRAINT provider_services_trade_fk
    FOREIGN KEY (provider_id, category_id)
    REFERENCES provider_categories (provider_id, category_id)
);

-- "Who offers service X?" — only active offers matter for search.
CREATE INDEX provider_services_service_active_idx
  ON provider_services (service_id, price_cents) WHERE is_active;

CREATE TRIGGER provider_services_set_updated_at
  BEFORE UPDATE ON provider_services
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;
