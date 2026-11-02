import { Meter, normalizeForMatch, structured } from "./claude";
import { type Env, today } from "./env";
import { type Paper, arxivRecent, crossrefRecent, openAlexRecent } from "./feeds";
import { newId, normalizeTopic } from "./quiz";
import { quotaProblem, recordUsage } from "./usage";

/** A new paper in the learner's field, summarized strictly from its abstract. */
export interface FieldUpdate {
  id: string;
  topic: string;
  headline: string;
  summary: string;
  whyItMatters: string;
  quote: string;
  url: string;
  venue: string;
  peerReviewed: boolean;
  date: string;
  authors: string;
}

const SYSTEM = `You brief busy experts on new research in their field for Sharpy, a learning app.
Summarize only what each abstract says, in plain language. State findings with the same certainty the authors use; never overstate. No hype words such as "breakthrough" or "revolutionary".`;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["picks"],
  properties: {
    picks: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["paper", "headline", "summary", "why_it_matters", "quote"],
        properties: {
          paper: { type: "integer" },
          headline: { type: "string" },
          summary: { type: "string" },
          why_it_matters: { type: "string" },
          quote: { type: "string" },
        },
      },
    },
  },
};

async function buildUpdates(env: Env, meter: Meter, display: string): Promise<FieldUpdate[]> {
  const [journals, preprints] = await Promise.allSettled([
    env.OPENALEX_API_KEY ? openAlexRecent(display, env.OPENALEX_API_KEY) : crossrefRecent(display),
    arxivRecent(display),
  ]);
  const papers: Paper[] = [
    ...(journals.status === "fulfilled" ? journals.value : []),
    ...(preprints.status === "fulfilled" ? preprints.value : []),
  ];
  if (!papers.length) return [];

  const out = await structured<{
    picks: { paper: number; headline: string; summary: string; why_it_matters: string; quote: string }[];
  }>(env, meter, {
    system: SYSTEM,
    effort: "medium",
    schema: SCHEMA,
    user: `Field: ${display}

Recent papers:
${papers
  .map((p, i) => `P${i + 1}. "${p.title}" — ${p.venue}, ${p.date}${p.peerReviewed ? "" : " (preprint, not peer reviewed)"}\nAbstract: ${p.abstract}`)
  .join("\n\n")}

Pick up to 3 papers that are clearly about ${display} and most worth an expert's attention. Prefer peer-reviewed work in established journals, and skip any venue you don't recognize as reputable. Pick none if nothing fits.
- paper: the P number (just the number).
- headline: up to 12 words, plain and accurate.
- summary: 40–60 words on what they did and found, from the abstract only.
- why_it_matters: one cautious sentence.
- quote: an exact, word-for-word excerpt of 10–30 words from the abstract.`,
  });

  const updates: FieldUpdate[] = [];
  for (const pick of out.picks) {
    const p = papers[pick.paper - 1];
    if (!p || updates.some((u) => u.url === p.url)) continue;
    if (!normalizeForMatch(p.abstract).includes(normalizeForMatch(pick.quote))) continue;
    updates.push({
      id: newId(),
      topic: display,
      headline: pick.headline.trim(),
      summary: pick.summary.trim(),
      whyItMatters: pick.why_it_matters.trim(),
      quote: pick.quote.trim(),
      url: p.url,
      venue: p.venue,
      peerReviewed: p.peerReviewed,
      date: p.date,
      authors: p.authors,
    });
  }
  return updates.slice(0, 3);
}

/**
 * POST /v1/updates — streams one {"type":"updates","topic":…,"items":[…]} line
 * per topic. Each topic's briefing is built at most once a day and shared.
 */
export async function updatesStream(
  env: Env,
  install: string,
  body: { topics?: unknown },
  send: (line: Record<string, unknown>) => Promise<void>,
) {
  const topics = (Array.isArray(body.topics) ? body.topics : [])
    .filter((t): t is string => typeof t === "string")
    .map(normalizeTopic)
    .filter((t): t is { key: string; display: string } => t !== null)
    .slice(0, 5);
  const date = today();

  await Promise.all(
    topics.map(async (t) => {
      const key = `${t.key}|${date}`;
      const cached = await env.DB.prepare("SELECT payload FROM daily WHERE kind = 'updates' AND key = ?1")
        .bind(key)
        .first<{ payload: string }>();
      if (cached) {
        await send({ type: "updates", topic: t.display, items: JSON.parse(cached.payload) });
        return;
      }
      const problem = await quotaProblem(env, install);
      if (problem) {
        await send({ type: "updates", topic: t.display, items: [], note: problem });
        return;
      }
      await send({ type: "progress", message: `Reading new papers on “${t.display}”…` });
      const meter = new Meter();
      try {
        const items = await buildUpdates(env, meter, t.display);
        await env.DB.prepare("INSERT OR REPLACE INTO daily (kind, key, payload, created_at) VALUES ('updates', ?1, ?2, ?3)")
          .bind(key, JSON.stringify(items), Date.now())
          .run();
        await send({ type: "updates", topic: t.display, items });
      } catch (err) {
        console.error("updates failed", t.key, err);
        await send({ type: "updates", topic: t.display, items: [], note: "Couldn't load new papers right now." });
      } finally {
        if (meter.input) await recordUsage(env, install, meter);
      }
    }),
  );
  await send({ type: "done" });
}
