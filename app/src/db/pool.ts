import pg from "pg";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const { Pool } = pg;

export function createPool(databaseUrl?: string) {
  return new Pool({
    connectionString: databaseUrl ?? process.env.DATABASE_URL ?? "postgres://andx:andx@127.0.0.1:5432/andx",
  });
}

export async function migrate(pool: pg.Pool) {
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const sql = readFileSync(join(__dirname, "../../migrations/001_init.sql"), "utf8");
  await pool.query(sql);
}
