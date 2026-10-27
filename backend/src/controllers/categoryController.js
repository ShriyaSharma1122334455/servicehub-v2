import { query } from '../config/database.js';

const CATEGORY_COLUMNS = 'id, slug, name, icon, description';

// Get all categories
export const getAllCategories = async (_req, res) => {
  try {
    const { rows } = await query(`SELECT ${CATEGORY_COLUMNS} FROM categories ORDER BY name`);
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('Error fetching categories:', err);
    res.status(500).json({ success: false, error: 'Failed to fetch categories' });
  }
};

// Get category by ID (IDs are small hand-assigned integers: 1 = plumbing, ...)
export const getCategoryById = async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id < 1 || id > 32767) {
      return res.status(404).json({ success: false, error: 'Category not found' });
    }

    const { rows } = await query(`SELECT ${CATEGORY_COLUMNS} FROM categories WHERE id = $1`, [id]);
    if (rows.length === 0) {
      return res.status(404).json({ success: false, error: 'Category not found' });
    }

    res.json({ success: true, data: rows[0] });
  } catch (err) {
    console.error('Error fetching category:', err);
    res.status(500).json({ success: false, error: 'Failed to fetch category' });
  }
};

// Get category by slug
export const getCategoryBySlug = async (req, res) => {
  try {
    const { rows } = await query(
      `SELECT ${CATEGORY_COLUMNS} FROM categories WHERE slug = $1`,
      [req.params.slug],
    );
    if (rows.length === 0) {
      return res.status(404).json({ success: false, error: 'Category not found' });
    }

    res.json({ success: true, data: rows[0] });
  } catch (err) {
    console.error('Error fetching category:', err);
    res.status(500).json({ success: false, error: 'Failed to fetch category' });
  }
};

export default { getAllCategories, getCategoryById, getCategoryBySlug };
