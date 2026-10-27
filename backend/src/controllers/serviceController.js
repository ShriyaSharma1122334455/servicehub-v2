import supabase from '../config/supabase.js';
import { query } from '../config/database.js';
import { getInternalUser, profileNotFoundResponse } from '../utils/internalUser.js';
import { parsePagination, escapeLike } from '../utils/pagination.js';

// ── Catalog reads (PostgreSQL) ────────────────────────────────────────────
// Each catalog service is returned with its category and a summary of the
// active offers for it: how many providers offer it and their price range.
// Prices are integer cents; starting_price is the same value in dollars.
const SERVICE_SELECT = `
  SELECT s.id, s.slug, s.name, s.description, s.default_duration_minutes, s.price_unit,
         json_build_object('id', c.id, 'slug', c.slug, 'name', c.name) AS category,
         coalesce(o.provider_count, 0)  AS provider_count,
         o.min_price_cents,
         o.max_price_cents,
         o.min_price_cents / 100.0::float8 AS starting_price
    FROM services s
    JOIN categories c ON c.id = s.category_id
    LEFT JOIN LATERAL (
      SELECT count(*)            AS provider_count,
             min(ps.price_cents) AS min_price_cents,
             max(ps.price_cents) AS max_price_cents
        FROM provider_services ps
        JOIN providers p ON p.user_id = ps.provider_id AND p.is_active
       WHERE ps.service_id = s.id AND ps.is_active
    ) o ON true`;

const dollarsToCents = (value) => {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) : null;
};

// ── Shared ownership helper ───────────────────────────────────────────────

/**
 * Resolves the providers row for the currently authenticated user.
 * Sends the appropriate error response and returns null if not found,
 * so callers can do:  if (!providerProfile) return;
 *
 * @param {string}                         supabaseUserId  — req.user.id
 * @param {import('express').Response}     res
 * @returns {Promise<{id: string}|null>}
 */
async function getCallerProviderProfile(supabaseUserId, res) {
  const internalUser = await getInternalUser(supabaseUserId);
  if (!internalUser) {
    profileNotFoundResponse(res);
    return null;
  }

  const { data: providerProfile, error } = await supabase
    .from('providers')
    .select('id')
    .eq('user_id', internalUser.id)
    .maybeSingle();

  if (error) {
    res.status(400).json({ success: false, error: error.message });
    return null;
  }
  if (!providerProfile) {
    res.status(403).json({ success: false, error: 'Provider profile not found' });
    return null;
  }

  return providerProfile;
}

// listServices

// GET /api/services?category=&search=&minPrice=&maxPrice=&page=&limit=
//   category: category ID (1) or slug (plumbing); prices in dollars.
export const listServices = async (req, res) => {
  try {
    const { category, search, minPrice, maxPrice } = req.query;
    const { page, limit, offset } = parsePagination(req.query);

    const categoryId   = /^\d+$/.test(category ?? '') ? Number(category) : null;
    const categorySlug = category && categoryId === null ? String(category) : null;
    const searchText   = search ? `%${escapeLike(String(search).trim())}%` : null;

    const { rows } = await query(
      `${SERVICE_SELECT}
        WHERE s.is_active
          AND ($1::smallint IS NULL OR s.category_id = $1)
          AND ($2::text     IS NULL OR c.slug = $2)
          AND ($3::text     IS NULL OR s.name ILIKE $3)
          AND ($4::int      IS NULL OR o.min_price_cents >= $4)
          AND ($5::int      IS NULL OR o.min_price_cents <= $5)
        ORDER BY c.id, s.sort_order, s.name
        LIMIT $6 OFFSET $7`,
      [categoryId, categorySlug, searchText,
       dollarsToCents(minPrice), dollarsToCents(maxPrice), limit, offset],
    );

    return res.json({ success: true, count: rows.length, page, limit, data: rows });
  } catch (err) {
    console.error('listServices error:', err);
    res.status(500).json({ success: false, error: 'Failed to list services' });
  }
};

// GET /api/services/:id   (catalog IDs are small integers, e.g. 102)
export const getService = async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id < 1 || id > 32767) {
      return res.status(404).json({ success: false, error: 'Service not found' });
    }

    const { rows } = await query(`${SERVICE_SELECT} WHERE s.id = $1`, [id]);
    if (rows.length === 0) {
      return res.status(404).json({ success: false, error: 'Service not found' });
    }

    res.json({ success: true, data: rows[0] });
  } catch (err) {
    console.error('getService error:', err);
    res.status(500).json({ success: false, error: 'Failed to fetch service' });
  }
};

// createService

export const createService = async (req, res) => {
  try {
    const { category_id, name, description, base_price, duration_minutes, sub_category } = req.body;

    if (!category_id || !name || !base_price || !duration_minutes) {
      return res.status(400).json({
        success: false,
        error: 'category_id, name, base_price and duration_minutes are required',
      });
    }

    const providerProfile = await getCallerProviderProfile(req.user.id, res);
    if (!providerProfile) return;   // response already sent

    const { data: service, error } = await supabase
      .from('services')
      .insert({
        provider_id:      providerProfile.id,
        category_id,
        name,
        description,
        base_price,
        duration_minutes,
        sub_category: sub_category || null,
        is_active:    true,
      })
      .select()
      .single();

    if (error) return res.status(400).json({ success: false, error: error.message });

    res.status(201).json({ success: true, data: service });

  } catch (err) {
    console.error('createService error:', err);
    res.status(500).json({ success: false, error: 'Failed to create service' });
  }
};

// updateService
// ownership enforced via .eq('provider_id', providerProfile.id) in query.
// only whitelisted fields accepted — no req.body spread.
export const updateService = async (req, res) => {
  try {
    // Resolve caller's provider profile (sends error and returns null if not found)
    const providerProfile = await getCallerProviderProfile(req.user.id, res);
    if (!providerProfile) return;

    //whitelist — never spread req.body directly into a DB update
    const {
      name,
      description,
      base_price,
      duration_minutes,
      sub_category,
      is_active,
      category_id,
    } = req.body;

    // Build update object with only defined fields (avoid overwriting with undefined)
    const updatePayload = {
      updated_at: new Date().toISOString(),
    };
    if (name            !== undefined) updatePayload.name             = name;
    if (description     !== undefined) updatePayload.description      = description;
    if (base_price      !== undefined) updatePayload.base_price       = base_price;
    if (duration_minutes !== undefined) updatePayload.duration_minutes = duration_minutes;
    if (sub_category    !== undefined) updatePayload.sub_category     = sub_category;
    if (is_active       !== undefined) updatePayload.is_active        = is_active;
    if (category_id     !== undefined) updatePayload.category_id      = category_id;

    // ownership enforced — .eq('provider_id', …) means only the owning
    // provider's service can match; a different provider's service returns
    // 0 rows, which we handle as either 403 (exists but not theirs) or 404.
    const { data: service, error } = await supabase
      .from('services')
      .update(updatePayload)
      .eq('id', req.params.id)
      .eq('provider_id', providerProfile.id)   // ← ownership guard
      .select()
      .single();

    if (error || !service) {
      // Distinguish 403 from 404: check whether the service exists at all
      const { data: exists } = await supabase
        .from('services')
        .select('id')
        .eq('id', req.params.id)
        .maybeSingle();

      if (exists) {
        return res.status(403).json({
          success: false,
          error: 'Forbidden: you do not own this service',
        });
      }
      return res.status(404).json({ success: false, error: 'Service not found' });
    }

    res.json({ success: true, data: service });

  } catch (err) {
    console.error('updateService error:', err);
    res.status(500).json({ success: false, error: 'Failed to update service' });
  }
};

// deleteService
// ownership enforced via .eq('provider_id', providerProfile.id).
export const deleteService = async (req, res) => {
  try {
    const providerProfile = await getCallerProviderProfile(req.user.id, res);
    if (!providerProfile) return;

    // A-02: .eq('provider_id', …) ensures only the owning provider's service is deleted.
    // .select('id') makes PostgREST return the deleted rows so we can check the count.
    const { data, error } = await supabase
      .from('services')
      .delete()
      .eq('id', req.params.id)
      .eq('provider_id', providerProfile.id)   // ← ownership guard
      .select('id');

    if (error) {
      return res.status(400).json({ success: false, error: error.message });
    }

    if (!data?.length) {
      // No rows deleted — distinguish 403 from 404
      const { data: exists } = await supabase
        .from('services')
        .select('id')
        .eq('id', req.params.id)
        .maybeSingle();

      if (exists) {
        return res.status(403).json({
          success: false,
          error: 'Forbidden: you do not own this service',
        });
      }
      return res.status(404).json({ success: false, error: 'Service not found' });
    }

    res.json({ success: true, message: 'Service deleted' });

  } catch (err) {
    console.error('deleteService error:', err);
    res.status(500).json({ success: false, error: 'Failed to delete service' });
  }
};

export default { listServices, getService, createService, updateService, deleteService };