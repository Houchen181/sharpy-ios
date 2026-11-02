export interface Env {
  DB: D1Database;
  BURST: RateLimit;
  ANTHROPIC_API_KEY: string;
  /** Bearer token for GET /v1/admin/usage. */
  ADMIN_TOKEN?: string;
  NASA_API_KEY?: string;
  OPENALEX_API_KEY?: string;
  MODEL: string;
  DAILY_GENERATION_CAP: string;
  PER_INSTALL_DAILY_GENERATIONS: string;
}

export type Level = "curious" | "student" | "pro";

export const LEVELS: Record<Level, string> = {
  curious: "a curious adult with no formal training in the field",
  student: "a university student taking courses in the field",
  pro: "a working professional or researcher in the field; go past textbook basics",
};

export const USER_AGENT = "SharpyApp/1.0 (+https://github.com/Houchen181/sharpy-ios)";

export function today(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}
