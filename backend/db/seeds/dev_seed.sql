-- =============================================================================
-- Development seed data — LOCAL / TEST DATABASES ONLY, never production.
-- Run after all migrations (0001–0005).
--
-- Creates a small, realistic marketplace: 1 admin, 4 customers, 5 providers
-- across all four trades, their offers, schedules, bookings in every status,
-- reviews, complaints, verifications, payments and AI assessments.
--
-- Fixed IDs make the data easy to reference in tests and while debugging:
--   01900000-0000-7000-8000-00000000a0xx  admin
--   01900000-0000-7000-8000-00000000c0xx  customers
--   01900000-0000-7000-8000-00000000b0xx  providers
--   01900000-0000-7000-8000-00000000d0xx  provider offers
--   01900000-0000-7000-8000-00000000e0xx  bookings
--   01900000-0000-7000-8000-00000000f0xx  damage assessments
--
-- Dates are relative to the day you run it, so "upcoming" bookings stay upcoming.
-- Emails use example.com, a domain reserved for examples.
--
-- password_hash is a placeholder: these accounts can't log in until the auth
-- step adds real argon2id hashes for a known dev password.
-- =============================================================================

BEGIN;

-- ── Users ───────────────────────────────────────────────────────────────────
INSERT INTO users (id, email, email_verified_at, password_hash, full_name, phone, dob, role) VALUES
  ('01900000-0000-7000-8000-00000000a001', 'admin@example.com',       now(), 'seed-placeholder', 'Alex Admin',   '+12015550100', '1988-03-14', 'admin'),
  ('01900000-0000-7000-8000-00000000c001', 'maya.chen@example.com',   now(), 'seed-placeholder', 'Maya Chen',    '+12015550111', '1994-07-02', 'customer'),
  ('01900000-0000-7000-8000-00000000c002', 'omar.hassan@example.com', now(), 'seed-placeholder', 'Omar Hassan',  '+12015550112', '1986-11-23', 'customer'),
  ('01900000-0000-7000-8000-00000000c003', 'lena.park@example.com',   now(), 'seed-placeholder', 'Lena Park',    '+19735550113', '1999-01-30', 'customer'),
  ('01900000-0000-7000-8000-00000000c004', 'raj.mehta@example.com',   NULL,  'seed-placeholder', 'Raj Mehta',    '+19735550114', '1991-05-18', 'customer'),
  ('01900000-0000-7000-8000-00000000b001', 'pat.rivera@example.com',  now(), 'seed-placeholder', 'Pat Rivera',   '+12015550121', '1982-09-09', 'provider'),
  ('01900000-0000-7000-8000-00000000b002', 'sam.okafor@example.com',  now(), 'seed-placeholder', 'Sam Okafor',   '+12015550122', '1979-04-11', 'provider'),
  ('01900000-0000-7000-8000-00000000b003', 'nina.lopez@example.com',  now(), 'seed-placeholder', 'Nina Lopez',   '+19735550123', '1990-12-05', 'provider'),
  ('01900000-0000-7000-8000-00000000b004', 'tom.becker@example.com',  now(), 'seed-placeholder', 'Tom Becker',   '+19735550124', '1984-02-27', 'provider'),
  ('01900000-0000-7000-8000-00000000b005', 'ivy.grant@example.com',   now(), 'seed-placeholder', 'Ivy Grant',    '+12015550125', '1987-08-16', 'provider');

-- ── Providers and their trades ──────────────────────────────────────────────
INSERT INTO providers (user_id, business_name, description, years_experience, license_number,
                       service_radius_km, stripe_account_id, payouts_enabled) VALUES
  ('01900000-0000-7000-8000-00000000b001', 'Rivera Plumbing',        'Family-run plumbing in Essex County. Same-week appointments.', 14, 'NJ-MP-36BI00412', 30, 'acct_seedrivera01', true),
  ('01900000-0000-7000-8000-00000000b002', 'Okafor Home Repair',     'Handyman for small plumbing and electrical jobs.',              19, NULL,              25, 'acct_seedokafor01', true),
  ('01900000-0000-7000-8000-00000000b003', 'Bright Home Cleaning',   'Eco-friendly supplies, insured, background-checked team.',      7,  NULL,              20, 'acct_seedbright01', true),
  ('01900000-0000-7000-8000-00000000b004', 'Green Shield Pest Control', 'Pet-safe treatments and rodent exclusion.',                 11, 'NJ-PA-98000213',  40, 'acct_seedgreen01',  true),
  ('01900000-0000-7000-8000-00000000b005', 'Volt Pro Electric',      'Licensed electricians: panels, EV chargers, lighting.',         9,  'NJ-EC-34EB01927', 35, 'acct_seedvolt01',   true);

INSERT INTO provider_categories (provider_id, category_id) VALUES
  ('01900000-0000-7000-8000-00000000b001', 1),   -- Rivera: plumbing
  ('01900000-0000-7000-8000-00000000b002', 1),   -- Okafor: plumbing ...
  ('01900000-0000-7000-8000-00000000b002', 2),   -- ... and electrical
  ('01900000-0000-7000-8000-00000000b003', 3),   -- Bright: cleaning
  ('01900000-0000-7000-8000-00000000b004', 4),   -- Green Shield: pest control
  ('01900000-0000-7000-8000-00000000b005', 2);   -- Volt Pro: electrical

-- ── Offers (provider_services) ──────────────────────────────────────────────
INSERT INTO provider_services (id, provider_id, service_id, category_id, price_cents, duration_minutes, description) VALUES
  ('01900000-0000-7000-8000-00000000d001', '01900000-0000-7000-8000-00000000b001', 101, 1,   9500,  60, 'Includes up to 2 fittings.'),
  ('01900000-0000-7000-8000-00000000d002', '01900000-0000-7000-8000-00000000b001', 102, 1,  12500,  60, 'Camera inspection included.'),
  ('01900000-0000-7000-8000-00000000d003', '01900000-0000-7000-8000-00000000b001', 104, 1,  18000, 120, NULL),
  ('01900000-0000-7000-8000-00000000d004', '01900000-0000-7000-8000-00000000b002', 101, 1,   8500,  60, NULL),
  ('01900000-0000-7000-8000-00000000d005', '01900000-0000-7000-8000-00000000b002', 201, 2,   9000,  60, 'Standard or GFCI outlets.'),
  ('01900000-0000-7000-8000-00000000d006', '01900000-0000-7000-8000-00000000b002', 203, 2,  11000, 120, 'Hourly rate.'),
  ('01900000-0000-7000-8000-00000000d007', '01900000-0000-7000-8000-00000000b003', 301, 3,   4500, 120, 'Hourly rate, 2-hour minimum.'),
  ('01900000-0000-7000-8000-00000000d008', '01900000-0000-7000-8000-00000000b003', 302, 3,   5500, 240, 'Hourly rate.'),
  ('01900000-0000-7000-8000-00000000d009', '01900000-0000-7000-8000-00000000b003', 303, 3,  32000, 240, 'Up to 3 bedrooms.'),
  ('01900000-0000-7000-8000-00000000d010', '01900000-0000-7000-8000-00000000b004', 401, 4,  12000,  60, NULL),
  ('01900000-0000-7000-8000-00000000d011', '01900000-0000-7000-8000-00000000b004', 402, 4,  16500,  90, 'Includes one follow-up visit.'),
  ('01900000-0000-7000-8000-00000000d012', '01900000-0000-7000-8000-00000000b005', 201, 2,   9500,  60, NULL),
  ('01900000-0000-7000-8000-00000000d013', '01900000-0000-7000-8000-00000000b005', 202, 2, 185000, 240, '200A panel, permit included.'),
  ('01900000-0000-7000-8000-00000000d014', '01900000-0000-7000-8000-00000000b005', 204, 2,  11500,  60, NULL);

-- ── Weekly hours: Mon–Fri 09:00–12:00 and 13:00–17:00; cleaners also Sat 10:00–14:00
INSERT INTO provider_working_hours (provider_id, day_of_week, start_time, end_time)
SELECT p.user_id, d, s.start_time, s.end_time
  FROM providers p
 CROSS JOIN generate_series(1, 5) AS d
 CROSS JOIN (VALUES (time '09:00', time '12:00'), (time '13:00', time '17:00')) AS s(start_time, end_time);

INSERT INTO provider_working_hours (provider_id, day_of_week, start_time, end_time) VALUES
  ('01900000-0000-7000-8000-00000000b003', 6, '10:00', '14:00');

-- Time off: Rivera Plumbing is away for two days, two weeks from now.
INSERT INTO provider_time_off (provider_id, period, reason) VALUES
  ('01900000-0000-7000-8000-00000000b001',
   tstzrange(((current_date + 14) + time '00:00') AT TIME ZONE 'America/New_York',
             ((current_date + 16) + time '00:00') AT TIME ZONE 'America/New_York', '[)'),
   'Family trip');

-- ── Customer addresses ──────────────────────────────────────────────────────
INSERT INTO addresses (user_id, label, line1, line2, city, state, postal_code, latitude, longitude, is_default) VALUES
  ('01900000-0000-7000-8000-00000000c001', 'Home',    '88 Halsey St',         'Apt 4B', 'Newark',      'NJ', '07102', 40.737400, -74.172300, true),
  ('01900000-0000-7000-8000-00000000c002', 'Home',    '215 Bloomfield Ave',   NULL,     'Montclair',   'NJ', '07042', 40.816100, -74.218400, true),
  ('01900000-0000-7000-8000-00000000c003', 'Home',    '40 Newark Ave',        'Unit 12','Jersey City', 'NJ', '07302', 40.720800, -74.043300, true),
  ('01900000-0000-7000-8000-00000000c003', 'Parents', '9 Maple Ter',          NULL,     'Livingston',  'NJ', '07039', 40.795900, -74.314900, false),
  ('01900000-0000-7000-8000-00000000c004', 'Home',    '311 Washington St',    NULL,     'Hoboken',     'NJ', '07030-4818', 40.742500, -74.030200, true);

-- ── Bookings ────────────────────────────────────────────────────────────────
-- Price and address are snapshotted from the offer and the customer's default
-- address, exactly as the booking API will do it. Every booking starts 'pending'.
INSERT INTO bookings (id, customer_id, provider_id, provider_service_id, scheduled_period,
                      price_cents, price_unit,
                      address_line1, address_line2, address_city, address_state, address_postal_code,
                      address_latitude, address_longitude, address_id, customer_notes)
SELECT v.id, v.customer_id, ps.provider_id, ps.id,
       tstzrange(((current_date + v.day_offset) + v.start_time) AT TIME ZONE 'America/New_York',
                 ((current_date + v.day_offset) + v.start_time + make_interval(mins => ps.duration_minutes))
                   AT TIME ZONE 'America/New_York', '[)'),
       ps.price_cents, s.price_unit,
       a.line1, a.line2, a.city, a.state, a.postal_code, a.latitude, a.longitude, a.id,
       v.notes
  FROM (VALUES
    -- id                                       customer                                  offer                                    day  start
    ('01900000-0000-7000-8000-00000000e001'::uuid, '01900000-0000-7000-8000-00000000c001'::uuid, '01900000-0000-7000-8000-00000000d002'::uuid, -10, time '10:00', 'Kitchen sink drains slowly.'),
    ('01900000-0000-7000-8000-00000000e002'::uuid, '01900000-0000-7000-8000-00000000c002'::uuid, '01900000-0000-7000-8000-00000000d005'::uuid,  -6, time '14:00', 'Two outlets in the garage.'),
    ('01900000-0000-7000-8000-00000000e003'::uuid, '01900000-0000-7000-8000-00000000c003'::uuid, '01900000-0000-7000-8000-00000000d008'::uuid,  -3, time '09:00', NULL),
    ('01900000-0000-7000-8000-00000000e004'::uuid, '01900000-0000-7000-8000-00000000c004'::uuid, '01900000-0000-7000-8000-00000000d001'::uuid,   2, time '09:00', 'Leak under the bathroom vanity. Buzzer 3.'),
    ('01900000-0000-7000-8000-00000000e005'::uuid, '01900000-0000-7000-8000-00000000c001'::uuid, '01900000-0000-7000-8000-00000000d013'::uuid,   5, time '09:00', 'Old 100A fuse box.'),
    ('01900000-0000-7000-8000-00000000e006'::uuid, '01900000-0000-7000-8000-00000000c002'::uuid, '01900000-0000-7000-8000-00000000d011'::uuid,   3, time '13:00', NULL),
    ('01900000-0000-7000-8000-00000000e007'::uuid, '01900000-0000-7000-8000-00000000c003'::uuid, '01900000-0000-7000-8000-00000000d006'::uuid,   4, time '10:00', 'Flickering lights in the hallway.')
  ) AS v(id, customer_id, offer_id, day_offset, start_time, notes)
  JOIN provider_services ps ON ps.id = v.offer_id
  JOIN services s          ON s.id  = ps.service_id
  JOIN addresses a         ON a.user_id = v.customer_id AND a.is_default;

-- Status changes go through the trigger, which checks each transition and logs
-- it to booking_events. app.actor_id records who acted.

-- Rivera Plumbing confirms e001 and e004, and completes e001.
SELECT set_config('app.actor_id', '01900000-0000-7000-8000-00000000b001', true);
UPDATE bookings SET status = 'confirmed', confirmed_at = lower(scheduled_period) - interval '2 days'
 WHERE id = '01900000-0000-7000-8000-00000000e001';
UPDATE bookings SET status = 'confirmed'
 WHERE id = '01900000-0000-7000-8000-00000000e004';
UPDATE bookings SET status = 'completed', completed_at = upper(scheduled_period)
 WHERE id = '01900000-0000-7000-8000-00000000e001';

-- Okafor Home Repair completes e002 and declines e007.
SELECT set_config('app.actor_id', '01900000-0000-7000-8000-00000000b002', true);
UPDATE bookings SET status = 'confirmed', confirmed_at = lower(scheduled_period) - interval '1 day'
 WHERE id = '01900000-0000-7000-8000-00000000e002';
UPDATE bookings SET status = 'completed', completed_at = upper(scheduled_period)
 WHERE id = '01900000-0000-7000-8000-00000000e002';
UPDATE bookings SET status = 'declined', cancellation_reason = 'Fully booked that morning.'
 WHERE id = '01900000-0000-7000-8000-00000000e007';

-- Bright Home Cleaning completes e003.
SELECT set_config('app.actor_id', '01900000-0000-7000-8000-00000000b003', true);
UPDATE bookings SET status = 'confirmed', confirmed_at = lower(scheduled_period) - interval '3 days'
 WHERE id = '01900000-0000-7000-8000-00000000e003';
UPDATE bookings SET status = 'completed', completed_at = upper(scheduled_period)
 WHERE id = '01900000-0000-7000-8000-00000000e003';

-- Omar cancels e006 himself. (e005 stays pending, waiting for Volt Pro.)
SELECT set_config('app.actor_id', '01900000-0000-7000-8000-00000000c002', true);
UPDATE bookings SET status = 'cancelled', cancellation_reason = 'Found the entry point and sealed it myself.'
 WHERE id = '01900000-0000-7000-8000-00000000e006';

SELECT set_config('app.actor_id', '', true);

-- ── Reviews (the trigger updates providers.rating_count / rating_sum) ──────
INSERT INTO reviews (booking_id, reviewer_id, provider_id, rating, comment, provider_reply, provider_replied_at) VALUES
  ('01900000-0000-7000-8000-00000000e001', '01900000-0000-7000-8000-00000000c001', '01900000-0000-7000-8000-00000000b001',
   5, 'On time, explained the problem, and the drain is perfect now.', NULL, NULL),
  ('01900000-0000-7000-8000-00000000e002', '01900000-0000-7000-8000-00000000c002', '01900000-0000-7000-8000-00000000b002',
   4, 'Good work. One outlet cover was left a little loose.', 'Thanks Omar, I''ll swing by and tighten it.', now()),
  ('01900000-0000-7000-8000-00000000e003', '01900000-0000-7000-8000-00000000c003', '01900000-0000-7000-8000-00000000b003',
   5, 'Apartment has never been this clean.', NULL, NULL);

-- ── Complaints ──────────────────────────────────────────────────────────────
INSERT INTO complaints (user_id, booking_id, type, subject, description, priority, status, assigned_to, resolution_note) VALUES
  ('01900000-0000-7000-8000-00000000c002', '01900000-0000-7000-8000-00000000e002', 'complaint',
   'Outlet cover left loose', 'One of the two new garage outlets has a loose cover plate.',
   'low', 'resolved', '01900000-0000-7000-8000-00000000a001', 'Provider returned and fixed it the next day.'),
  ('01900000-0000-7000-8000-00000000c004', NULL, 'feedback',
   'Show prices per hour more clearly', 'It was not obvious which offers are hourly and which are a fixed price.',
   'medium', 'open', NULL, NULL);

-- ── Verifications (the trigger syncs users.verification_status) ────────────
INSERT INTO verifications (user_id, document_type, document_key, selfie_key, status,
                           extracted_full_name, extracted_dob, document_number_last4, document_expires_on,
                           face_match_score, registry_check_status, submitted_at, rejection_reason) VALUES
  -- Providers: approved automatically.
  ('01900000-0000-7000-8000-00000000b001', 'drivers_license', 'verif/b001/id.jpg', 'verif/b001/selfie.jpg', 'approved', 'PAT RIVERA', '1982-09-09', '4821', current_date + 900, 96.40, 'clear', now() - interval '30 days', NULL),
  ('01900000-0000-7000-8000-00000000b002', 'passport',        'verif/b002/id.jpg', 'verif/b002/selfie.jpg', 'approved', 'SAM OKAFOR', '1979-04-11', '7730', current_date + 1500, 93.10, 'clear', now() - interval '28 days', NULL),
  ('01900000-0000-7000-8000-00000000b003', 'drivers_license', 'verif/b003/id.jpg', 'verif/b003/selfie.jpg', 'approved', 'NINA LOPEZ', '1990-12-05', '1055', current_date + 600, 97.85, 'clear', now() - interval '25 days', NULL),
  ('01900000-0000-7000-8000-00000000b004', 'state_id',        'verif/b004/id.jpg', 'verif/b004/selfie.jpg', 'approved', 'TOM BECKER', '1984-02-27', '6612', current_date + 1100, 91.20, 'clear', now() - interval '22 days', NULL),
  ('01900000-0000-7000-8000-00000000b005', 'drivers_license', 'verif/b005/id.jpg', 'verif/b005/selfie.jpg', 'approved', 'IVY GRANT',  '1987-08-16', '3398', current_date + 800, 95.00, 'clear', now() - interval '20 days', NULL),
  -- Customers: two approved, one waiting for an admin, one rejected (then retrying below).
  ('01900000-0000-7000-8000-00000000c001', 'drivers_license', 'verif/c001/id.jpg', 'verif/c001/selfie.jpg', 'approved', 'MAYA CHEN',   '1994-07-02', '2207', current_date + 700, 94.60, 'clear', now() - interval '15 days', NULL),
  ('01900000-0000-7000-8000-00000000c002', 'passport',        'verif/c002/id.jpg', 'verif/c002/selfie.jpg', 'approved', 'OMAR HASSAN', '1986-11-23', '9014', current_date + 2000, 92.30, 'clear', now() - interval '12 days', NULL),
  ('01900000-0000-7000-8000-00000000c003', 'state_id',        'verif/c003/id.jpg', 'verif/c003/selfie.jpg', 'pending_review', 'LENA PARK', '1999-01-30', '5560', current_date + 400, 78.50, 'clear', now() - interval '1 day', NULL),
  ('01900000-0000-7000-8000-00000000c004', 'drivers_license', 'verif/c004/id.jpg', 'verif/c004/selfie.jpg', 'rejected', NULL, NULL, NULL, NULL, NULL, NULL, now() - interval '3 days', 'ID photo too blurry to read.');

-- Raj's second attempt, still in progress (allowed: the rejected one is closed).
INSERT INTO verifications (user_id, document_type, status)
VALUES ('01900000-0000-7000-8000-00000000c004', 'drivers_license', 'in_progress');

-- ── Payments (Stripe test-mode style IDs) ───────────────────────────────────
-- Completed jobs were captured; the confirmed upcoming job is authorized (card on hold);
-- the cancelled booking's hold was released. Platform fee: 15%.
INSERT INTO payments (booking_id, stripe_payment_intent_id, amount_cents, platform_fee_cents, status,
                      authorized_at, captured_at, cancelled_at)
SELECT b.id, v.pi, b.price_cents, round(b.price_cents * 0.15), v.status::payment_status,
       b.created_at, CASE WHEN v.status = 'captured' THEN b.completed_at END,
       CASE WHEN v.status = 'cancelled' THEN b.cancelled_at END
  FROM (VALUES
    ('01900000-0000-7000-8000-00000000e001'::uuid, 'pi_seed_e001', 'captured'),
    ('01900000-0000-7000-8000-00000000e002'::uuid, 'pi_seed_e002', 'captured'),
    ('01900000-0000-7000-8000-00000000e003'::uuid, 'pi_seed_e003', 'captured'),
    ('01900000-0000-7000-8000-00000000e004'::uuid, 'pi_seed_e004', 'authorized'),
    ('01900000-0000-7000-8000-00000000e006'::uuid, 'pi_seed_e006', 'cancelled')
  ) AS v(booking_id, pi, status)
  JOIN bookings b ON b.id = v.booking_id;

INSERT INTO stripe_events (id, type, payload, processed_at) VALUES
  ('evt_seed_0001', 'payment_intent.amount_capturable_updated', '{"data": {"object": {"id": "pi_seed_e004"}}}', now()),
  ('evt_seed_0002', 'payment_intent.succeeded',                 '{"data": {"object": {"id": "pi_seed_e003"}}}', now());

-- ── AI damage assessments ───────────────────────────────────────────────────
INSERT INTO damage_assessments (id, user_id, image_key, status, detected_category_id, severity, confidence,
                                summary, model_name, latency_ms, raw_result, error_message, created_at, completed_at) VALUES
  ('01900000-0000-7000-8000-00000000f001', '01900000-0000-7000-8000-00000000c001', 'vda/c001/sink.jpg',
   'completed', 1, 'medium', 0.870, 'Standing water in a kitchen sink basin; likely a partial drain clog.',
   'gemma-4-31b', 2840, '{"category": "plumbing", "severity": "medium"}', NULL,
   now() - interval '11 days', now() - interval '11 days'),
  ('01900000-0000-7000-8000-00000000f002', '01900000-0000-7000-8000-00000000c002', 'vda/c002/garage.jpg',
   'failed', NULL, NULL, NULL, NULL, 'gemma-4-31b', 30000, NULL, 'Model request timed out after 30s.',
   now() - interval '7 days', NULL);

INSERT INTO damage_assessment_services (assessment_id, service_id, rank) VALUES
  ('01900000-0000-7000-8000-00000000f001', 102, 1),   -- Drain cleaning
  ('01900000-0000-7000-8000-00000000f001', 101, 2);   -- Leak repair

-- Maya booked the top recommendation.
UPDATE bookings SET damage_assessment_id = '01900000-0000-7000-8000-00000000f001'
 WHERE id = '01900000-0000-7000-8000-00000000e001';

-- ── Auth ────────────────────────────────────────────────────────────────────
INSERT INTO sessions (user_id, refresh_token_hash, family_id, user_agent, ip_address, last_used_at, expires_at) VALUES
  ('01900000-0000-7000-8000-00000000c001', encode(sha256('seed-refresh-maya'::bytea), 'hex'), uuidv7(),
   'Chrome on Windows', '127.0.0.1', now(), now() + interval '30 days');

INSERT INTO auth_tokens (user_id, purpose, token_hash, expires_at) VALUES
  ('01900000-0000-7000-8000-00000000c004', 'email_verification',
   encode(sha256('seed-verify-raj'::bytea), 'hex'), now() + interval '24 hours');

-- ── Outbox ──────────────────────────────────────────────────────────────────
INSERT INTO outbox (topic, payload, status, attempts, available_at, sent_at) VALUES
  ('email.booking_confirmed', '{"booking_id": "01900000-0000-7000-8000-00000000e004"}', 'sent', 1, now() - interval '1 hour', now() - interval '1 hour'),
  ('email.review_request',    '{"booking_id": "01900000-0000-7000-8000-00000000e003"}', 'sent', 1, now() - interval '2 days', now() - interval '2 days'),
  ('email.booking_reminder',  '{"booking_id": "01900000-0000-7000-8000-00000000e004"}', 'pending', 0,
   (SELECT lower(scheduled_period) - interval '24 hours' FROM bookings WHERE id = '01900000-0000-7000-8000-00000000e004'), NULL);

COMMIT;
