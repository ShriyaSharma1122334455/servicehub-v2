import { jest } from '@jest/globals';

let mockFromResult = { data: [], error: null }; 
function createChainProxy() {
  const handler = {
    get(target, prop) {
      // When awaited, JS calls .then()
      if (prop === 'then') {
        return (resolve) => resolve(mockFromResult);
      }
      // Any chained method returns the proxy itself
      return jest.fn().mockReturnValue(new Proxy({}, handler));
    },
  };
  return new Proxy({}, handler);
}

/** Sequential `{ data, error }` for each awaited PostgREST chain (dashboard tests). */
let supabaseAwaitQueue = [];

function createQueuedChainProxy() {
  const handler = {
    get(target, prop) {
      if (prop === 'then') {
        return (resolve) => {
          const next = supabaseAwaitQueue.shift();
          resolve(
            next !== undefined
              ? next
              : { data: null, error: { message: 'test: unexpected extra supabase await' } },
          );
        };
      }
      return jest.fn().mockReturnValue(new Proxy({}, handler));
    },
  };
  return new Proxy({}, handler);
}

function mockProviderAuth() {
  setSupabaseClient({
    auth: {
      getUser: jest.fn().mockResolvedValue({
        data: {
          user: {
            id: 'auth-provider-1',
            email: 'provider@test.com',
            user_metadata: { role: 'provider' },
          },
        },
        error: null,
      }),
    },
  });
}

function mockCustomerAuth() {
  setSupabaseClient({
    auth: {
      getUser: jest.fn().mockResolvedValue({
        data: {
          user: {
            id: 'auth-customer-1',
            email: 'customer@test.com',
            user_metadata: { role: 'customer' },
          },
        },
        error: null,
      }),
    },
  });
}

const mockFrom = jest.fn(() => createChainProxy());

// ✅ FIX: use signUp (not admin.createUser) — matches what authController calls
const mockSignUp = jest.fn();
const mockSignIn = jest.fn();

const mockSupabaseClient = {
  from: mockFrom,
  auth: {
    signUp: mockSignUp,
    signInWithPassword: mockSignIn,
  },
};

jest.unstable_mockModule('../config/supabase.js', () => ({
  default: mockSupabaseClient,
  checkSupabaseConnection: jest.fn(),
}));

// Health checks hit PostgreSQL; these tests don't need a real database.
const mockCheckDatabaseConnection = jest.fn().mockResolvedValue({ ok: true, version: 'test', latencyMs: 0 });
jest.unstable_mockModule('../config/database.js', () => ({
  checkDatabaseConnection: mockCheckDatabaseConnection,
  closePool: jest.fn(),
  query: jest.fn(),
  withTransaction: jest.fn(),
  getPool: jest.fn(),
}));

// ── NOW import the app (after mocks are in place) ─────────────────────────
const { default: app } = await import('../server.js');
import request from 'supertest';
import { describe, it, expect, beforeEach, afterEach } from '@jest/globals';
import { setSupabaseClient, resetSupabaseClient } from '../middleware/authMiddleware.js';

// ── Reset mocks between tests ─────────────────────────────────────────────
beforeEach(() => {
  jest.clearAllMocks();
  mockFromResult = { data: [], error: null };
  mockFrom.mockImplementation(() => createChainProxy());
});

// ─── 1. Health check ──────────────────────────────────────────────────────
describe('Health', () => {
  it('GET /api/health returns 200', async () => {
    const res = await request(app).get('/api/health');
    expect(res.statusCode).toBe(200);
    expect(res.body).toHaveProperty('status', 'healthy');
    expect(res.body).toHaveProperty('database', 'up');
  });

  it('GET /api/health returns 503 when the database is down', async () => {
    mockCheckDatabaseConnection.mockResolvedValueOnce({ ok: false, error: 'connection refused', latencyMs: 5 });
    const res = await request(app).get('/api/health');
    expect(res.statusCode).toBe(503);
    expect(res.body).toHaveProperty('status', 'unhealthy');
    expect(res.body).toHaveProperty('database', 'down');
  });
});

// ─── 2. Auth routes ───────────────────────────────────────────────────────
describe('Auth – /api/auth', () => {
  it('POST /register creates a new user (201)', async () => {
    // ✅ FIX: mock signUp (not createUser), return user + session
    mockSignUp.mockResolvedValueOnce({
      data: {
        user: {
          id: 'uuid-1',
          email: 'test@example.com',
          user_metadata: { role: 'customer' },
        },
        session: { access_token: 'fake-jwt-token' },
      },
      error: null,
    });
    mockFromResult = { data: { id: 'internal-user-1' }, error: null };

    const res = await request(app).post('/api/auth/register').send({
      email: 'newuser@example.com',
      password: 'ValidPass1!',
      fullName: 'Test User',
      phone: '1234567890',
      dob: '1990-06-15',
      street: '123 Main St',
      city: 'New York',
      state: 'NY',
      zip: '10001',
      role: 'customer'
    });

    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.data).toHaveProperty('token');
    expect(res.body.data.user).toHaveProperty('id');
  });

  it('POST /register rejects missing fields (400)', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'test@example.com' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });

  it('POST /register rejects short password (400)', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'test@example.com', password: '123', fullName: 'Test' });
    expect(res.statusCode).toBe(400);
    expect(res.body).toHaveProperty('message');
  });

  it('POST /register rejects duplicate email (400)', async () => {
    // ✅ FIX: mock signUp (not createUser)
    mockSignUp.mockResolvedValueOnce({
      data: null,
      error: { message: 'User already registered' },
    });

    const res = await request(app).post('/api/auth/register').send({
      email: 'dup@example.com',
      password: 'Password123!',
      fullName: 'Dup User',
      role: 'customer',
    });

    expect(res.statusCode).toBe(400);
  });


  it('POST /login returns token for valid credentials', async () => {
    mockSignIn.mockResolvedValueOnce({
      data: {
        session: { access_token: 'fake-jwt-token' },
        user: { id: 'uuid-1', email: 'test@example.com', user_metadata: { role: 'customer' } },
      },
      error: null,
    });
    // ensurePublicUserRow: getInternalUser finds an existing profile — no upsert
    mockFromResult = { data: { id: 'internal-user-1', role: 'customer' }, error: null };

    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'test@example.com', password: 'Password123!' });

    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.data).toHaveProperty('token');
  });

  it('POST /login upserts public.users when auth user has no profile row', async () => {
    mockSignIn.mockResolvedValueOnce({
      data: {
        session: { access_token: 'fake-jwt-token' },
        user: {
          id: 'uuid-orphan',
          email: 'orphan@example.com',
          user_metadata: { role: 'customer', full_name: 'Orphan User' },
        },
      },
      error: null,
    });

    let fromAwaitCount = 0;
    mockFrom.mockImplementation(() => {
      const handler = {
        get(target, prop) {
          if (prop === 'then') {
            return (resolve) => {
              fromAwaitCount += 1;
              if (fromAwaitCount === 1) {
                resolve({ data: null, error: { code: 'PGRST116', message: 'not found' } });
              } else {
                resolve({ data: null, error: null });
              }
            };
          }
          return jest.fn().mockReturnValue(new Proxy({}, handler));
        },
      };
      return new Proxy({}, handler);
    });

    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'orphan@example.com', password: 'Password123!' });

    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(fromAwaitCount).toBe(2);
  });

  it('POST /login rejects wrong password (401)', async () => {
    mockSignIn.mockResolvedValueOnce({
      data: {
        user: null,
        session: null,
      },
      error: { message: 'Invalid login credentials' },
    });
    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'test@example.com', password: 'WrongPass!' });
    expect(res.statusCode).toBe(401);
  });

  it('POST /login rejects missing fields (400)', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({});

    expect(res.statusCode).toBe(400);
  });
});

// ─── 3. Categories ────────────────────────────────────────────────────────
// Now served from PostgreSQL — covered in catalogRoutes.test.js.

// ─── 4. Providers ─────────────────────────────────────────────────────────
describe('Providers – /api/providers', () => {
  it('GET / returns provider list', async () => {
    mockFromResult = { data: [], error: null };

    const res = await request(app).get('/api/providers');
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body).toHaveProperty('pagination');
  });

  it('GET /:id returns 404 for non-existent provider', async () => {
    mockFromResult = { data: null, error: { message: 'not found' } };

    const res = await request(app).get('/api/providers/non-existent-uuid');
    expect(res.statusCode).toBe(404);
  });
});

// ─── 5. Provider dashboard – GET /api/dashboard/provider ─────────────────
describe('Provider dashboard – GET /api/dashboard/provider', () => {
  beforeEach(() => {
    supabaseAwaitQueue = [];
    mockFrom.mockImplementation(() => createQueuedChainProxy());
  });

  afterEach(() => {
    resetSupabaseClient();
    mockFrom.mockImplementation(() => createChainProxy());
  });

  it('returns 403 when JWT role is not provider', async () => {
    setSupabaseClient({
      auth: {
        getUser: jest.fn().mockResolvedValue({
          data: {
            user: {
              id: 'auth-customer-1',
              email: 'c@test.com',
              user_metadata: { role: 'customer' },
            },
          },
          error: null,
        }),
      },
    });

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(403);
    expect(res.body.success).toBe(false);
  });

  it('returns 404 when public.users profile is missing', async () => {
    mockProviderAuth();
    supabaseAwaitQueue.push({ data: null, error: null });

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(404);
    expect(res.body.success).toBe(false);
  });

  it('returns 404 when provider row is missing', async () => {
    mockProviderAuth();
    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      { data: null, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(404);
    expect(res.body.error).toMatch(/provider profile/i);
  });

  it('returns 200 with stats, empty breakdown, and empty calendar when there are no bookings', async () => {
    mockProviderAuth();
    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      {
        data: {
          id: 'prov-1',
          business_name: 'Test Co',
          rating_avg: 4.2,
        },
        error: null,
      },
      { data: [], error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.data.provider).toEqual({
      id: 'prov-1',
      business_name: 'Test Co',
      rating_avg: 4.2,
    });
    expect(res.body.data.stats).toMatchObject({
      total_bookings: 0,
      pending: 0,
      confirmed: 0,
      completed: 0,
      cancelled: 0,
      total_earnings: 0,
    });
    expect(res.body.data.breakdown).toEqual({ pending: [], confirmed: [] });
    expect(res.body.data.calendar).toEqual([]);
    expect(supabaseAwaitQueue).toHaveLength(0);
  });

  it('aggregates stats, breakdown lists, and calendar (includes confirmed only)', async () => {
    mockProviderAuth();
    const bookings = [
      {
        id: 'b1',
        status: 'pending',
        scheduled_at: '2026-05-10T14:00:00.000Z',
        total_price: 100,
        service: { name: 'Cleaning' },
        customer: { full_name: 'Alex' },
      },
      {
        id: 'b2',
        status: 'confirmed',
        scheduled_at: '2026-05-10T16:00:00.000Z',
        total_price: 80,
        service: { name: 'Plumbing' },
        customer: { full_name: 'Blake' },
      },
      {
        id: 'b3',
        status: 'completed',
        scheduled_at: '2026-04-01T10:00:00.000Z',
        total_price: 50.25,
        service: { name: 'Electrical' },
        customer: { full_name: 'Casey' },
      },
      {
        id: 'b4',
        status: 'cancelled',
        scheduled_at: '2026-05-11T09:00:00.000Z',
        total_price: 200,
        service: { name: 'Paint' },
        customer: { full_name: 'Dana' },
      },
    ];

    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      {
        data: { id: 'prov-1', business_name: 'Biz', rating_avg: 5 },
        error: null,
      },
      { data: bookings, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.data.stats).toMatchObject({
      total_bookings: 4,
      pending: 1,
      confirmed: 1,
      completed: 1,
      cancelled: 1,
      total_earnings: 50.25,
    });

    expect(res.body.data.breakdown.pending).toHaveLength(1);
    expect(res.body.data.breakdown.pending[0]).toMatchObject({
      id: 'b1',
      status: 'pending',
      scheduled_date: '2026-05-10',
      scheduled_time: '14:00',
      service_name: 'Cleaning',
      customer_name: 'Alex',
      total_price: 100,
    });

    expect(res.body.data.breakdown.confirmed).toHaveLength(1);
    expect(res.body.data.breakdown.confirmed[0]).toMatchObject({
      id: 'b2',
      status: 'confirmed',
      service_name: 'Plumbing',
    });

    const cal = res.body.data.calendar;
    expect(cal).toHaveLength(1);
    const byDate = Object.fromEntries(cal.map((d) => [d.date, d.items]));
    expect(byDate['2026-05-10'].map((i) => i.id).sort()).toEqual(['b2']);
    expect(byDate['2026-05-10'][0]).toMatchObject({
      customer_name: 'Blake',
      scheduled_date: '2026-05-10',
      scheduled_time: '16:00',
    });
    expect(cal.some((d) => d.date === '2026-04-01')).toBe(false);
    expect(cal.some((d) => d.date === '2026-05-11')).toBe(false);
    expect(supabaseAwaitQueue).toHaveLength(0);
  });

  it('returns date/time fields in both pending and confirmed breakdown rows', async () => {
    mockProviderAuth();
    const bookings = [
      {
        id: 'p1',
        status: 'pending',
        scheduled_at: '2026-06-15T09:30:00.000Z',
        total_price: 120,
        service: { name: 'Deep Clean' },
        customer: { full_name: 'Rory' },
      },
      {
        id: 'c1',
        status: 'confirmed',
        scheduled_at: '2026-06-16T13:45:00.000Z',
        total_price: 95,
        service: { name: 'Pipe Repair' },
        customer: { full_name: 'Jordan' },
      },
    ];

    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      {
        data: { id: 'prov-1', business_name: 'Biz', rating_avg: 4.8 },
        error: null,
      },
      { data: bookings, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.data.breakdown.pending[0]).toMatchObject({
      id: 'p1',
      scheduled_date: '2026-06-15',
      scheduled_time: '09:30',
      customer_name: 'Rory',
      service_name: 'Deep Clean',
    });
    expect(res.body.data.breakdown.confirmed[0]).toMatchObject({
      id: 'c1',
      scheduled_date: '2026-06-16',
      scheduled_time: '13:45',
      customer_name: 'Jordan',
      service_name: 'Pipe Repair',
    });
    expect(supabaseAwaitQueue).toHaveLength(0);
  });

  it('ignores pending/completed/cancelled bookings in calendar and keeps confirmed', async () => {
    mockProviderAuth();
    const bookings = [
      {
        id: 'p1',
        status: 'pending',
        scheduled_at: '2026-07-01T09:00:00.000Z',
        total_price: 30,
        service: { name: 'Pending Job' },
        customer: { full_name: 'A' },
      },
      {
        id: 'cm1',
        status: 'completed',
        scheduled_at: '2026-07-01T10:00:00.000Z',
        total_price: 50,
        service: { name: 'Completed Job' },
        customer: { full_name: 'B' },
      },
      {
        id: 'x1',
        status: 'cancelled',
        scheduled_at: '2026-07-01T11:00:00.000Z',
        total_price: 60,
        service: { name: 'Cancelled Job' },
        customer: { full_name: 'C' },
      },
      {
        id: 'c1',
        status: 'confirmed',
        scheduled_at: '2026-07-01T12:15:00.000Z',
        total_price: 70,
        service: { name: 'Confirmed Job' },
        customer: { full_name: 'D' },
      },
    ];

    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      {
        data: { id: 'prov-1', business_name: 'Biz', rating_avg: 4.8 },
        error: null,
      },
      { data: bookings, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.data.calendar).toHaveLength(1);
    expect(res.body.data.calendar[0]).toMatchObject({
      date: '2026-07-01',
    });
    expect(res.body.data.calendar[0].items).toHaveLength(1);
    expect(res.body.data.calendar[0].items[0]).toMatchObject({
      id: 'c1',
      status: 'confirmed',
      customer_name: 'D',
      scheduled_date: '2026-07-01',
      scheduled_time: '12:15',
    });
    expect(supabaseAwaitQueue).toHaveLength(0);
  });

  it('returns 403 when internal user role is not provider (stale metadata)', async () => {
    mockProviderAuth();
    supabaseAwaitQueue.push({ data: { id: 'internal-1', role: 'customer' }, error: null });

    const res = await request(app)
      .get('/api/dashboard/provider')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(403);
    expect(res.body.error).toMatch(/only available for provider/i);
  });

  it('applies calendar range + statuses filters and returns calendar metadata', async () => {
    mockProviderAuth();
    const allBookings = [
      {
        id: 'in-range-confirmed',
        status: 'confirmed',
        scheduled_at: '2026-08-05T12:00:00.000Z',
        total_price: 90,
        service: { name: 'Plumbing' },
        customer: { full_name: 'A' },
      },
      {
        id: 'out-range-confirmed',
        status: 'confirmed',
        scheduled_at: '2026-09-01T12:00:00.000Z',
        total_price: 120,
        service: { name: 'Electrical' },
        customer: { full_name: 'B' },
      },
      {
        id: 'in-range-pending',
        status: 'pending',
        scheduled_at: '2026-08-06T09:00:00.000Z',
        total_price: 60,
        service: { name: 'Cleaning' },
        customer: { full_name: 'C' },
      },
    ];
    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      { data: { id: 'prov-1', business_name: 'Biz', rating_avg: 4.9 }, error: null },
      { data: allBookings, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider?start_date=2026-08-01&end_date=2026-08-31&statuses=pending&timezone=America/New_York')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.data.calendar_meta).toMatchObject({
      start_date: '2026-08-01',
      end_date: '2026-08-31',
      statuses: ['pending'],
      provider_timezone: 'America/New_York',
    });
    expect(res.body.data.calendar).toHaveLength(1);
    expect(res.body.data.calendar[0]).toMatchObject({
      date: '2026-08-06',
    });
    expect(res.body.data.calendar[0].items).toHaveLength(1);
    expect(res.body.data.calendar[0].items[0]).toMatchObject({
      id: 'in-range-pending',
      status: 'pending',
      customer_name: 'C',
      scheduled_date: '2026-08-06',
      scheduled_time: '05:00',
    });
  });

  it('falls back to confirmed when statuses query contains only unsupported values', async () => {
    mockProviderAuth();
    const allBookings = [
      {
        id: 'confirmed-1',
        status: 'confirmed',
        scheduled_at: '2026-08-05T12:00:00.000Z',
        total_price: 90,
        service: { name: 'Plumbing' },
        customer: { full_name: 'A' },
      },
      {
        id: 'pending-1',
        status: 'pending',
        scheduled_at: '2026-08-06T09:00:00.000Z',
        total_price: 60,
        service: { name: 'Cleaning' },
        customer: { full_name: 'C' },
      },
    ];
    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      { data: { id: 'prov-1', business_name: 'Biz', rating_avg: 4.9 }, error: null },
      { data: allBookings, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider?start_date=2026-08-01&end_date=2026-08-31&statuses=foo,bar')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.data.calendar_meta.statuses).toEqual(['confirmed']);
    expect(res.body.data.calendar).toHaveLength(1);
    expect(res.body.data.calendar[0].items).toHaveLength(1);
    expect(res.body.data.calendar[0].items[0].id).toBe('confirmed-1');
  });

  it('groups calendar days and times using requested timezone', async () => {
    mockProviderAuth();
    const bookings = [
      {
        id: 'tz-1',
        status: 'confirmed',
        scheduled_at: '2026-08-06T00:30:00.000Z',
        total_price: 70,
        service: { name: 'Confirmed Job' },
        customer: { full_name: 'D' },
      },
    ];

    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      { data: { id: 'prov-1', business_name: 'Biz', rating_avg: 4.8 }, error: null },
      { data: bookings, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider?start_date=2026-08-01&end_date=2026-08-31&statuses=confirmed&timezone=America/New_York')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.data.calendar_meta.provider_timezone).toBe('America/New_York');
    expect(res.body.data.calendar).toHaveLength(1);
    expect(res.body.data.calendar[0]).toMatchObject({ date: '2026-08-05' });
    expect(res.body.data.calendar[0].items[0]).toMatchObject({
      id: 'tz-1',
      scheduled_date: '2026-08-05',
      scheduled_time: '20:30',
    });
  });

  it('applies date range using provider timezone boundaries (not UTC day boundaries)', async () => {
    mockProviderAuth();
    const bookings = [
      {
        id: 'edge-in-local-day',
        status: 'confirmed',
        scheduled_at: '2026-08-06T02:30:00.000Z',
        total_price: 70,
        service: { name: 'Confirmed Job' },
        customer: { full_name: 'D' },
      },
    ];

    supabaseAwaitQueue.push(
      { data: { id: 'internal-1', role: 'provider' }, error: null },
      { data: { id: 'prov-1', business_name: 'Biz', rating_avg: 4.8 }, error: null },
      { data: bookings, error: null },
    );

    const res = await request(app)
      .get('/api/dashboard/provider?start_date=2026-08-05&end_date=2026-08-05&statuses=confirmed&timezone=America/New_York')
      .set('Authorization', 'Bearer fake-jwt');

    expect(res.statusCode).toBe(200);
    expect(res.body.data.calendar).toHaveLength(1);
    expect(res.body.data.calendar[0]).toMatchObject({ date: '2026-08-05' });
    expect(res.body.data.calendar[0].items[0]).toMatchObject({
      id: 'edge-in-local-day',
      scheduled_date: '2026-08-05',
      scheduled_time: '22:30',
    });
  });
});

describe('Bookings – POST /api/bookings', () => {
  beforeEach(() => {
    supabaseAwaitQueue = [];
    mockFrom.mockImplementation(() => createQueuedChainProxy());
  });

  afterEach(() => {
    resetSupabaseClient();
    mockFrom.mockImplementation(() => createChainProxy());
  });

  it('returns 409 when the requested slot is already booked', async () => {
    mockCustomerAuth();
    supabaseAwaitQueue.push(
      { data: [{ id: 'existing-booking' }], error: null },
    );

    const res = await request(app)
      .post('/api/bookings')
      .set('Authorization', 'Bearer fake-jwt')
      .send({
        provider_id: 'prov-1',
        service_id: 'svc-1',
        scheduled_at: '2026-08-10T10:00:00.000Z',
      });

    expect(res.statusCode).toBe(409);
    expect(res.body.success).toBe(false);
    expect(res.body.code).toBe('SLOT_UNAVAILABLE');
  });

  it('creates booking successfully when slot is free', async () => {
    mockCustomerAuth();

    supabaseAwaitQueue.push(
      { data: [], error: null },
      { data: { id: 'prov-1', is_fully_verified: true, user_id: 'prov-user-uuid' }, error: null },
      { data: { id: 'internal-customer-1', role: 'customer' }, error: null },
      { data: { id: 'svc-1', base_price: 125, provider_id: 'prov-1', is_active: true }, error: null },
      {
        data: {
          id: 'booking-1',
          provider_id: 'prov-1',
          service_id: 'svc-1',
          scheduled_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString(),
          total_price: 125,
          status: 'pending',
        },
        error: null,
      },
    );

    const res = await request(app)
      .post('/api/bookings')
      .set('Authorization', 'Bearer fake-jwt')
      .send({
        provider_id:  'prov-1',
        service_id:   'svc-1',
        scheduled_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString(),
      });

    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.data).toMatchObject({
      id: 'booking-1',
      status: 'pending',
      total_price: 125,
    });
  });
});

// ─── 6. Protected routes ──────────────────────────────────────────────────
describe('Protected route guard', () => {
  const protectedRoutes = [
    { method: 'get', path: '/api/bookings' },
    { method: 'post', path: '/api/bookings' },
    { method: 'get', path: '/api/users/profile' },
    { method: 'get', path: '/api/dashboard/provider' },
  ];

  protectedRoutes.forEach(({ method, path }) => {
    it(`${method.toUpperCase()} ${path} requires auth`, async () => {
      const res = await request(app)[method](path);
      expect([401, 403]).toContain(res.statusCode);
    });
  });
});

// ─── 7. Input validation ──────────────────────────────────────────────────
describe('Input validation', () => {
  it('POST /api/auth/register rejects missing fields', async () => {
    const res = await request(app).post('/api/auth/register').send({ email: 'x@x.com' });
    expect(res.statusCode).toBe(400);
    expect(res.body).toHaveProperty('message');
  });

  it('Responses include Content-Type: application/json', async () => {
    const res = await request(app).get('/api/health');
    expect(res.headers['content-type']).toMatch(/json/);
  });
});

// ─── 8. Security headers ──────────────────────────────────────────────────
describe('Security headers (helmet)', () => {
  it('Response includes X-Content-Type-Options', async () => {
    const res = await request(app).get('/api/health');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
  });

  it('Response includes X-Frame-Options', async () => {
    const res = await request(app).get('/api/health');
    expect(res.headers['x-frame-options']).toBeDefined();
  });
});

// ─── 9. 404 handler ──────────────────────────────────────────────────────
describe('404 handler', () => {
  it('Returns 404 for unknown routes', async () => {
    const res = await request(app).get('/api/nonexistent');
    expect(res.statusCode).toBe(404);
  });
});