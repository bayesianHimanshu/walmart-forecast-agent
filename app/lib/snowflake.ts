// Connects to Snowflake from inside a Snowpark Container Services container.
// SPCS injects an OAuth token at /snowflake/session/token and account/host env
// vars, so the container authenticates as the service's owner role — no secrets
// to manage. Falls back to env-based key-pair/password auth for local dev.
import snowflake from 'snowflake-sdk';
import { readFileSync } from 'fs';

snowflake.configure({ logLevel: 'ERROR' });

const DATABASE = process.env.SNOWFLAKE_DATABASE || 'WALMART_DEMO';
const SCHEMA = process.env.SNOWFLAKE_SCHEMA || 'FORECAST';
const WAREHOUSE = process.env.SNOWFLAKE_WAREHOUSE || 'WALMART_WH';

function spcsToken(): string | null {
  try {
    return readFileSync('/snowflake/session/token', 'utf8');
  } catch {
    return null;
  }
}

function connectionOptions(): snowflake.ConnectionOptions {
  const token = spcsToken();
  const base = {
    account: process.env.SNOWFLAKE_ACCOUNT!,
    host: process.env.SNOWFLAKE_HOST,
    database: DATABASE,
    schema: SCHEMA,
    warehouse: WAREHOUSE,
  } as snowflake.ConnectionOptions;

  if (token) {
    return { ...base, authenticator: 'OAUTH', token };
  }
  // Local development fallback (username/password from env).
  return {
    ...base,
    username: process.env.SNOWFLAKE_USER!,
    password: process.env.SNOWFLAKE_PASSWORD!,
  };
}

// One-shot query: connect, run, destroy. The SPCS token can rotate, so a fresh
// connection per request keeps things simple and robust for a demo workload.
export function runSql<T = any>(sqlText: string, binds: any[] = []): Promise<T[]> {
  return new Promise((resolve, reject) => {
    const conn = snowflake.createConnection(connectionOptions());
    conn.connect((err) => {
      if (err) return reject(err);
      conn.execute({
        sqlText,
        binds,
        complete: (execErr, _stmt, rows) => {
          conn.destroy(() => {});
          if (execErr) return reject(execErr);
          resolve((rows || []) as T[]);
        },
      });
    });
  });
}
