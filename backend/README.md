# StayMate API

This Express service serves the website and connects it to MySQL.

1. Install Node.js with npm and MySQL 8, or Docker Desktop.
2. Start MySQL using `docker compose up -d` from this folder, or run `../staymate-mysql-schema.sql` against your own MySQL database.
3. Copy `.env.example` to `.env` and enter the database credentials.
4. Run `npm install`, then `npm start`.
5. Visit `http://localhost:3000` (do not open `index.html` directly).

The API offers `GET /api/health`, `GET /api/listings`, `GET /api/roommates`, and `POST /api/roommate-connections`.

Production additions still required: real authentication/session middleware, role and ownership checks, rate limiting, document storage, a KYC provider, and secrets managed outside `.env`.
