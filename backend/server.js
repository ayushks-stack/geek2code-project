import 'dotenv/config';
import express from 'express';
import mysql from 'mysql2/promise';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';

const dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
const port = Number(process.env.PORT || 3000);

const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 3306),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  waitForConnections: true,
  connectionLimit: 10,
  namedPlaceholders: true
});

await pool.query(`CREATE TABLE IF NOT EXISTS auth_sessions (
  token_hash CHAR(64) PRIMARY KEY,
  user_id BIGINT UNSIGNED NOT NULL,
  expires_at DATETIME NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_auth_sessions_expiry (expires_at),
  CONSTRAINT fk_auth_session_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB`);

app.use(express.json({ limit: '100kb' }));
app.use(express.static(path.resolve(dirname, '..')));

function passwordHash(password, salt = crypto.randomBytes(16).toString('hex')) {
  const derived = crypto.scryptSync(password, salt, 64).toString('hex');
  return `${salt}:${derived}`;
}
function passwordMatches(password, saved) {
  const [salt, expected] = String(saved || '').split(':');
  if (!salt || !expected) return false;
  const actual = crypto.scryptSync(password, salt, 64).toString('hex');
  return crypto.timingSafeEqual(Buffer.from(actual, 'hex'), Buffer.from(expected, 'hex'));
}
function tokenHash(token) { return crypto.createHash('sha256').update(token).digest('hex'); }
async function issueSession(user) {
  const token = crypto.randomBytes(32).toString('base64url');
  await pool.query('INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?, ?, DATE_ADD(NOW(), INTERVAL 7 DAY))', [tokenHash(token), user.id]);
  return token;
}
async function currentUser(req) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token) return null;
  const [rows] = await pool.query(`SELECT u.id, u.role, u.full_name AS fullName
    FROM auth_sessions s JOIN users u ON u.id = s.user_id
    WHERE s.token_hash = ? AND s.expires_at > NOW() LIMIT 1`, [tokenHash(token)]);
  return rows[0] || null;
}
function requireRole(role) {
  return async (req, res, next) => {
    const user = await currentUser(req);
    if (!user) return res.status(401).json({ error: 'Please sign in first.' });
    if (role && user.role !== role) return res.status(403).json({ error: 'This action requires a landlord account.' });
    req.user = user; next();
  };
}

app.post('/api/auth/register', async (req, res, next) => {
  try {
    const { fullName, phone, password, role, collegeName, budget, businessName } = req.body;
    if (!['student', 'landlord'].includes(role) || !fullName?.trim() || !/^\+?[1-9]\d{7,14}$/.test(phone?.trim() || '') || !password || password.length < 8) {
      return res.status(400).json({ error: 'Name, phone, role, and a password of at least 8 characters are required.' });
    }
    const [result] = await pool.query('INSERT INTO users (role, full_name, phone_e164, password_hash, is_phone_verified) VALUES (?, ?, ?, ?, TRUE)',
      [role, fullName.trim(), phone.trim(), passwordHash(password)]);
    if (role === 'student') await pool.query('INSERT INTO student_profiles (user_id, college_name, monthly_budget_max) VALUES (?, ?, ?)', [result.insertId, collegeName?.trim() || 'Not provided', Number(budget) || null]);
    else await pool.query('INSERT INTO landlord_profiles (user_id, business_name, is_good_faith_cleared) VALUES (?, ?, FALSE)', [result.insertId, businessName?.trim() || null]);
    const user = { id: result.insertId, role, fullName: fullName.trim() }; const token = await issueSession(user);
    res.status(201).json({ token, user });
  } catch (error) { if (error.code === 'ER_DUP_ENTRY') return res.status(409).json({ error: 'This phone number is already registered.' }); next(error); }
});

app.post('/api/auth/login', async (req, res, next) => {
  try {
    const { phone, password } = req.body;
    const [rows] = await pool.query('SELECT id, role, full_name, password_hash FROM users WHERE phone_e164 = ? LIMIT 1', [phone?.trim()]);
    if (!rows[0] || !passwordMatches(password, rows[0].password_hash)) return res.status(401).json({ error: 'Incorrect phone number or password.' });
    const user = { id: rows[0].id, role: rows[0].role, fullName: rows[0].full_name }; const token = await issueSession(user);
    res.json({ token, user });
  } catch (error) { next(error); }
});

app.get('/api/auth/me', requireRole(), (req, res) => res.json(req.user));
app.post('/api/auth/logout', requireRole(), async (req, res, next) => {
  try { await pool.query('DELETE FROM auth_sessions WHERE token_hash = ?', [tokenHash(req.headers.authorization.replace('Bearer ', ''))]); res.status(204).end(); }
  catch (error) { next(error); }
});

app.get('/api/health', async (_req, res) => {
  try { await pool.query('SELECT 1'); res.json({ ok: true, database: 'connected' }); }
  catch { res.status(503).json({ ok: false, database: 'unavailable' }); }
});

// Public discovery exposes only active listings. Private documents and exact landlord data never leave the API.
app.get('/api/listings', async (req, res, next) => {
  try {
    const location = String(req.query.location || '').trim();
    const q = `%${location}%`;
    const [rows] = await pool.query(`
      SELECT l.id, l.property_name AS name, l.locality, l.city, l.monthly_price AS price,
             l.risk, l.trust_score AS score, l.sharing_capacity,
             COALESCE(s.weighted_rating, 0) AS rating, COALESCE(s.review_count, 0) AS reviews,
             (SELECT storage_key FROM listing_photos p WHERE p.listing_id = l.id ORDER BY p.display_order, p.id LIMIT 1) AS image
      FROM listings l
      LEFT JOIN listing_review_scores s ON s.listing_id = l.id
      WHERE l.status = 'active' AND (? = '' OR l.city LIKE ? OR l.locality LIKE ?)
      ORDER BY l.trust_score DESC, l.created_at DESC`, [location, q, q]);
    res.json(rows.map(row => ({ ...row, place: `${row.locality}, ${row.city}`, amen: `${row.sharing_capacity} sharing` })));
  } catch (error) { next(error); }
});

app.get('/api/listings/:id/reviews', async (req, res, next) => {
  try {
    const [rows] = await pool.query(`SELECT r.stars, r.body, r.created_at, u.full_name
      FROM reviews r JOIN users u ON u.id = r.author_id
      WHERE r.listing_id = ? AND r.status = 'verified'
      ORDER BY r.created_at DESC LIMIT 20`, [req.params.id]);
    res.json(rows.map(row => ({ stars: row.stars, body: row.body, createdAt: row.created_at, author: row.full_name.split(' ')[0] })));
  } catch (error) { next(error); }
});

// Only a completed stay may produce a review; the database trigger recalculates the weighted summary.
app.post('/api/listings/:id/reviews', requireRole('student'), async (req, res, next) => {
  try {
    const stars = Number(req.body.stars); const body = String(req.body.body || '').trim();
    if (!Number.isInteger(stars) || stars < 1 || stars > 5 || body.length < 20 || body.length > 2000) {
      return res.status(400).json({ error: 'Choose 1–5 stars and write at least 20 characters.' });
    }
    const [bookings] = await pool.query(`SELECT id FROM bookings WHERE listing_id = ? AND student_id = ? AND status = 'checked_out' LIMIT 1`, [req.params.id, req.user.id]);
    if (!bookings[0]) return res.status(403).json({ error: 'Ratings unlock after you complete a verified stay at this PG.' });
    await pool.query(`INSERT INTO reviews (booking_id, listing_id, author_id, stars, body, authenticity_weight, status, published_at)
      VALUES (?, ?, ?, ?, ?, 1.0000, 'verified', NOW())`, [bookings[0].id, req.params.id, req.user.id, stars, body]);
    res.status(201).json({ ok: true, message: 'Your verified review is published.' });
  } catch (error) { if (error.code === 'ER_DUP_ENTRY') return res.status(409).json({ error: 'You have already reviewed this completed stay.' }); next(error); }
});

app.post('/api/listings', requireRole('landlord'), async (req, res, next) => {
  try {
    const { propertyName, address, locality, city, state, postalCode, monthlyPrice, sharingCapacity, genderPolicy, description } = req.body;
    if (![propertyName, address, locality, city, state, postalCode].every(value => String(value || '').trim()) || !Number(monthlyPrice) || !Number(sharingCapacity)) {
      return res.status(400).json({ error: 'Complete all required property details.' });
    }
    const [result] = await pool.query(`INSERT INTO listings
      (landlord_id, property_name, address_line1, locality, city, state, postal_code, monthly_price, sharing_capacity, gender_policy, description, status, risk, trust_score)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending_review', 'medium', 0)`,
      [req.user.id, propertyName.trim(), address.trim(), locality.trim(), city.trim(), state.trim(), postalCode.trim(), Number(monthlyPrice), Number(sharingCapacity), genderPolicy || 'all', description?.trim() || null]);
    res.status(201).json({ id: result.insertId, status: 'pending_review', message: 'Your PG was submitted for document and safety review.' });
  } catch (error) { next(error); }
});

app.get('/api/my/listings', requireRole('landlord'), async (req, res, next) => {
  try {
    const [rows] = await pool.query(`SELECT id, property_name AS name, locality, city, monthly_price AS price,
      status, risk, trust_score AS score, created_at
      FROM listings WHERE landlord_id = ? ORDER BY created_at DESC`, [req.user.id]);
    res.json(rows);
  } catch (error) { next(error); }
});

// Presentation-only reviewer simulator. Replace this with an admin-only approval workflow in production.
app.post('/api/demo/listings/:id/verify', requireRole('landlord'), async (req, res, next) => {
  try {
    const [result] = await pool.query(`UPDATE listings SET status = 'active', risk = 'low', trust_score = 92
      WHERE id = ? AND landlord_id = ? AND status = 'pending_review'`, [req.params.id, req.user.id]);
    if (!result.affectedRows) return res.status(404).json({ error: 'Pending listing not found.' });
    await pool.query(`INSERT INTO trust_assessments
      (listing_id, identity_ownership_score, registration_score, review_authenticity_score, safety_signals_score, total_score, risk, explanation, assessed_by)
      VALUES (?, 96, 94, 85, 92, 92, 'low', JSON_OBJECT('mode','presentation_demo','note','Simulated reviewer approval'), ?)`, [req.params.id, req.user.id]);
    res.json({ ok: true, status: 'active', score: 92 });
  } catch (error) { next(error); }
});

app.get('/api/roommates', async (_req, res, next) => {
  try {
    const [rows] = await pool.query(`
      SELECT u.id, u.full_name AS name, sp.college_name AS course,
             rp.sleep_schedule, rp.food_preference, rp.cleanliness, rp.smoking_preference, rp.study_habits
      FROM users u
      JOIN student_profiles sp ON sp.user_id = u.id
      LEFT JOIN roommate_preferences rp ON rp.student_id = u.id
      JOIN identity_verifications iv ON iv.user_id = u.id AND iv.status = 'verified'
      WHERE u.role = 'student' GROUP BY u.id ORDER BY u.created_at DESC LIMIT 30`);
    res.json(rows);
  } catch (error) { next(error); }
});

// Replace demo user ids with the authenticated session identity before production.
app.post('/api/roommate-connections', async (req, res, next) => {
  try {
    const { bookingId, matchedStudentId, compatibilityPercentage } = req.body;
    if (!Number.isInteger(bookingId) || !Number.isInteger(matchedStudentId) || !Number.isInteger(compatibilityPercentage)) {
      return res.status(400).json({ error: 'bookingId, matchedStudentId, and compatibilityPercentage are required integers.' });
    }
    await pool.query(`INSERT INTO roommate_matches (booking_id, matched_student_id, compatibility_percentage)
      VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE compatibility_percentage = VALUES(compatibility_percentage)`,
      [bookingId, matchedStudentId, compatibilityPercentage]);
    res.status(201).json({ ok: true });
  } catch (error) { next(error); }
});

app.get('/{*splat}', (_req, res) => res.sendFile(path.resolve(dirname, '..', 'index.html')));
app.use((error, _req, res, _next) => { console.error(error); res.status(500).json({ error: 'Database request failed.' }); });

app.listen(port, () => console.log(`StayMate API on http://localhost:${port}`));
