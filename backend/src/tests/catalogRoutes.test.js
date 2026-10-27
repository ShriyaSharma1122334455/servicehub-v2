/**
 * @fileoverview Tests for the PostgreSQL-backed catalog endpoints:
 *   GET /api/categories, /api/categories/:id, /api/categories/slug/:slug
 *   GET /api/services, /api/services/:id
 *   GET /api/providers/by-service/:serviceId
 *
 * The database module is mocked, so these check input handling, the values
 * passed to SQL, and the response shape — no database needed.
 */

import { jest } from '@jest/globals';

process.env.NODE_ENV = 'test';
process.env.SUPABASE_URL = 'https://test.supabase.co';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'test-service-key';

const mockQuery = jest.fn();

jest.unstable_mockModule('../config/supabase.js', () => ({
  default: {},
  checkSupabaseConnection: jest.fn(),
}));

jest.unstable_mockModule('../config/database.js', () => ({
  query: mockQuery,
  checkDatabaseConnection: jest.fn().mockResolvedValue({ ok: true, version: 'test', latencyMs: 0 }),
  closePool: jest.fn(),
  withTransaction: jest.fn(),
  getPool: jest.fn(),
}));

const { default: app } = await import('../server.js');
const { default: request } = await import('supertest');

const lastParams = () => mockQuery.mock.calls.at(-1)[1];

beforeEach(() => {
  mockQuery.mockReset();
});

// ── Categories ────────────────────────────────────────────────────────────
describe('GET /api/categories', () => {
  it('returns all categories', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [{ id: 1, slug: 'plumbing', name: 'Plumbing' }] });

    const res = await request(app).get('/api/categories');

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ success: true, data: [{ id: 1, slug: 'plumbing', name: 'Plumbing' }] });
  });

  it('returns 500 without leaking database errors', async () => {
    mockQuery.mockRejectedValueOnce(new Error('relation "categories" does not exist'));

    const res = await request(app).get('/api/categories');

    expect(res.statusCode).toBe(500);
    expect(JSON.stringify(res.body)).not.toMatch(/relation/);
  });
});

describe('GET /api/categories/:id', () => {
  it('returns 404 for a non-numeric ID without querying', async () => {
    const res = await request(app).get('/api/categories/abc');
    expect(res.statusCode).toBe(404);
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it('returns 404 when the category does not exist', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    const res = await request(app).get('/api/categories/9');
    expect(res.statusCode).toBe(404);
    expect(lastParams()).toEqual([9]);
  });
});

describe('GET /api/categories/slug/:slug', () => {
  it('passes the slug as a parameter', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [{ id: 2, slug: 'electrical' }] });
    const res = await request(app).get('/api/categories/slug/electrical');
    expect(res.statusCode).toBe(200);
    expect(lastParams()).toEqual(['electrical']);
  });
});

// ── Services ──────────────────────────────────────────────────────────────
describe('GET /api/services', () => {
  it('uses default pagination', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });

    const res = await request(app).get('/api/services');

    expect(res.statusCode).toBe(200);
    expect(res.body).toMatchObject({ success: true, count: 0, page: 1, limit: 20 });
    // [categoryId, categorySlug, search, minCents, maxCents, limit, offset]
    expect(lastParams()).toEqual([null, null, null, null, null, 20, 0]);
  });

  it('accepts a category ID or a slug', async () => {
    mockQuery.mockResolvedValue({ rows: [] });

    await request(app).get('/api/services?category=3');
    expect(lastParams().slice(0, 2)).toEqual([3, null]);

    await request(app).get('/api/services?category=pest-control');
    expect(lastParams().slice(0, 2)).toEqual([null, 'pest-control']);
  });

  it('caps the page size at 100 and computes the offset', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    await request(app).get('/api/services?limit=100000&page=3');
    expect(lastParams().slice(5)).toEqual([100, 200]);
  });

  it('converts dollar price filters to cents', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    await request(app).get('/api/services?minPrice=49.99&maxPrice=150');
    expect(lastParams().slice(3, 5)).toEqual([4999, 15000]);
  });

  it('treats search text literally, including % and _', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    await request(app).get(`/api/services?search=${encodeURIComponent("100%_' OR 1=1 --")}`);
    expect(lastParams()[2]).toBe("%100\\%\\_' OR 1=1 --%");
  });
});

describe('GET /api/services/:id', () => {
  it('returns 404 for an ID outside the catalog range without querying', async () => {
    const res = await request(app).get('/api/services/99999999');
    expect(res.statusCode).toBe(404);
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it('returns the service', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [{ id: 102, name: 'Drain cleaning', provider_count: 3 }] });
    const res = await request(app).get('/api/services/102');
    expect(res.statusCode).toBe(200);
    expect(res.body.data).toMatchObject({ id: 102, provider_count: 3 });
  });
});

// ── Providers by service ──────────────────────────────────────────────────
describe('GET /api/providers/by-service/:serviceId', () => {
  it('rejects a non-numeric service ID with 400', async () => {
    const res = await request(app).get('/api/providers/by-service/drain-cleaning');
    expect(res.statusCode).toBe(400);
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it('returns a page of providers', async () => {
    mockQuery.mockResolvedValueOnce({
      rows: [{ id: 'p1', business_name: 'Rivera Plumbing', price_cents: 12500, custom_price: 125 }],
    });

    const res = await request(app).get('/api/providers/by-service/102?page=2&limit=10');

    expect(res.statusCode).toBe(200);
    expect(res.body).toMatchObject({ success: true, count: 1, page: 2, limit: 10 });
    expect(lastParams()).toEqual([102, 10, 10]);
  });
});
