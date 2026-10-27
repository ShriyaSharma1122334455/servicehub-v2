import supabase from '../config/supabase.js';
import { query } from '../config/database.js';
import { parsePagination } from '../utils/pagination.js';

export const getProvider = async (req, res) => {
  try {
    const { id } = req.params;

    const { data: provider, error } = await supabase
      .from('providers')
      .select(`
        id, business_name, description, rating_avg, rating_count,
        user:users(full_name, email, avatar_url, role),
        provider_categories(category_id)
      `)
      .eq('id', id)
      .single();

    if (error || !provider) {
      return res.status(404).json({ success: false, error: 'Provider not found' });
    }

    return res.json({
      success: true,
      data: {
        id:                    provider.id,
        business_name:         provider.business_name,
        description:           provider.description,
        rating_avg:            provider.rating_avg,
        rating_count:          provider.rating_count,
        is_fully_verified:     provider.is_fully_verified ?? false,
        service_categories:    provider.provider_categories,
        full_name:             provider.user?.full_name || provider.business_name,
        email:                 provider.user?.email,
        avatar_url:            provider.user?.avatar_url,
        role:                  provider.user?.role || 'provider',
      }
    });

  } catch (err) {
    console.error('Error fetching provider:', err);
    res.status(500).json({ success: false, error: 'Failed to fetch provider' });
  }
};

export const listProviders = async (req, res) => {
  try {
    const { data: providers, error } = await supabase
      .from('providers')
      .select(`
        id, business_name, description, rating_avg, rating_count, is_fully_verified,
        user:users(full_name, email, avatar_url)
      `)
      .eq('is_active', true);

    if (error) return res.status(400).json({ success: false, error: error.message });

    const list = providers.map(p => ({
      id:                  p.id,
      business_name:       p.business_name,
      description:         p.description,
      rating_avg:          p.rating_avg,
      rating_count:        p.rating_count,
      is_fully_verified:   p.is_fully_verified ?? false,
      full_name:           p.user?.full_name || p.business_name,
      email:               p.user?.email,
      avatar_url:          p.user?.avatar_url,
    }));

    return res.json({
      success: true,
      data: { providers: list },
      pagination: { total: list.length, page: 1, limit: list.length }
    });

  } catch (err) {
    console.error('Error fetching providers:', err);
    res.status(500).json({ success: false, error: 'Failed to fetch providers' });
  }
};

// GET /api/providers/by-service/:serviceId?page=&limit=
// Active providers offering a catalog service, cheapest first. The ORDER BY
// matches the provider_services (service_id, price_cents) index, so Postgres
// reads offers already sorted instead of sorting them.
export const getProvidersByService = async (req, res) => {
  try {
    const serviceId = Number(req.params.serviceId);
    if (!Number.isInteger(serviceId) || serviceId < 1 || serviceId > 32767) {
      return res.status(400).json({ success: false, error: 'serviceId must be a catalog service ID' });
    }
    const { page, limit, offset } = parsePagination(req.query);

    const { rows } = await query(
      `SELECT p.user_id AS id,
              p.business_name,
              p.rating_count,
              CASE WHEN p.rating_count > 0
                   THEN round(p.rating_sum::numeric / p.rating_count, 2)::float8
              END                                     AS rating_avg,
              (u.verification_status = 'verified')    AS is_fully_verified,
              u.full_name,
              u.avatar_url,
              ps.id                                   AS offer_id,
              ps.price_cents,
              ps.price_cents / 100.0::float8          AS custom_price,
              ps.duration_minutes,
              ps.description                          AS custom_description
         FROM provider_services ps
         JOIN providers p ON p.user_id = ps.provider_id AND p.is_active
         JOIN users u     ON u.id = p.user_id AND u.deleted_at IS NULL
        WHERE ps.service_id = $1 AND ps.is_active
        ORDER BY ps.price_cents, p.rating_count DESC, p.user_id
        LIMIT $2 OFFSET $3`,
      [serviceId, limit, offset],
    );

    return res.json({ success: true, count: rows.length, page, limit, data: rows });

  } catch (err) {
    console.error('getProvidersByService error:', err);
    res.status(500).json({ success: false, error: 'Failed to fetch providers for service' });
  }
};

export const searchProviders = async (req, res) => {
  try {
    const { category, minRating, isActive, search, page = 1, limit = 20 } = req.query;

    // PostgREST does not apply .eq on embedded relation paths (e.g. provider_categories.*)
    // to the junction join — filter is ignored and all providers are returned. Resolve
    // provider ids from provider_categories first, then filter the root table with .in('id', …).
    let categoryProviderIds = null;
    if (category) {
      const { data: junctionRows, error: junctionError } = await supabase
        .from('provider_categories')
        .select('provider_id')
        .eq('category_id', category);

      if (junctionError) {
        return res.status(400).json({ success: false, error: junctionError.message });
      }

      categoryProviderIds = [...new Set((junctionRows || []).map((r) => r.provider_id))];
      if (categoryProviderIds.length === 0) {
        return res.json({
          success: true,
          count: 0,
          total: 0,
          page: Number(page),
          data: { providers: [] },
        });
      }
    }

    let query = supabase
      .from('providers')
      .select(`
        id, business_name, description, rating_avg, rating_count, is_active, is_fully_verified,
        user:users(full_name, email, avatar_url),
        provider_categories(category_id)
      `, { count: 'exact' });

    if (categoryProviderIds) query = query.in('id', categoryProviderIds);

    // Filters
    if (minRating)              query = query.gte('rating_avg', Number(minRating));
    if (isActive !== undefined) query = query.eq('is_active', isActive === 'true');
    if (search)                 query = query.ilike('business_name', `%${search}%`);

    // Pagination
    const from = (Number(page) - 1) * Number(limit);
    const to   = from + Number(limit) - 1;
    query = query.range(from, to);

    const { data: providers, error, count } = await query;

    if (error) return res.status(400).json({ success: false, error: error.message });

    const list = providers.map(p => ({
      id:                    p.id,
      business_name:         p.business_name,
      description:           p.description,
      rating_avg:            p.rating_avg,
      rating_count:          p.rating_count,
      is_active:             p.is_active,
      is_fully_verified:     p.is_fully_verified ?? false,
      service_categories:    p.provider_categories,
      full_name:             p.user?.full_name,
      email:                 p.user?.email,
      avatar_url:            p.user?.avatar_url,
    }));

    return res.json({
      success: true,
      count: list.length,
      total: count,
      page: Number(page),
      data: { providers: list }
    });

  } catch (err) {
    console.error('searchProviders error:', err);
    res.status(500).json({ success: false, error: 'Failed to search providers' });
  }
};

export default { getProvider, listProviders, getProvidersByService, searchProviders };