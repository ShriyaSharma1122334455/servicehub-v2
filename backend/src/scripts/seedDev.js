// Load seed data from db/seeds.
//   npm run db:seed            → dev_seed.sql (sample marketplace)
//   npm run db:seed:loadtest   → loadtest_seed.sql (5,000 providers for k6)
// Run on a migrated database; development and test only.
import path from 'node:path';
import { runSqlFile, SEEDS_DIR } from '../db/migrator.js';
import { closePool } from '../config/database.js';

const file = path.basename(process.argv[2] ?? 'dev_seed.sql');

try {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Refusing to load seed data in production.');
  }
  await runSqlFile(path.join(SEEDS_DIR, file));
  console.log(`✅ Seed data loaded: ${file}`);
} catch (err) {
  console.error('❌ Seeding failed:', err.message);
  process.exitCode = 1;
} finally {
  await closePool();
}
