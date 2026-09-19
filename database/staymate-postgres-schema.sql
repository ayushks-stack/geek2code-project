-- StayMate production data model (PostgreSQL 15+)
-- Run with: psql "$DATABASE_URL" -f staymate-schema.sql
-- This schema stores only document references, never government-ID numbers or files.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE user_role AS ENUM ('student', 'landlord', 'admin', 'municipal_officer');
CREATE TYPE verification_status AS ENUM ('pending', 'verified', 'rejected', 'expired');
CREATE TYPE listing_status AS ENUM ('draft', 'pending_review', 'active', 'paused', 'removed');
CREATE TYPE risk_level AS ENUM ('low', 'medium', 'high');
CREATE TYPE booking_status AS ENUM ('requested', 'accepted', 'declined', 'cancelled', 'checked_in', 'checked_out');
CREATE TYPE report_status AS ENUM ('open', 'acknowledged', 'in_progress', 'resolved', 'closed');
CREATE TYPE roommate_mode AS ENUM ('random_verified', 'specific_match');

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role user_role NOT NULL,
  full_name TEXT NOT NULL,
  phone_e164 TEXT NOT NULL UNIQUE,
  email TEXT UNIQUE,
  password_hash TEXT, -- nullable when using OTP-only authentication
  is_phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE student_profiles (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  college_name TEXT NOT NULL,
  monthly_budget_min INTEGER CHECK (monthly_budget_min >= 0),
  monthly_budget_max INTEGER CHECK (monthly_budget_max >= monthly_budget_min)
);

CREATE TABLE landlord_profiles (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  business_name TEXT,
  is_good_faith_cleared BOOLEAN NOT NULL DEFAULT FALSE,
  cleared_at TIMESTAMPTZ
);

-- Keep provider reference tokens / encrypted file paths only; do not persist Aadhaar numbers.
CREATE TABLE identity_verifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  provider_reference TEXT NOT NULL UNIQUE,
  document_type TEXT NOT NULL,
  document_storage_key TEXT, -- S3-style private object key
  status verification_status NOT NULL DEFAULT 'pending',
  verified_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_identity_verifications_user ON identity_verifications(user_id, status);

CREATE TABLE listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  landlord_id UUID NOT NULL REFERENCES users(id),
  property_name TEXT NOT NULL,
  address_line1 TEXT NOT NULL,
  locality TEXT NOT NULL,
  city TEXT NOT NULL,
  state TEXT NOT NULL,
  postal_code TEXT NOT NULL,
  latitude NUMERIC(9,6),
  longitude NUMERIC(9,6),
  monthly_price INTEGER NOT NULL CHECK (monthly_price > 0),
  sharing_capacity SMALLINT NOT NULL CHECK (sharing_capacity BETWEEN 1 AND 8),
  gender_policy TEXT NOT NULL DEFAULT 'all',
  description TEXT,
  status listing_status NOT NULL DEFAULT 'draft',
  risk risk_level NOT NULL DEFAULT 'medium',
  trust_score NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (trust_score BETWEEN 0 AND 100),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_listings_discovery ON listings(city, locality, monthly_price) WHERE status = 'active';
CREATE INDEX idx_listings_landlord ON listings(landlord_id);

CREATE TABLE listing_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id UUID NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  document_type TEXT NOT NULL CHECK (document_type IN ('ownership_proof', 'pg_registration', 'fire_safety', 'other')),
  storage_key TEXT NOT NULL,
  provider_reference TEXT,
  status verification_status NOT NULL DEFAULT 'pending',
  verified_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE amenities (
  id SMALLSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
);
CREATE TABLE listing_amenities (
  listing_id UUID NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  amenity_id SMALLINT NOT NULL REFERENCES amenities(id),
  PRIMARY KEY (listing_id, amenity_id)
);

CREATE TABLE listing_photos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id UUID NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  storage_key TEXT NOT NULL,
  alt_text TEXT,
  display_order SMALLINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Scores stay explainable rather than opaque. Latest row is the visible assessment.
CREATE TABLE trust_assessments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id UUID NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  identity_ownership_score NUMERIC(5,2) NOT NULL CHECK (identity_ownership_score BETWEEN 0 AND 100),
  registration_score NUMERIC(5,2) NOT NULL CHECK (registration_score BETWEEN 0 AND 100),
  review_authenticity_score NUMERIC(5,2) NOT NULL CHECK (review_authenticity_score BETWEEN 0 AND 100),
  safety_signals_score NUMERIC(5,2) NOT NULL CHECK (safety_signals_score BETWEEN 0 AND 100),
  total_score NUMERIC(5,2) NOT NULL CHECK (total_score BETWEEN 0 AND 100),
  risk risk_level NOT NULL,
  explanation JSONB NOT NULL DEFAULT '{}'::jsonb,
  assessed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  assessed_by UUID REFERENCES users(id)
);
CREATE INDEX idx_trust_assessments_latest ON trust_assessments(listing_id, assessed_at DESC);

CREATE TABLE bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id UUID NOT NULL REFERENCES listings(id),
  student_id UUID NOT NULL REFERENCES users(id),
  landlord_id UUID NOT NULL REFERENCES users(id),
  status booking_status NOT NULL DEFAULT 'requested',
  move_in_date DATE NOT NULL,
  move_out_date DATE,
  roommate_preference roommate_mode NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (move_out_date IS NULL OR move_out_date > move_in_date)
);
CREATE INDEX idx_bookings_student ON bookings(student_id, status);
CREATE INDEX idx_bookings_listing ON bookings(listing_id, status);

-- A review becomes publishable only after an actual checked-out stay.
CREATE TABLE reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL UNIQUE REFERENCES bookings(id),
  listing_id UUID NOT NULL REFERENCES listings(id),
  author_id UUID NOT NULL REFERENCES users(id),
  stars SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
  body TEXT NOT NULL CHECK (char_length(body) BETWEEN 20 AND 2000),
  authenticity_weight NUMERIC(6,4) NOT NULL DEFAULT 1.0000 CHECK (authenticity_weight BETWEEN 0 AND 1),
  status verification_status NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at TIMESTAMPTZ
);
CREATE INDEX idx_reviews_listing ON reviews(listing_id, status, created_at DESC);

-- Materialized running score: weighted, server-maintained, and inexpensive to render.
CREATE TABLE listing_review_scores (
  listing_id UUID PRIMARY KEY REFERENCES listings(id) ON DELETE CASCADE,
  weighted_rating NUMERIC(3,2) NOT NULL DEFAULT 0 CHECK (weighted_rating BETWEEN 0 AND 5),
  review_count INTEGER NOT NULL DEFAULT 0,
  total_weight NUMERIC(12,4) NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION recompute_review_score() RETURNS TRIGGER AS $$
DECLARE target_listing UUID;
BEGIN
  target_listing := COALESCE(NEW.listing_id, OLD.listing_id);
  INSERT INTO listing_review_scores (listing_id, weighted_rating, review_count, total_weight, updated_at)
  SELECT target_listing,
         COALESCE(SUM(stars * authenticity_weight) / NULLIF(SUM(authenticity_weight),0),0),
         COUNT(*) FILTER (WHERE status = 'verified'),
         COALESCE(SUM(authenticity_weight) FILTER (WHERE status = 'verified'),0), now()
  FROM reviews WHERE listing_id = target_listing AND status = 'verified'
  ON CONFLICT (listing_id) DO UPDATE SET weighted_rating=EXCLUDED.weighted_rating,
    review_count=EXCLUDED.review_count,total_weight=EXCLUDED.total_weight,updated_at=EXCLUDED.updated_at;
  RETURN COALESCE(NEW, OLD);
END; $$ LANGUAGE plpgsql;
CREATE TRIGGER reviews_recompute_score AFTER INSERT OR UPDATE OR DELETE ON reviews
  FOR EACH ROW EXECUTE FUNCTION recompute_review_score();

CREATE TABLE listing_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id UUID NOT NULL REFERENCES listings(id),
  reporter_id UUID NOT NULL REFERENCES users(id),
  category TEXT NOT NULL CHECK (category IN ('structural_crack','waterlogging','electrical_fault','fire_safety','cleanliness','maintenance','scam','other')),
  description TEXT NOT NULL,
  status report_status NOT NULL DEFAULT 'open',
  send_to_municipality BOOLEAN NOT NULL DEFAULT FALSE,
  municipal_reference TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ
);
CREATE INDEX idx_reports_municipal_queue ON listing_reports(status, created_at) WHERE send_to_municipality = TRUE;

CREATE TABLE conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID UNIQUE REFERENCES bookings(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES users(id),
  landlord_id UUID NOT NULL REFERENCES users(id),
  unlocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES users(id),
  body TEXT NOT NULL CHECK (char_length(body) <= 4000),
  sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  read_at TIMESTAMPTZ
);
CREATE INDEX idx_messages_conversation ON messages(conversation_id, sent_at);

CREATE TABLE roommate_preferences (
  student_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  sleep_schedule TEXT, food_preference TEXT, cleanliness TEXT, smoking_preference TEXT, study_habits TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE roommate_matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  matched_student_id UUID NOT NULL REFERENCES users(id),
  compatibility_percentage SMALLINT NOT NULL CHECK (compatibility_percentage BETWEEN 0 AND 100),
  accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (booking_id, matched_student_id)
);

-- Permission model: expose filtered views or enable RLS before connecting the app role.
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
-- Example: application service role can bypass RLS; public/client roles get dedicated policies.
