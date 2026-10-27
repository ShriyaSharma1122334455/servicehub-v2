// Load the development seed data (db/seeds/dev_seed.sql).
//   npm run db:seed
// Run on a freshly migrated database; development and test only.
import path from 'node:path';
import { runSqlFile, SEEDS_DIR } from '../db/migrator.js';
import { closePool } from '../config/database.js';

try {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Refusing to load development seed data in production.');
  }
  await runSqlFile(path.join(SEEDS_DIR, 'dev_seed.sql'));
  console.log('✅ Development seed data loaded');
} catch (err) {
  console.error('❌ Seeding failed:', err.message);
  process.exitCode = 1;
} finally {
  await closePool();
}
