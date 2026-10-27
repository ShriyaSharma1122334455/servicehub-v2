import pg from 'pg';
import dotenv from 'dotenv';
dotenv.config();

const { Pool, types } = pg;

// ── Type parsing ──────────────────────────────────────────────────────────
// Return `date` columns as 'YYYY-MM-DD' strings. By default pg turns them into
// JS Dates at local midnight, which can shift the day across time zones.
types.setTypeParser(types.builtins.DATE, (value) => value);
// Return bigint (COUNT(*), identity IDs) as numbers instead of strings.
// Our bigint values stay far below Number.MAX_SAFE_INTEGER.
types.setTypeParser(types.builtins.INT8, (value) => Number(value));

// ── Connection pool ───────────────────────────────────────────────────────
// A pool keeps a few connections open and lends them to requests, instead of
// opening a new connection per query. Created lazily, so importing this file
// never fails when DATABASE_URL is missing (e.g. unit tests).
let _pool = null;

export function getPool() {
  if (!_pool) {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) {
      throw new Error('❌ Missing DATABASE_URL in .env');
    }

    _pool = new Pool({
      connectionString,
      max:                     Number(process.env.DB_POOL_MAX) || 10,
      idleTimeoutMillis:       30_000,   // close connections idle for 30s
      connectionTimeoutMillis: 5_000,    // fail fast if the DB is unreachable
      statement_timeout:       10_000,   // no single query may run longer than 10s
      application_name:        'servicehub-backend',
    });

    // An idle connection can error (e.g. the DB restarts). Without a listener
    // this would crash the process.
    _pool.on('error', (err) => {
      console.error('❌ Idle database connection error:', err.message);
    });
  }
  return _pool;
}

// ── query ─────────────────────────────────────────────────────────────────
// Always pass values separately from the SQL text:
//   query('SELECT * FROM users WHERE email = $1', [email])
// Postgres receives them apart, so a value can never be run as SQL. Never
// build SQL by concatenating user input into the string.
export const query = (text, params = []) => getPool().query(text, params);

// ── withTransaction ───────────────────────────────────────────────────────
// Runs `fn(client)` inside BEGIN/COMMIT on one connection, rolling back if it
// throws. Pass `actorId` to record who is acting: database triggers (e.g.
// booking_events) read it via current_setting('app.actor_id').
export async function withTransaction(fn, { actorId } = {}) {
  const client = await getPool().connect();
  try {
    await client.query('BEGIN');
    if (actorId) {
      // `true` = local to this transaction, like SET LOCAL.
      await client.query("SELECT set_config('app.actor_id', $1, true)", [actorId]);
    }
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

// ── Health check ──────────────────────────────────────────────────────────
// Used at startup and by GET /api/health. Never throws.
export async function checkDatabaseConnection() {
  const started = Date.now();
  try {
    const { rows } = await query('SELECT current_setting($1) AS version', ['server_version']);
    return { ok: true, version: rows[0].version, latencyMs: Date.now() - started };
  } catch (err) {
    return { ok: false, error: err.message, latencyMs: Date.now() - started };
  }
}

// ── Shutdown ──────────────────────────────────────────────────────────────
export async function closePool() {
  if (_pool) {
    const pool = _pool;
    _pool = null;
    await pool.end();
  }
}
