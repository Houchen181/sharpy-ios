import Anthropic from "@anthropic-ai/sdk";
import type {
  BetaContentBlock,
  BetaMessage,
  BetaMessageParam,
  BetaUsage,
} from "@anthropic-ai/sdk/resources/beta/messages/messages";
import type { Env } from "./env";
import { TRUSTED_DOMAINS, isTrusted, publisherFor } from "./sources";

// `fallbacks: "default"` re-runs a request on Anthropic's recommended model if the
// main model's safety classifiers decline it (a false positive on, say, virology).
const BETAS = ["server-side-fallback-2026-07-01"];

export interface Source {
  url: string;
  title: string;
  publisher: string;
  /** Verbatim excerpt from the page, as returned by the web search citation. */
  quote: string;
}

export interface Evidence {
  id: number;
  text: string;
  sources: Source[];
}

/** Claude declined the request even after the fallback model. */
export class RefusedError extends Error {}

/** Token and search counts for one piece of work, written to the usage table afterwards. */
export class Meter {
  input = 0;
  output = 0;
  searches = 0;

  add(u: BetaUsage) {
    this.input += u.input_tokens + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0);
    this.output += u.output_tokens;
    this.searches += u.server_tool_use?.web_search_requests ?? 0;
  }
}

function client(env: Env) {
  return new Anthropic({ apiKey: env.ANTHROPIC_API_KEY, maxRetries: 2, timeout: 170_000 });
}

function checkStop(res: BetaMessage) {
  if (res.stop_reason === "refusal") {
    throw new RefusedError(res.stop_details?.explanation ?? "Claude declined this request.");
  }
}

/**
 * Asks Claude to research with web search limited to TRUSTED_DOMAINS and to write
 * one "FACT:" line per finding. Only facts carrying at least one citation to a
 * trusted page survive, so every source URL and quote comes from the search
 * results themselves rather than from the model's memory.
 */
export async function research(
  env: Env,
  meter: Meter,
  opts: { system: string; user: string; maxSearches: number },
): Promise<Evidence[]> {
  const anthropic = client(env);
  const messages: BetaMessageParam[] = [{ role: "user", content: opts.user }];
  const content: BetaContentBlock[] = [];

  for (let turn = 0; turn < 4; turn++) {
    const res = await anthropic.beta.messages.create({
      model: env.MODEL,
      max_tokens: 16000,
      betas: BETAS,
      fallbacks: "default",
      output_config: { effort: "medium" },
      system: opts.system,
      tools: [
        {
          type: "web_search_20260209",
          name: "web_search",
          max_uses: opts.maxSearches,
          allowed_domains: TRUSTED_DOMAINS,
        },
      ],
      messages,
    });
    meter.add(res.usage);
    checkStop(res);
    content.push(...res.content);
    // A long server-tool turn can pause; send it back to let Claude continue.
    if (res.stop_reason !== "pause_turn") break;
    messages.push({ role: "assistant", content: res.content });
  }

  return factsFromContent(content);
}

/**
 * Splits Claude's "FACT:" lines out of the response and attaches the citations of
 * every text block overlapping each fact. Facts with no trusted citation are dropped.
 */
export function factsFromContent(content: BetaContentBlock[]): Evidence[] {
  // Lay the text blocks end to end, remembering which citations cover which span.
  let full = "";
  const spans: { start: number; end: number; sources: Source[] }[] = [];
  for (const block of content) {
    if (block.type !== "text") continue;
    const start = full.length;
    full += block.text;
    const sources: Source[] = [];
    for (const c of block.citations ?? []) {
      if (c.type !== "web_search_result_location" || !isTrusted(c.url)) continue;
      sources.push({
        url: c.url,
        title: c.title ?? publisherFor(c.url),
        publisher: publisherFor(c.url),
        quote: c.cited_text.trim(),
      });
    }
    spans.push({ start, end: full.length, sources });
  }

  const facts: Evidence[] = [];
  const re = /FACT:\s*([\s\S]*?)(?=\n\s*FACT:|$)/g;
  for (let m = re.exec(full); m; m = re.exec(full)) {
    // A fact ends at the next FACT line or blank line (ignore any closing remarks).
    const para = m[0].split(/\n\s*\n/)[0];
    const start = m.index;
    const end = m.index + para.length;
    const seen = new Set<string>();
    const sources: Source[] = [];
    for (const s of spans) {
      if (s.start >= end || s.end <= start) continue;
      for (const src of s.sources) {
        const key = src.url + "\n" + src.quote;
        if (!seen.has(key)) {
          seen.add(key);
          sources.push(src);
        }
      }
    }
    const text = para.replace(/^FACT:\s*/, "").replace(/\s+/g, " ").trim();
    if (text && sources.length) facts.push({ id: facts.length + 1, text, sources });
  }
  return facts;
}

/** One Claude call whose reply is JSON matching `schema` (structured outputs). */
export async function structured<T>(
  env: Env,
  meter: Meter,
  opts: {
    system: string;
    user: string;
    schema: Record<string, unknown>;
    effort: "low" | "medium" | "high";
  },
): Promise<T> {
  const res = await client(env).beta.messages.create({
    model: env.MODEL,
    max_tokens: 16000,
    betas: BETAS,
    fallbacks: "default",
    output_config: { effort: opts.effort, format: { type: "json_schema", schema: opts.schema } },
    system: opts.system,
    messages: [{ role: "user", content: opts.user }],
  });
  meter.add(res.usage);
  checkStop(res);
  if (res.stop_reason === "max_tokens") throw new Error("Claude ran out of room before finishing.");
  const text = res.content.map((b) => (b.type === "text" ? b.text : "")).join("");
  return JSON.parse(text) as T;
}

/** Renders evidence as a numbered list for the writing and checking prompts. */
export function evidenceBlock(facts: Evidence[]): string {
  return facts
    .map((f) => {
      const quotes = f.sources
        .slice(0, 2)
        .map((s) => `   source: ${s.publisher} — "${s.title}"\n   excerpt: "${s.quote}"`)
        .join("\n");
      return `[${f.id}] ${f.text}\n${quotes}`;
    })
    .join("\n\n");
}

/** Collapses whitespace and curly quotes so a quote can be matched against its source text. */
export function normalizeForMatch(s: string): string {
  return s
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}
