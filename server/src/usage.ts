import type { Meter } from "./claude";
import { type Env, today } from "./env";

/** Returns a reason string when this install (or the whole app) is out of generations today. */
export async function quotaProblem(env: Env, install: string): Promise<string | null> {
  const day = today();
  const rows = await env.DB.prepare(
    "SELECT subject, generations FROM usage WHERE day = ?1 AND subject IN ('global', ?2)",
  )
    .bind(day, "install:" + install)
    .all<{ subject: string; generations: number }>();
  const used = (subject: string) => rows.results.find((r) => r.subject === subject)?.generations ?? 0;
  if (used("global") >= Number(env.DAILY_GENERATION_CAP)) {
    return "Sharpy has made all the new questions it can for today. Come back tomorrow for fresh ones.";
  }
  if (install !== "cron" && used("install:" + install) >= Number(env.PER_INSTALL_DAILY_GENERATIONS)) {
    return "You've explored a lot of new ground today. New questions for these topics unlock tomorrow.";
  }
  return null;
}

export async function recordUsage(env: Env, install: string, meter: Meter, generations = 1) {
  const day = today();
  const stmt = env.DB.prepare(
    `INSERT INTO usage (day, subject, generations, input_tokens, output_tokens, searches)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT (day, subject) DO UPDATE SET
       generations = generations + excluded.generations,
       input_tokens = input_tokens + excluded.input_tokens,
       output_tokens = output_tokens + excluded.output_tokens,
       searches = searches + excluded.searches`,
  );
  const args = [generations, meter.input, meter.output, meter.searches] as const;
  await env.DB.batch([
    stmt.bind(day, "global", ...args),
    stmt.bind(day, "install:" + install, ...args),
  ]);
}
