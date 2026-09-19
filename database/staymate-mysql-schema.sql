-- StayMate production data model (MySQL 8.0+ / InnoDB / utf8mb4)
-- Run with: mysql -u USER -p DATABASE < staymate-mysql-schema.sql
-- Store government-ID references and private file keys only — never Aadhaar numbers or files in this database.

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
CREATE DATABASE IF NOT EXISTS staymate CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE staymate;

CREATE TABLE users (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  role ENUM('student','landlord','admin','municipal_officer') NOT NULL,
  full_name VARCHAR(150) NOT NULL,
  phone_e164 VARCHAR(20) NOT NULL,
  email VARCHAR(254),
  password_hash VARCHAR(255), -- nullable for OTP-only sign-in
  is_phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id), UNIQUE KEY uq_users_phone (phone_e164), UNIQUE KEY uq_users_email (email)
) ENGINE=InnoDB;

CREATE TABLE student_profiles (
  user_id BIGINT UNSIGNED NOT NULL,
  college_name VARCHAR(255) NOT NULL,
  monthly_budget_min INT UNSIGNED,
  monthly_budget_max INT UNSIGNED,
  PRIMARY KEY (user_id),
  CONSTRAINT chk_student_budget CHECK (monthly_budget_max IS NULL OR monthly_budget_min IS NULL OR monthly_budget_max >= monthly_budget_min),
  CONSTRAINT fk_student_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE landlord_profiles (
  user_id BIGINT UNSIGNED NOT NULL,
  business_name VARCHAR(255),
  is_good_faith_cleared BOOLEAN NOT NULL DEFAULT FALSE,
  cleared_at DATETIME,
  PRIMARY KEY (user_id),
  CONSTRAINT fk_landlord_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE identity_verifications (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  provider VARCHAR(80) NOT NULL,
  provider_reference VARCHAR(255) NOT NULL,
  document_type VARCHAR(80) NOT NULL,
  document_storage_key VARCHAR(1024),
  status ENUM('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  verified_at DATETIME, expires_at DATETIME,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id), UNIQUE KEY uq_verification_provider_ref (provider_reference),
  KEY idx_verification_user_status (user_id,status),
  CONSTRAINT fk_verification_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE listings (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  landlord_id BIGINT UNSIGNED NOT NULL,
  property_name VARCHAR(255) NOT NULL,
  address_line1 VARCHAR(255) NOT NULL,
  locality VARCHAR(150) NOT NULL, city VARCHAR(150) NOT NULL, state VARCHAR(150) NOT NULL, postal_code VARCHAR(20) NOT NULL,
  latitude DECIMAL(9,6), longitude DECIMAL(9,6),
  monthly_price INT UNSIGNED NOT NULL,
  sharing_capacity TINYINT UNSIGNED NOT NULL,
  gender_policy ENUM('all','women','men') NOT NULL DEFAULT 'all',
  description TEXT,
  status ENUM('draft','pending_review','active','paused','removed') NOT NULL DEFAULT 'draft',
  risk ENUM('low','medium','high') NOT NULL DEFAULT 'medium',
  trust_score DECIMAL(5,2) NOT NULL DEFAULT 0.00,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id), KEY idx_listing_discovery (status,city,locality,monthly_price), KEY idx_listing_landlord (landlord_id),
  CONSTRAINT chk_listing_price CHECK (monthly_price > 0),
  CONSTRAINT chk_listing_capacity CHECK (sharing_capacity BETWEEN 1 AND 8),
  CONSTRAINT chk_listing_score CHECK (trust_score BETWEEN 0 AND 100),
  CONSTRAINT fk_listing_landlord FOREIGN KEY (landlord_id) REFERENCES users(id)
) ENGINE=InnoDB;

CREATE TABLE listing_documents (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  listing_id BIGINT UNSIGNED NOT NULL,
  document_type ENUM('ownership_proof','pg_registration','fire_safety','other') NOT NULL,
  storage_key VARCHAR(1024) NOT NULL, provider_reference VARCHAR(255),
  status ENUM('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  verified_at DATETIME, expires_at DATETIME, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id), KEY idx_listing_document (listing_id,status),
  CONSTRAINT fk_document_listing FOREIGN KEY (listing_id) REFERENCES listings(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE amenities (id SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT, name VARCHAR(100) NOT NULL, PRIMARY KEY(id), UNIQUE KEY uq_amenity_name(name)) ENGINE=InnoDB;
CREATE TABLE listing_amenities (
  listing_id BIGINT UNSIGNED NOT NULL, amenity_id SMALLINT UNSIGNED NOT NULL,
  PRIMARY KEY(listing_id,amenity_id),
  CONSTRAINT fk_la_listing FOREIGN KEY(listing_id) REFERENCES listings(id) ON DELETE CASCADE,
  CONSTRAINT fk_la_amenity FOREIGN KEY(amenity_id) REFERENCES amenities(id)
) ENGINE=InnoDB;
CREATE TABLE listing_photos (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, listing_id BIGINT UNSIGNED NOT NULL,
  storage_key VARCHAR(1024) NOT NULL, alt_text VARCHAR(255), display_order SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id), KEY idx_photo_listing(listing_id,display_order),
  CONSTRAINT fk_photo_listing FOREIGN KEY(listing_id) REFERENCES listings(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE trust_assessments (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, listing_id BIGINT UNSIGNED NOT NULL,
  identity_ownership_score DECIMAL(5,2) NOT NULL, registration_score DECIMAL(5,2) NOT NULL,
  review_authenticity_score DECIMAL(5,2) NOT NULL, safety_signals_score DECIMAL(5,2) NOT NULL,
  total_score DECIMAL(5,2) NOT NULL, risk ENUM('low','medium','high') NOT NULL,
  explanation JSON NOT NULL, assessed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, assessed_by BIGINT UNSIGNED,
  PRIMARY KEY(id), KEY idx_assessment_latest(listing_id,assessed_at DESC),
  CONSTRAINT chk_assessment_scores CHECK (identity_ownership_score BETWEEN 0 AND 100 AND registration_score BETWEEN 0 AND 100 AND review_authenticity_score BETWEEN 0 AND 100 AND safety_signals_score BETWEEN 0 AND 100 AND total_score BETWEEN 0 AND 100),
  CONSTRAINT fk_assessment_listing FOREIGN KEY(listing_id) REFERENCES listings(id) ON DELETE CASCADE,
  CONSTRAINT fk_assessment_user FOREIGN KEY(assessed_by) REFERENCES users(id)
) ENGINE=InnoDB;

CREATE TABLE bookings (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, listing_id BIGINT UNSIGNED NOT NULL,
  student_id BIGINT UNSIGNED NOT NULL, landlord_id BIGINT UNSIGNED NOT NULL,
  status ENUM('requested','accepted','declined','cancelled','checked_in','checked_out') NOT NULL DEFAULT 'requested',
  move_in_date DATE NOT NULL, move_out_date DATE,
  roommate_preference ENUM('random_verified','specific_match') NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY(id), KEY idx_booking_student(student_id,status), KEY idx_booking_listing(listing_id,status),
  CONSTRAINT chk_booking_dates CHECK(move_out_date IS NULL OR move_out_date > move_in_date),
  CONSTRAINT fk_booking_listing FOREIGN KEY(listing_id) REFERENCES listings(id),
  CONSTRAINT fk_booking_student FOREIGN KEY(student_id) REFERENCES users(id),
  CONSTRAINT fk_booking_landlord FOREIGN KEY(landlord_id) REFERENCES users(id)
) ENGINE=InnoDB;

CREATE TABLE reviews (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, booking_id BIGINT UNSIGNED NOT NULL,
  listing_id BIGINT UNSIGNED NOT NULL, author_id BIGINT UNSIGNED NOT NULL,
  stars TINYINT UNSIGNED NOT NULL, body TEXT NOT NULL,
  authenticity_weight DECIMAL(6,4) NOT NULL DEFAULT 1.0000,
  status ENUM('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, published_at DATETIME,
  PRIMARY KEY(id), UNIQUE KEY uq_review_booking(booking_id), KEY idx_review_listing(listing_id,status,created_at DESC),
  CONSTRAINT chk_review_stars CHECK(stars BETWEEN 1 AND 5),
  CONSTRAINT chk_review_weight CHECK(authenticity_weight BETWEEN 0 AND 1),
  CONSTRAINT fk_review_booking FOREIGN KEY(booking_id) REFERENCES bookings(id),
  CONSTRAINT fk_review_listing FOREIGN KEY(listing_id) REFERENCES listings(id),
  CONSTRAINT fk_review_author FOREIGN KEY(author_id) REFERENCES users(id)
) ENGINE=InnoDB;

CREATE TABLE listing_review_scores (
  listing_id BIGINT UNSIGNED NOT NULL, weighted_rating DECIMAL(3,2) NOT NULL DEFAULT 0.00,
  review_count INT UNSIGNED NOT NULL DEFAULT 0, total_weight DECIMAL(12,4) NOT NULL DEFAULT 0.0000,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY(listing_id), CONSTRAINT chk_weighted_rating CHECK(weighted_rating BETWEEN 0 AND 5),
  CONSTRAINT fk_score_listing FOREIGN KEY(listing_id) REFERENCES listings(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE listing_reports (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, listing_id BIGINT UNSIGNED NOT NULL, reporter_id BIGINT UNSIGNED NOT NULL,
  category ENUM('structural_crack','waterlogging','electrical_fault','fire_safety','cleanliness','maintenance','scam','other') NOT NULL,
  description TEXT NOT NULL, status ENUM('open','acknowledged','in_progress','resolved','closed') NOT NULL DEFAULT 'open',
  send_to_municipality BOOLEAN NOT NULL DEFAULT FALSE, municipal_reference VARCHAR(255),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, resolved_at DATETIME,
  PRIMARY KEY(id), KEY idx_municipal_queue(send_to_municipality,status,created_at),
  CONSTRAINT fk_report_listing FOREIGN KEY(listing_id) REFERENCES listings(id),
  CONSTRAINT fk_reporter FOREIGN KEY(reporter_id) REFERENCES users(id)
) ENGINE=InnoDB;

CREATE TABLE conversations (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, booking_id BIGINT UNSIGNED NOT NULL,
  student_id BIGINT UNSIGNED NOT NULL, landlord_id BIGINT UNSIGNED NOT NULL,
  unlocked_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(id), UNIQUE KEY uq_conversation_booking(booking_id),
  CONSTRAINT fk_conversation_booking FOREIGN KEY(booking_id) REFERENCES bookings(id) ON DELETE CASCADE,
  CONSTRAINT fk_conversation_student FOREIGN KEY(student_id) REFERENCES users(id),
  CONSTRAINT fk_conversation_landlord FOREIGN KEY(landlord_id) REFERENCES users(id)
) ENGINE=InnoDB;
CREATE TABLE messages (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, conversation_id BIGINT UNSIGNED NOT NULL, sender_id BIGINT UNSIGNED NOT NULL,
  body TEXT NOT NULL, sent_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, read_at DATETIME,
  PRIMARY KEY(id), KEY idx_message_conversation(conversation_id,sent_at),
  CONSTRAINT fk_message_conversation FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
  CONSTRAINT fk_message_sender FOREIGN KEY(sender_id) REFERENCES users(id)
) ENGINE=InnoDB;

CREATE TABLE roommate_preferences (
  student_id BIGINT UNSIGNED NOT NULL, sleep_schedule VARCHAR(60), food_preference VARCHAR(60), cleanliness VARCHAR(60),
  smoking_preference VARCHAR(60), study_habits VARCHAR(60), updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY(student_id), CONSTRAINT fk_preference_student FOREIGN KEY(student_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE TABLE roommate_matches (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, booking_id BIGINT UNSIGNED NOT NULL, matched_student_id BIGINT UNSIGNED NOT NULL,
  compatibility_percentage TINYINT UNSIGNED NOT NULL, accepted_at DATETIME, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(id), UNIQUE KEY uq_roommate_match(booking_id,matched_student_id),
  CONSTRAINT chk_compatibility CHECK(compatibility_percentage BETWEEN 0 AND 100),
  CONSTRAINT fk_match_booking FOREIGN KEY(booking_id) REFERENCES bookings(id) ON DELETE CASCADE,
  CONSTRAINT fk_match_student FOREIGN KEY(matched_student_id) REFERENCES users(id)
) ENGINE=InnoDB;

-- Weighted scores are recomputed inside MySQL whenever a review changes.
DELIMITER $$
CREATE PROCEDURE recompute_listing_review_score(IN p_listing_id BIGINT UNSIGNED)
BEGIN
  INSERT INTO listing_review_scores (listing_id, weighted_rating, review_count, total_weight, updated_at)
  SELECT p_listing_id,
         COALESCE(SUM(stars * authenticity_weight) / NULLIF(SUM(authenticity_weight),0),0),
         COUNT(*), COALESCE(SUM(authenticity_weight),0), NOW()
  FROM reviews WHERE listing_id = p_listing_id AND status = 'verified'
  ON DUPLICATE KEY UPDATE weighted_rating = VALUES(weighted_rating), review_count = VALUES(review_count),
    total_weight = VALUES(total_weight), updated_at = VALUES(updated_at);
END$$
CREATE TRIGGER reviews_score_after_insert AFTER INSERT ON reviews FOR EACH ROW
BEGIN CALL recompute_listing_review_score(NEW.listing_id); END$$
CREATE TRIGGER reviews_score_after_update AFTER UPDATE ON reviews FOR EACH ROW
BEGIN
  CALL recompute_listing_review_score(OLD.listing_id);
  IF NEW.listing_id <> OLD.listing_id THEN CALL recompute_listing_review_score(NEW.listing_id); END IF;
END$$
CREATE TRIGGER reviews_score_after_delete AFTER DELETE ON reviews FOR EACH ROW
BEGIN CALL recompute_listing_review_score(OLD.listing_id); END$$
DELIMITER ;

SET FOREIGN_KEY_CHECKS = 1;
