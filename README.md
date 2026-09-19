# StayMate

StayMate is a local full-stack prototype for verified student PG housing. It includes a student and landlord flow, PG submission, explainable trust signals, manual presentation verification, and a MySQL-backed API.

## Project structure

- `frontend/` — responsive HTML, CSS, and client-side interaction flows
- `backend/` — Express API, authentication, MySQL queries, and local configuration template
- `database/` — MySQL and PostgreSQL database schemas

## Run locally

1. Create a MySQL database using `database/staymate-mysql-schema.sql`.
2. Copy `backend/.env.example` to `backend/.env` and add your local MySQL credentials.
3. In `backend`, run `npm install` and then `npm start`.
4. Open `http://localhost:3000`.

## Important

This is a prototype, not a production system. KYC, verification, review moderation, payment, and My PGmate matching are presentation workflows or partial implementations and require secure external services before public use.
