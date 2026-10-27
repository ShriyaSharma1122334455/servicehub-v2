-- =============================================================================
-- Load-test seed — LOCAL / TEST DATABASES ONLY, never production.
-- Run after the migrations (and optionally after dev_seed.sql):
--   npm run db:seed:loadtest
--
-- Generates 5,000 providers across the four trades with about 16,000 offers,
-- so browse/search queries in the k6 load test read realistic amounts of
-- data instead of a handful of rows. Re-running replaces the previous batch.
--
-- Synthetic data: ratings are written straight to providers.rating_count /
-- rating_sum (no review rows), which is all the browse endpoints read.
-- setseed() makes every run generate the same data.
-- =============================================================================

BEGIN;

SELECT setseed(0.42);

-- Remove a previous batch (cascades to providers, trades and offers).
DELETE FROM users WHERE email LIKE 'loadtest.provider%@example.com';

-- ── Users ───────────────────────────────────────────────────────────────────
INSERT INTO users (email, password_hash, full_name, role, verification_status)
SELECT format('loadtest.provider%s@example.com', g),
       'seed-placeholder',
       format('Load Test Provider %s', g),
       'provider',
       CASE WHEN random() < 0.85 THEN 'verified' ELSE 'unverified' END::verification_status
  FROM generate_series(1, 5000) AS g;

CREATE TEMP TABLE lt_providers ON COMMIT DROP AS
SELECT id, row_number() OVER (ORDER BY id) AS n
  FROM users
 WHERE email LIKE 'loadtest.provider%@example.com';

-- ── Provider profiles (about 8% paused; ratings 0–200 reviews, 3.5–5.0 avg)
INSERT INTO providers (user_id, business_name, description, years_experience,
                       service_radius_km, is_active, rating_count, rating_sum)
SELECT lt.id,
       format('Load Test Services %s', lt.n),
       'Synthetic provider generated for load testing.',
       (random() * 30)::int,
       10 + (random() * 40)::int,
       random() > 0.08,
       r.cnt,
       round(r.cnt * (3.5 + random() * 1.5))::int
  FROM lt_providers lt
 CROSS JOIN LATERAL (SELECT (random() * 200)::int AS cnt) AS r;

-- ── Trades: one primary trade each, about 30% also have a second ───────────
INSERT INTO provider_categories (provider_id, category_id)
SELECT id, 1 + (n % 4) FROM lt_providers;

INSERT INTO provider_categories (provider_id, category_id)
SELECT id, 1 + ((n + 1) % 4) FROM lt_providers WHERE random() < 0.30;

-- ── Offers: each catalog service in a provider's trades, with 70% chance ───
-- Prices are random between $40 and $250, rounded to $5.
INSERT INTO provider_services (provider_id, service_id, category_id, price_cents, duration_minutes)
SELECT pc.provider_id,
       s.id,
       s.category_id,
       (round((4000 + random() * 21000) / 500) * 500)::int,
       s.default_duration_minutes
  FROM provider_categories pc
  JOIN lt_providers lt ON lt.id = pc.provider_id
  JOIN services s      ON s.category_id = pc.category_id AND s.is_active
 WHERE random() < 0.70;

-- Refresh planner statistics so Postgres picks good plans for the new data.
ANALYZE users;
ANALYZE providers;
ANALYZE provider_categories;
ANALYZE provider_services;

COMMIT;
