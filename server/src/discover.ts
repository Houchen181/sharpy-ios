import { Meter, type Source, evidenceBlock, normalizeForMatch, research, structured } from "./claude";
import { type Env, today } from "./env";
import { type SourceDoc, nasaApod, quantaLatest, wikipediaFeatured } from "./feeds";
import { newId } from "./quiz";
import { recordUsage } from "./usage";

export type CardKind = "field_primer" | "featured_article" | "on_this_day" | "space" | "worth_reading";

export interface CheckQuestion {
  question: string;
  choices: string[];
  answerIndex: number;
  explanation: string;
}

export interface DiscoverCard {
  id: string;
  kind: CardKind;
  eyebrow: string;
  title: string;
  body: string;
  bullets: string[];
  whyItMatters: string;
  imageURL: string | null;
  sources: Source[];
  check: CheckQuestion | null;
}

export interface DiscoverFeed {
  date: string;
  cards: DiscoverCard[];
}

// One field a day, in rotation, so learners wander outside their own expertise.
const FIELDS = [
  "Linguistics", "Immunology", "Plate tectonics", "Game theory", "Cryptography", "Marine biology",
  "Thermodynamics", "Behavioral economics", "Epidemiology", "Number theory", "Materials science",
  "Cognitive psychology", "Climate science", "Archaeology", "Quantum mechanics", "Neuroscience",
  "Information theory", "Ecology", "Astrophysics", "Genetics", "Philosophy of science", "Oceanography",
  "Machine learning", "Organic chemistry", "Urban planning", "Music theory", "Statistics", "Volcanology",
  "Microbiology", "Cosmology", "Developmental biology", "Monetary economics", "Topology", "Pharmacology",
  "Paleontology", "Optics", "Anthropology", "Control theory", "Mycology", "Glaciology", "Logic",
  "Evolutionary biology", "Seismology", "Public health", "Fluid dynamics", "Botany", "Graph theory",
  "Ethology", "Atmospheric science", "Computational complexity", "Endocrinology", "Semiconductor physics",
];

export function fieldOfTheDay(date: string): string {
  const day = Math.floor(Date.parse(date + "T00:00:00Z") / 86_400_000);
  return FIELDS[day % FIELDS.length];
}

const EYEBROWS: Record<CardKind, string> = {
  field_primer: "Field of the day",
  featured_article: "Wikipedia's featured article",
  on_this_day: "On this day",
  space: "NASA picture of the day",
  worth_reading: "Worth reading",
};

const CARD_SYSTEM = `You write the daily "Discover" cards for Sharpy, a learning app. Readers want one genuinely interesting thing to learn, explained clearly and accurately.
Use only what the given source text says. Do not add facts from memory, even well-known ones. No hype, no clickbait, no exclamation marks.`;

const CHECK_SYSTEM = `You check quiz questions before learners see them. Use only the evidence given for each question.
Work out which choice the evidence supports without assuming the author was right. Set ok to false if the evidence does not settle it or more than one choice could be defended.`;

const QUESTION_PROPS = {
  question: { type: "string" },
  choices: { type: "array", items: { type: "string" } },
  answer_index: { type: "integer" },
  explanation: { type: "string" },
};

const DOC_CARDS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["cards"],
  properties: {
    cards: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["source", "title", "body", "why_it_matters", "quote", ...Object.keys(QUESTION_PROPS)],
        properties: {
          source: { type: "integer" },
          title: { type: "string" },
          body: { type: "string" },
          why_it_matters: { type: "string" },
          quote: { type: "string" },
          ...QUESTION_PROPS,
        },
      },
    },
  },
};

const PRIMER_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["title", "body", "bullets", "why_it_matters", ...Object.keys(QUESTION_PROPS)],
  properties: {
    title: { type: "string" },
    body: { type: "string" },
    bullets: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["text", "fact_id"],
        properties: { text: { type: "string" }, fact_id: { type: "integer" } },
      },
    },
    why_it_matters: { type: "string" },
    ...QUESTION_PROPS,
  },
};

const CHECK_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["results"],
  properties: {
    results: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["question", "answer_index", "ok"],
        properties: { question: { type: "integer" }, answer_index: { type: "integer" }, ok: { type: "boolean" } },
      },
    },
  },
};

interface DraftQuestion {
  question: string;
  choices: string[];
  answer_index: number;
  explanation: string;
}

function toCheck(d: DraftQuestion): CheckQuestion | null {
  if (!d.question.trim() || d.choices.length < 2 || d.choices.length > 4) return null;
  if (d.answer_index < 0 || d.answer_index >= d.choices.length) return null;
  return { question: d.question.trim(), choices: d.choices, answerIndex: d.answer_index, explanation: d.explanation.trim() };
}

async function buildFeed(env: Env, date: string, meter: Meter): Promise<DiscoverFeed> {
  const field = fieldOfTheDay(date);
  const [wiki, apod, quanta, facts] = await Promise.allSettled([
    wikipediaFeatured(new Date(date + "T12:00:00Z")),
    nasaApod(env.NASA_API_KEY),
    quantaLatest(3),
    research(env, meter, {
      system: `You are the research desk for Sharpy, a learning app. Gather precise, checkable facts from reliable sources and cite them. Write only what the pages you find state directly.`,
      maxSearches: 4,
      user: `Field: ${field}
Find 8 facts that give a curious newcomer a real foothold in this field: the central question it asks, one key idea or method, a landmark discovery (who and when), how it touches everyday life, and one thing that surprises most people.
Output one fact per line, each line starting with "FACT:". One or two sentences per fact. No other text.`,
    }),
  ]);
  for (const r of [wiki, apod, quanta, facts]) {
    if (r.status === "rejected") console.error("discover source failed", r.reason);
  }

  const docs: SourceDoc[] = [
    ...(wiki.status === "fulfilled" ? wiki.value : []),
    ...(apod.status === "fulfilled" && apod.value ? [apod.value] : []),
    ...(quanta.status === "fulfilled" ? quanta.value : []),
  ];
  const cards: DiscoverCard[] = [];
  const checks: { card: DiscoverCard; evidence: string }[] = [];

  if (docs.length) {
    const draft = await structured<{
      cards: ({ source: number; title: string; body: string; why_it_matters: string; quote: string } & DraftQuestion)[];
    }>(env, meter, {
      system: CARD_SYSTEM,
      effort: "medium",
      schema: DOC_CARDS_SCHEMA,
      user: `Sources (kind in brackets):
${docs.map((d, i) => `S${i + 1} [${d.label}] "${d.title}" (${d.publisher})\n${d.text}`).join("\n\n")}

Write one card for each kind present: featured_article, the single most interesting on_this_day event, space, and the single best worth_reading story.
- source: the S number the card is based on (just the number).
- title: up to 8 words.
- body: 50–80 words that teach something specific, in plain language.
- why_it_matters: one sentence.
- quote: an exact, word-for-word excerpt of 8–30 words from that source's text, copied verbatim.
- A check question about the card with 3 or 4 choices, answerable from the source; explanation in one sentence.`,
    });
    for (const c of draft.cards) {
      const doc = docs[c.source - 1];
      if (!doc) continue;
      // The quote must really be in the source; otherwise the card is suspect.
      if (!c.quote.trim() || !normalizeForMatch(doc.text).includes(normalizeForMatch(c.quote))) continue;
      if (cards.some((x) => x.kind === doc.label)) continue;
      const kind = doc.label as CardKind;
      const card: DiscoverCard = {
        id: newId(),
        kind,
        eyebrow: EYEBROWS[kind],
        title: c.title.trim(),
        body: c.body.trim(),
        bullets: [],
        whyItMatters: c.why_it_matters.trim(),
        imageURL: doc.imageURL ?? null,
        sources: [{ url: doc.url, title: doc.title, publisher: doc.publisher, quote: c.quote.trim() }],
        check: toCheck(c),
      };
      cards.push(card);
      if (card.check) checks.push({ card, evidence: doc.text });
    }
  }

  if (facts.status === "fulfilled" && facts.value.length >= 3) {
    const evidence = facts.value;
    const p = await structured<{
      title: string;
      body: string;
      bullets: { text: string; fact_id: number }[];
      why_it_matters: string;
    } & DraftQuestion>(env, meter, {
      system: CARD_SYSTEM,
      effort: "medium",
      schema: PRIMER_SCHEMA,
      user: `Field of the day: ${field}

Evidence:
${evidenceBlock(evidence)}

Write a primer card for a curious newcomer:
- title: a hook of up to 8 words (not just the field's name).
- body: 2–3 sentences on what the field studies and why it is interesting.
- bullets: exactly 3 facts from the evidence, each one sentence, with the fact_id it comes from.
- why_it_matters: one sentence.
- A check question with 3 or 4 choices, answerable from the evidence; explanation in one sentence.`,
    });
    const sources: Source[] = [];
    for (const b of p.bullets) {
      for (const s of evidence.find((f) => f.id === b.fact_id)?.sources ?? []) {
        if (!sources.some((x) => x.url === s.url)) sources.push(s);
      }
    }
    if (sources.length) {
      const card: DiscoverCard = {
        id: newId(),
        kind: "field_primer",
        eyebrow: `${EYEBROWS.field_primer} · ${field}`,
        title: p.title.trim(),
        body: p.body.trim(),
        bullets: p.bullets.map((b) => b.text.trim()).slice(0, 3),
        whyItMatters: p.why_it_matters.trim(),
        imageURL: null,
        sources: sources.slice(0, 4),
        check: toCheck(p),
      };
      cards.unshift(card);
      if (card.check) checks.push({ card, evidence: evidenceBlock(evidence) });
    }
  }

  // Keep a check question only if an independent pass reaches the same answer.
  if (checks.length) {
    const verdict = await structured<{ results: { question: number; answer_index: number; ok: boolean }[] }>(env, meter, {
      system: CHECK_SYSTEM,
      effort: "medium",
      schema: CHECK_SCHEMA,
      user: checks
        .map(({ card, evidence }, i) => {
          const q = card.check!;
          return `Question ${i}\nEvidence:\n${evidence}\n\n${q.question}\n${q.choices.map((c, j) => `   ${j}. ${c}`).join("\n")}`;
        })
        .join("\n\n---\n\n"),
    });
    checks.forEach(({ card }, i) => {
      const v = verdict.results.find((r) => r.question === i);
      if (!v?.ok || v.answer_index !== card.check!.answerIndex) card.check = null;
    });
  }

  return { date, cards };
}

/** Builds and stores the feed for `date` unless it exists or another run is building it. */
export async function ensureDiscover(env: Env, date = today()): Promise<DiscoverFeed | null> {
  const existing = await env.DB.prepare("SELECT payload FROM daily WHERE kind = 'discover' AND key = ?1")
    .bind(date)
    .first<{ payload: string }>();
  if (existing) return JSON.parse(existing.payload) as DiscoverFeed;

  const now = Date.now();
  const lock = await env.DB.prepare(
    `INSERT INTO daily (kind, key, payload, created_at) VALUES ('lock', ?1, '', ?2)
     ON CONFLICT (kind, key) DO UPDATE SET created_at = excluded.created_at WHERE daily.created_at < ?3`,
  )
    .bind("discover:" + date, now, now - 600_000)
    .run();
  if (lock.meta.changes !== 1) return null;

  const meter = new Meter();
  try {
    const feed = await buildFeed(env, date, meter);
    if (feed.cards.length) {
      await env.DB.prepare("INSERT OR REPLACE INTO daily (kind, key, payload, created_at) VALUES ('discover', ?1, ?2, ?3)")
        .bind(date, JSON.stringify(feed), Date.now())
        .run();
    }
    return feed;
  } finally {
    await env.DB.prepare("DELETE FROM daily WHERE kind = 'lock' AND key = ?1").bind("discover:" + date).run();
    if (meter.input) await recordUsage(env, "cron", meter);
  }
}

/** GET /v1/discover — the newest feed on or before the learner's local date. */
export async function latestDiscover(env: Env, date: string): Promise<DiscoverFeed | null> {
  const row = await env.DB.prepare(
    "SELECT payload FROM daily WHERE kind = 'discover' AND key <= ?1 ORDER BY key DESC LIMIT 1",
  )
    .bind(date)
    .first<{ payload: string }>();
  return row ? (JSON.parse(row.payload) as DiscoverFeed) : null;
}
