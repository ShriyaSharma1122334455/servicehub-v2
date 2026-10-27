// Wipe the database, re-run every migration, then load the dev seed.
//   npm run db:reset
// Development and test only — refuses to run when NODE_ENV=production.
import path from 'node:path';
import { resetDatabase, runSqlFile, SEEDS_DIR } from '../db/migrator.js';
import { closePool } from '../config/database.js';

try {
  await resetDatabase();
  await runSqlFile(path.join(SEEDS_DIR, 'dev_seed.sql'));
  console.log('✅ Development seed data loaded');
} catch (err) {
  console.error('❌', err.message);
  process.exitCode = 1;
} finally {
  await closePool();
}
