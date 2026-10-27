/**
 * @fileoverview Integration tests for the PostgreSQL layer (config/database.js).
 *
 * These talk to a real database: start it with `docker compose up -d postgres`,
 * run `npm run db:reset`, then `npm test`. DATABASE_URL comes from backend/.env.
 * Without DATABASE_URL the whole suite is skipped, so unit-test runs (and CI
 * without a database) are unaffected.
 *
 * Every write happens inside a transaction that is rolled back, so the
 * database is left unchanged.
 */

import dotenv from 'dotenv';
dotenv.config();

import {
  query,
  withTransaction,
  checkDatabaseConnection,
  closePool,
} from '../config/database.js';

const describeIfDb = process.env.DATABASE_URL ? describe : describe.skip;

const ACTOR_ID = '01900000-0000-7000-8000-00000000a001';

describeIfDb('PostgreSQL layer', () => {
  afterAll(async () => {
    await closePool();
  });

  it('connects and reports PostgreSQL 18 or newer', async () => {
    const db = await checkDatabaseConnection();
    expect(db.ok).toBe(true);
    expect(Number.parseInt(db.version, 10)).toBeGreaterThanOrEqual(18);
  });

  it('runs parameterized queries', async () => {
    const { rows } = await query('SELECT $1::int + $2::int AS total', [2, 3]);
    expect(rows[0].total).toBe(5);
  });

  it('treats a SQL-injection string as plain data', async () => {
    const attack = "x' OR '1'='1'; DROP TABLE users; --";
    const { rows } = await query('SELECT count(*) AS n FROM users WHERE email = $1', [attack]);
    expect(rows[0].n).toBe(0);                       // no match, nothing dropped
    const { rows: still } = await query("SELECT to_regclass('public.users') AS t");
    expect(still[0].t).toBe('users');
  });

  it('returns dates as YYYY-MM-DD strings and counts as numbers', async () => {
    const { rows } = await query("SELECT DATE '2026-03-01' AS d, count(*) AS n FROM categories");
    expect(rows[0].d).toBe('2026-03-01');
    expect(typeof rows[0].n).toBe('number');
  });

  it('commits the work done inside withTransaction', async () => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query('SELECT 42 AS answer');
      return rows[0].answer;
    });
    expect(result).toBe(42);
  });

  it('rolls back everything when withTransaction throws', async () => {
    await expect(
      withTransaction(async (client) => {
        await client.query(
          "INSERT INTO categories (id, slug, name) VALUES (99, 'test-rollback', 'Test rollback')",
        );
        throw new Error('boom');
      }),
    ).rejects.toThrow('boom');

    const { rows } = await query('SELECT count(*) AS n FROM categories WHERE id = 99');
    expect(rows[0].n).toBe(0);
  });

  it('passes actorId to database triggers through app.actor_id', async () => {
    const seen = await withTransaction(
      async (client) => {
        const { rows } = await client.query('SELECT current_actor_id() AS actor');
        return rows[0].actor;
      },
      { actorId: ACTOR_ID },
    );
    expect(seen).toBe(ACTOR_ID);
  });

  it('does not leak actorId outside its transaction', async () => {
    await withTransaction(async () => {}, { actorId: ACTOR_ID });
    const { rows } = await query('SELECT current_actor_id() AS actor');
    expect(rows[0].actor).toBeNull();
  });
});
