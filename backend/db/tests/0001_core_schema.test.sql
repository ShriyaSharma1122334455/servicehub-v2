-- =============================================================================
-- Constraint tests for 0001_core_schema + 0002_seed_catalog
--
-- Each test either expects a statement to succeed, or to fail with a specific
-- SQLSTATE. Everything runs in one transaction that is rolled back at the end,
-- so the database is left unchanged.
--
-- Run:  psql -v ON_ERROR_STOP=1 -f backend/db/tests/0001_core_schema.test.sql
-- Any failed expectation raises an error and stops the run (non-zero exit).
--
-- SQLSTATEs used: 23505 unique_violation, 23503 foreign_key_violation,
--                 23514 check_violation
-- =============================================================================

\set QUIET on
BEGIN;

-- ── Test helpers (pg_temp = dropped automatically at session end) ───────────
CREATE FUNCTION pg_temp.expect_ok(label text, stmt text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  RAISE NOTICE 'PASS  %', label;
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'FAIL  % — expected success, got % (%)', label, SQLERRM, SQLSTATE;
END;
$$;

CREATE FUNCTION pg_temp.expect_error(label text, stmt text, expected_state text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expected_state THEN
      RAISE NOTICE 'PASS  %', label;
      RETURN;
    END IF;
    RAISE EXCEPTION 'FAIL  % — expected SQLSTATE %, got % (%)', label, expected_state, SQLSTATE, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL  % — expected SQLSTATE %, but statement succeeded', label, expected_state;
END;
$$;

CREATE FUNCTION pg_temp.expect_true(label text, condition boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL  % — condition was %', label, condition;
  END IF;
  RAISE NOTICE 'PASS  %', label;
END;
$$;

-- ── Fixtures ────────────────────────────────────────────────────────────────
INSERT INTO users (id, email, password_hash, full_name, role) VALUES
  ('00000000-0000-7000-8000-000000000001', 'customer@test.dev', 'x', 'Casey Customer', 'customer'),
  ('00000000-0000-7000-8000-000000000002', 'plumber@test.dev',  'x', 'Pat Plumber',    'provider');

INSERT INTO providers (user_id, business_name)
  VALUES ('00000000-0000-7000-8000-000000000002', 'Pat''s Plumbing');

INSERT INTO provider_categories (provider_id, category_id)
  VALUES ('00000000-0000-7000-8000-000000000002', 1);   -- plumbing only

-- ── users ───────────────────────────────────────────────────────────────────
INSERT INTO users (email, password_hash, full_name) VALUES ('v7@test.dev', 'x', 'V Seven');
SELECT pg_temp.expect_true('users: id defaults to a UUIDv7',
  (SELECT uuid_extract_version(id) = 7 FROM users WHERE email = 'v7@test.dev'));

SELECT pg_temp.expect_error('users: duplicate email is rejected regardless of case',
  $$INSERT INTO users (email, password_hash, full_name) VALUES ('CUSTOMER@Test.dev', 'x', 'Dup')$$,
  '23505');

SELECT pg_temp.expect_ok('users: a soft-deleted user''s email can register again',
  $$UPDATE users SET deleted_at = now() WHERE email = 'customer@test.dev';
    INSERT INTO users (email, password_hash, full_name) VALUES ('customer@test.dev', 'x', 'Casey Again');
    DELETE FROM users WHERE full_name = 'Casey Again';
    UPDATE users SET deleted_at = NULL WHERE email = 'customer@test.dev'$$);

SELECT pg_temp.expect_error('users: malformed email is rejected',
  $$INSERT INTO users (email, password_hash, full_name) VALUES ('not-an-email', 'x', 'Bad')$$,
  '23514');

SELECT pg_temp.expect_error('users: phone must be E.164',
  $$UPDATE users SET phone = '201-555-1234' WHERE email = 'customer@test.dev'$$,
  '23514');

SELECT pg_temp.expect_ok('users: valid E.164 phone is accepted',
  $$UPDATE users SET phone = '+12015551234' WHERE email = 'customer@test.dev'$$);

SELECT pg_temp.expect_error('users: blank full_name is rejected',
  $$INSERT INTO users (email, password_hash, full_name) VALUES ('blank@test.dev', 'x', '   ')$$,
  '23514');

-- The trigger overwrites updated_at on every UPDATE, so even an explicit old
-- value is replaced with now().
UPDATE users SET updated_at = '2000-01-01', full_name = 'Casey C.' WHERE email = 'customer@test.dev';
SELECT pg_temp.expect_true('users: updated_at moved forward after an update',
  (SELECT updated_at > '2000-01-01' FROM users WHERE email = 'customer@test.dev'));

-- ── providers ───────────────────────────────────────────────────────────────
SELECT pg_temp.expect_error('providers: a customer cannot have a provider profile',
  $$INSERT INTO providers (user_id, business_name)
    VALUES ('00000000-0000-7000-8000-000000000001', 'Not A Provider')$$,
  '23503');

SELECT pg_temp.expect_error('providers: cannot demote a user who still has a provider profile',
  $$UPDATE users SET role = 'customer' WHERE id = '00000000-0000-7000-8000-000000000002'$$,
  '23514');

SELECT pg_temp.expect_error('providers: service radius must be 1–500 km',
  $$UPDATE providers SET service_radius_km = 0
    WHERE user_id = '00000000-0000-7000-8000-000000000002'$$,
  '23514');

-- ── provider_categories ─────────────────────────────────────────────────────
SELECT pg_temp.expect_error('provider_categories: duplicate trade is rejected',
  $$INSERT INTO provider_categories (provider_id, category_id)
    VALUES ('00000000-0000-7000-8000-000000000002', 1)$$,
  '23505');

SELECT pg_temp.expect_error('provider_categories: unknown category is rejected',
  $$INSERT INTO provider_categories (provider_id, category_id)
    VALUES ('00000000-0000-7000-8000-000000000002', 99)$$,
  '23503');

-- ── addresses ───────────────────────────────────────────────────────────────
SELECT pg_temp.expect_ok('addresses: ZIP with a leading zero is kept intact',
  $$INSERT INTO addresses (user_id, line1, city, state, postal_code, is_default)
    VALUES ('00000000-0000-7000-8000-000000000001', '323 Dr MLK Jr Blvd', 'Newark', 'NJ', '07102', true)$$);

SELECT pg_temp.expect_true('addresses: stored ZIP is still 07102',
  (SELECT postal_code = '07102' FROM addresses
    WHERE user_id = '00000000-0000-7000-8000-000000000001'));

SELECT pg_temp.expect_error('addresses: a second default address is rejected',
  $$INSERT INTO addresses (user_id, line1, city, state, postal_code, is_default)
    VALUES ('00000000-0000-7000-8000-000000000001', '1 Other St', 'Newark', 'NJ', '07103', true)$$,
  '23505');

SELECT pg_temp.expect_ok('addresses: additional non-default addresses are fine',
  $$INSERT INTO addresses (user_id, label, line1, city, state, postal_code)
    VALUES ('00000000-0000-7000-8000-000000000001', 'Parents', '1 Other St', 'Newark', 'NJ', '07103-1234')$$);

SELECT pg_temp.expect_error('addresses: malformed ZIP is rejected',
  $$INSERT INTO addresses (user_id, line1, city, state, postal_code)
    VALUES ('00000000-0000-7000-8000-000000000001', '1 St', 'Newark', 'NJ', '7102')$$,
  '23514');

SELECT pg_temp.expect_error('addresses: lowercase state code is rejected',
  $$INSERT INTO addresses (user_id, line1, city, state, postal_code)
    VALUES ('00000000-0000-7000-8000-000000000001', '1 St', 'Newark', 'nj', '07102')$$,
  '23514');

SELECT pg_temp.expect_error('addresses: latitude without longitude is rejected',
  $$INSERT INTO addresses (user_id, line1, city, state, postal_code, latitude)
    VALUES ('00000000-0000-7000-8000-000000000001', '1 St', 'Newark', 'NJ', '07102', 40.7357)$$,
  '23514');

-- ── services (catalog seed) ─────────────────────────────────────────────────
SELECT pg_temp.expect_true('seed: 4 categories and 14 services loaded',
  (SELECT count(*) FROM categories) = 4 AND (SELECT count(*) FROM services) = 14);

SELECT pg_temp.expect_true('seed: every service ID follows category_id * 100 + n',
  NOT EXISTS (SELECT 1 FROM services WHERE id / 100 <> category_id));

SELECT pg_temp.expect_error('services: duplicate name within a category is rejected',
  $$INSERT INTO services (id, category_id, slug, name, default_duration_minutes)
    VALUES (199, 1, 'leak-repair-2', 'Leak repair', 60)$$,
  '23505');

SELECT pg_temp.expect_error('services: duration must be a multiple of 15',
  $$INSERT INTO services (id, category_id, slug, name, default_duration_minutes)
    VALUES (199, 1, 'odd-job', 'Odd job', 50)$$,
  '23514');

-- ── provider_services ───────────────────────────────────────────────────────
SELECT pg_temp.expect_ok('provider_services: provider can offer a service in their own trade',
  $$INSERT INTO provider_services (provider_id, service_id, category_id, price_cents, duration_minutes)
    VALUES ('00000000-0000-7000-8000-000000000002', 102, 1, 9000, 60)$$);

SELECT pg_temp.expect_error('provider_services: cannot offer a service outside their trades',
  $$INSERT INTO provider_services (provider_id, service_id, category_id, price_cents, duration_minutes)
    VALUES ('00000000-0000-7000-8000-000000000002', 202, 2, 50000, 240)$$,
  '23503');

SELECT pg_temp.expect_error('provider_services: category_id must match the service''s real category',
  $$INSERT INTO provider_services (provider_id, service_id, category_id, price_cents, duration_minutes)
    VALUES ('00000000-0000-7000-8000-000000000002', 202, 1, 50000, 240)$$,
  '23503');

SELECT pg_temp.expect_error('provider_services: duplicate offer for the same service is rejected',
  $$INSERT INTO provider_services (provider_id, service_id, category_id, price_cents, duration_minutes)
    VALUES ('00000000-0000-7000-8000-000000000002', 102, 1, 8000, 60)$$,
  '23505');

SELECT pg_temp.expect_error('provider_services: price must be positive',
  $$INSERT INTO provider_services (provider_id, service_id, category_id, price_cents, duration_minutes)
    VALUES ('00000000-0000-7000-8000-000000000002', 101, 1, 0, 60)$$,
  '23514');

SELECT pg_temp.expect_error('provider_services: duration must be in 15-minute steps',
  $$INSERT INTO provider_services (provider_id, service_id, category_id, price_cents, duration_minutes)
    VALUES ('00000000-0000-7000-8000-000000000002', 101, 1, 9000, 50)$$,
  '23514');

SELECT pg_temp.expect_error('provider_services: removing a trade with live offers is blocked',
  $$DELETE FROM provider_categories
    WHERE provider_id = '00000000-0000-7000-8000-000000000002' AND category_id = 1$$,
  '23503');

-- ── cascades ────────────────────────────────────────────────────────────────
SELECT pg_temp.expect_ok('cascade: hard-deleting a provider user removes profile, trades and offers',
  $$DELETE FROM users WHERE id = '00000000-0000-7000-8000-000000000002'$$);

SELECT pg_temp.expect_true('cascade: nothing left behind for the deleted provider',
  NOT EXISTS (SELECT 1 FROM providers           WHERE user_id     = '00000000-0000-7000-8000-000000000002')
  AND NOT EXISTS (SELECT 1 FROM provider_categories WHERE provider_id = '00000000-0000-7000-8000-000000000002')
  AND NOT EXISTS (SELECT 1 FROM provider_services   WHERE provider_id = '00000000-0000-7000-8000-000000000002'));

\echo 'All core schema tests passed.'
ROLLBACK;
