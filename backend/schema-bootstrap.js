import { readFileSync } from 'node:fs';
import path from 'node:path';

export async function bootstrapSchema(pool, backendDir) {
  const schemaFile = path.resolve(backendDir, '..', 'database', 'staymate-mysql-schema.sql');
  const baseSchema = readFileSync(schemaFile, 'utf8')
    .split('-- Weighted scores are recomputed')[0]
    .replace(/^CREATE DATABASE.*;\r?\n/m, '')
    .replace(/^USE staymate;\r?\n/m, '')
    .replace(/CREATE TABLE\s+(?!IF NOT EXISTS)/gi, 'CREATE TABLE IF NOT EXISTS ');
  await pool.query(baseSchema);
}
