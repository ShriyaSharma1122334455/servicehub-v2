-- =============================================================================
-- 0002 — Reference data: trade categories and the service catalog
--
-- IDs are hand-assigned so they are identical in every environment.
-- Service ID convention: category_id * 100 + n  (Plumbing = 1 → 101, 102, ...)
-- =============================================================================


INSERT INTO categories (id, slug, name, icon, description) VALUES
  (1, 'plumbing',     'Plumbing',     'plumbing',     'Leaks, drains, pipes and water heaters'),
  (2, 'electrical',   'Electrical',   'electrical',   'Outlets, panels, wiring and lighting'),
  (3, 'cleaning',     'Cleaning',     'cleaning',     'Regular, deep and move-in/out cleaning'),
  (4, 'pest-control', 'Pest Control', 'pest-control', 'Insects, rodents and prevention');

INSERT INTO services (id, category_id, slug, name, description, default_duration_minutes, price_unit, sort_order) VALUES
  -- Plumbing
  (101, 1, 'leak-repair',            'Leak repair',            'Find and fix leaking pipes, faucets and fixtures',  60,  'fixed',  1),
  (102, 1, 'drain-cleaning',         'Drain cleaning',         'Clear clogged sinks, tubs, showers and floor drains', 60,  'fixed',  2),
  (103, 1, 'pipe-installation',      'Pipe installation',      'Install or replace supply and drain lines',         120, 'hourly', 3),
  (104, 1, 'water-heater-service',   'Water heater service',   'Repair, flush or replace a water heater',           120, 'fixed',  4),
  -- Electrical
  (201, 2, 'outlet-installation',    'Outlet installation',    'Add or replace outlets, including GFCI',            60,  'fixed',  1),
  (202, 2, 'panel-upgrade',          'Panel upgrade',          'Upgrade or replace an electrical panel',            240, 'fixed',  2),
  (203, 2, 'wiring-repair',          'Wiring repair',          'Diagnose and repair faulty wiring',                 120, 'hourly', 3),
  (204, 2, 'light-fixture-install',  'Light fixture install',  'Install ceiling lights, fans and fixtures',         60,  'fixed',  4),
  -- Cleaning
  (301, 3, 'standard-cleaning',      'Standard cleaning',      'Routine cleaning of living areas, kitchen and baths', 120, 'hourly', 1),
  (302, 3, 'deep-cleaning',          'Deep cleaning',          'Top-to-bottom cleaning including inside appliances', 240, 'hourly', 2),
  (303, 3, 'move-in-out-cleaning',   'Move-in/out cleaning',   'Full clean of an empty home before or after a move', 240, 'fixed',  3),
  -- Pest Control
  (401, 4, 'insect-treatment',       'Insect treatment',       'Treatment for ants, roaches, bed bugs and more',     60,  'fixed',  1),
  (402, 4, 'rodent-control',         'Rodent control',         'Trapping, removal and entry-point sealing',          90,  'fixed',  2),
  (403, 4, 'preventive-treatment',   'Preventive treatment',   'Recurring perimeter treatment to keep pests out',    60,  'fixed',  3);

