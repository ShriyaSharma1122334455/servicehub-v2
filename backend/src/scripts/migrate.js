// Apply pending database migrations.
//   npm run db:migrate
import { runMigrations } from '../db/migrator.js';
import { closePool } from '../config/database.js';

try {
  await runMigrations();
} catch (err) {
  console.error('❌', err.message);
  process.exitCode = 1;
} finally {
  await closePool();
}
