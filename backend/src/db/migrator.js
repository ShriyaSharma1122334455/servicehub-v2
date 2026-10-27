import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getPool } from '../config/database.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const MIGRATIONS_DIR = path.resolve(__dirname, '../../db/migrations');
export const SEEDS_DIR      = path.resolve(__dirname, '../../db/seeds');

// Any fixed number works; it just has to be the same for every instance.
const MIGRATION_LOCK_ID = 7_210_431;

// Line endings are normalised first: git on Windows may check files out with
// CRLF, and that alone must not look like an edited migration.
const checksumOf = (sql) =>
  createHash('sha256').update(sql.replace(/\r\n/g, '\n')).digest('hex');

// ── runMigrations ─────────────────────────────────────────────────────────
// Applies every db/migrations/*.sql file not applied yet, in filename order.
//  - Each file runs in its own transaction together with its bookkeeping row,
//    so a failed migration leaves no trace and can be fixed and re-run.
//  - schema_migrations stores a checksum; editing a file after it was applied
//    is reported as an error instead of being silently ignored.
//  - An advisory lock stops two app instances from migrating at the same time.
export async function runMigrations({ log = console.log } = {}) {
  const client = await getPool().connect();
  try {
    await client.query('SELECT pg_advisory_lock($1)', [MIGRATION_LOCK_ID]);

    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        filename   text PRIMARY KEY,
        checksum   text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `);

    const { rows } = await client.query('SELECT filename, checksum FROM schema_migrations');
    const applied = new Map(rows.map((r) => [r.filename, r.checksum]));

    const files = (await readdir(MIGRATIONS_DIR))
      .filter((f) => f.endsWith('.sql'))
      .sort();

    // Migrations must run one after another, in order — never in parallel.
    /* eslint-disable no-await-in-loop */
    let count = 0;
    for (const file of files) {
      const sql = await readFile(path.join(MIGRATIONS_DIR, file), 'utf8');
      const checksum = checksumOf(sql);

      if (applied.has(file)) {
        if (applied.get(file) !== checksum) {
          throw new Error(
            `Migration ${file} was changed after it was applied. ` +
            'Add a new migration instead of editing an applied one.',
          );
        }
        continue;
      }

      log(`→ applying ${file}`);
      try {
        await client.query('BEGIN');
        await client.query(sql);
        await client.query(
          'INSERT INTO schema_migrations (filename, checksum) VALUES ($1, $2)',
          [file, checksum],
        );
        await client.query('COMMIT');
      } catch (err) {
        await client.query('ROLLBACK').catch(() => {});
        throw new Error(`Migration ${file} failed: ${err.message}`, { cause: err });
      }
      count += 1;
    }
    /* eslint-enable no-await-in-loop */

    log(count === 0 ? '✅ Database is up to date' : `✅ Applied ${count} migration(s)`);
    return count;
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK_ID]).catch(() => {});
    client.release();
  }
}

// ── runSqlFile ────────────────────────────────────────────────────────────
// Runs one .sql file as-is (used for seeds, which manage their own transaction).
export async function runSqlFile(filePath) {
  const sql = await readFile(filePath, 'utf8');
  await getPool().query(sql);
}

// ── resetDatabase ─────────────────────────────────────────────────────────
// Drops every table, type and function, then re-runs all migrations.
// Development and test only.
export async function resetDatabase({ log = console.log } = {}) {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Refusing to reset the database in production.');
  }
  log('⚠️  Dropping and recreating the public schema');
  await getPool().query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  return runMigrations({ log });
}
