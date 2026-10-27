// Parse ?page=&limit= safely. Bad or missing values fall back to defaults, and
// limit is capped so a client can't ask for 100,000 rows in one request.
export function parsePagination(params, { defaultLimit = 20, maxLimit = 100 } = {}) {
  const page  = Math.max(1, Number.parseInt(params.page, 10) || 1);
  const limit = Math.min(maxLimit, Math.max(1, Number.parseInt(params.limit, 10) || defaultLimit));
  return { page, limit, offset: (page - 1) * limit };
}

// Escape % and _ so user search text is matched literally inside ILIKE '%…%'.
export const escapeLike = (text) => text.replace(/[\\%_]/g, '\\$&');
