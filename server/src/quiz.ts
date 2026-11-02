import { type Evidence, Meter, RefusedError, type Source, evidenceBlock, research, structured } from "./claude";
import { type Env, LEVELS, type Level } from "./env";
import { quotaProblem, recordUsage } from "./usage";

/** A failure whose message is fit to show the learner. */
export class GenerationError extends Error {}

export type ItemKind = "true_false" | "multiple_choice" | "select_all" | "spot_the_error";

/** What the app receives. True/false items use choices ["True", "False"]. */
export interface QuizItem {
  id: string;
  topic: string;
  kind: ItemKind;
  prompt: string;
  choices: string[];
  /** The first (for single-answer kinds, the only) correct choice; kept for older app builds. */
  answerIndex: number;
  /** Every correct choice, ascending. More than one only for "select_all". */
  answerIndices: number[];
  /** A deliberately wrong statement (or a misconception-baited distractor) the learner should catch. */
  isTrap: boolean;
  explanation: string;
  misconception: string;
  difficulty: number;
  sources: Source[];
}

interface DraftItem {
  kind: ItemKind;
  prompt: string;
  choices: string[];
  answer_indices: number[];
  is_trap: boolean;
  explanation: string;
  misconception: string;
  difficulty: number;
  fact_ids: number[];
}

interface Check {
  item: number;
  answer_indices: number[];
  ok: boolean;
  note: string;
}

const RESEARCH_SYSTEM = `You are the research desk for Sharpy, an app people use for a few minutes a day to keep their thinking sharp in their own field.
Gather precise, checkable facts from reliable sources: reference works, peer-reviewed journals, government and university sites, and official documentation.
Write only what the pages you find state directly, and cite them. Prefer specific details (numbers, dates, mechanisms, definitions, cause and effect, who found what) over generalities.
Leave out contested claims, fast-moving news, and anything you cannot source.`;

const WRITER_SYSTEM = `You write practice items for Sharpy. Every item must be answerable from the numbered evidence you are given and nothing else.
Some items are traps: statements that sound right but are wrong in one specific way, such as a swapped number or date, a wrong attribution, reversed cause and effect, an overgeneralization, or a popular misconception.
A good trap is plausible to someone who half-remembers the topic, yet the evidence clearly refutes it. Never build a trap from vague wording or trick grammar; the error must be a real factual error that the explanation can point to.
Write plainly. Explanations teach the idea in one to three sentences and state the correct fact.`;

const CHECKER_SYSTEM = `You check practice items for Sharpy before learners see them. Use only the numbered evidence.
For each item, work out which choice the evidence supports, without assuming the item's author was right.
For true/false items answer [0] for True and [1] for False. For "which statement is wrong" items, answer with the wrong statement. For "select all that apply" items, list every choice the evidence supports, and only those.
Set ok to false if the evidence does not settle the item, if a single-answer item has more than one defensible choice, or if the wording is misleading.`;

const DRAFT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["items"],
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: [
          "kind", "prompt", "choices", "answer_indices", "is_trap",
          "explanation", "misconception", "difficulty", "fact_ids",
        ],
        properties: {
          kind: { type: "string", enum: ["true_false", "multiple_choice", "select_all", "spot_the_error"] },
          prompt: { type: "string" },
          choices: { type: "array", items: { type: "string" } },
          answer_indices: { type: "array", items: { type: "integer" } },
          is_trap: { type: "boolean" },
          explanation: { type: "string" },
          misconception: { type: "string" },
          difficulty: { type: "integer" },
          fact_ids: { type: "array", items: { type: "integer" } },
        },
      },
    },
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
        required: ["item", "answer_indices", "ok", "note"],
        properties: {
          item: { type: "integer" },
          answer_indices: { type: "array", items: { type: "integer" } },
          ok: { type: "boolean" },
          note: { type: "string" },
        },
      },
    },
  },
};

/** Lower-case, single-spaced key used to share item banks between learners. */
export function normalizeTopic(raw: string): { key: string; display: string } | null {
  const display = raw.replace(/\s+/g, " ").trim();
  if (display.length < 2 || display.length > 48) return null;
  if (!/^[\p{L}\p{N} .,'&+\-#/()]+$/u.test(display)) return null;
  return { key: display.toLowerCase(), display };
}

export function newId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(9));
  return Array.from(bytes, (b) => b.toString(36).padStart(2, "0")).join("").slice(0, 14);
}

function shuffle<T>(xs: T[]): T[] {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) {
    const j = crypto.getRandomValues(new Uint32Array(1))[0] % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/** Shuffles the choices of every kind except true/false, keeping the key right. */
function shuffleChoices(item: QuizItem): QuizItem {
  if (item.kind === "true_false") return item;
  const order = shuffle(item.choices.map((_, i) => i));
  const answers = item.answerIndices.map((a) => order.indexOf(a)).sort((a, b) => a - b);
  return {
    ...item,
    choices: order.map((i) => item.choices[i]),
    answerIndex: answers[0],
    answerIndices: answers,
  };
}

function sameAnswers(a: number[], b: number[]): boolean {
  const x = [...new Set(a)].sort((p, q) => p - q);
  const y = [...new Set(b)].sort((p, q) => p - q);
  return x.length === y.length && x.every((v, i) => v === y[i]);
}

function wellFormed(d: DraftItem): boolean {
  if (!d.prompt.trim() || !d.explanation.trim()) return false;
  const answers = new Set(d.answer_indices);
  if (answers.size !== d.answer_indices.length) return false;
  if (d.answer_indices.some((a) => a < 0 || a >= d.choices.length)) return false;
  switch (d.kind) {
    case "true_false":
      return d.choices.length === 2 && answers.size === 1;
    case "multiple_choice":
      return d.choices.length === 4 && answers.size === 1;
    case "select_all":
      // At least one right and one wrong choice, so neither "tick all" nor "tick none" works.
      return d.choices.length >= 4 && d.choices.length <= 5 && answers.size >= 2 && answers.size < d.choices.length;
    case "spot_the_error":
      return d.choices.length >= 3 && d.choices.length <= 4 && answers.size === 1;
  }
}

/**
 * Research → write → check. Returns only items whose key an independent pass
 * reproduced from the cited evidence. Typically 6–10 items.
 */
export async function generateBatch(
  env: Env,
  meter: Meter,
  display: string,
  level: Level,
  progress: (message: string) => void,
): Promise<QuizItem[]> {
  progress(`Searching trusted sources for “${display}”…`);
  const facts = await research(env, meter, {
    system: RESEARCH_SYSTEM,
    maxSearches: 5,
    user: `Topic: ${display}
Learner: ${LEVELS[level]}.

Find 14 facts this learner should know or would find illuminating, spread across different subtopics. Mix core ideas with a few surprising ones, and include several facts that people commonly get wrong.
Output one fact per line, each line starting with "FACT:". One or two sentences per fact. No other text.`,
  });
  if (facts.length < 4) throw new GenerationError(`Couldn't find enough well-sourced material on “${display}”.`);

  progress(`Writing questions from ${facts.length} sourced facts…`);
  const draft = await structured<{ items: DraftItem[] }>(env, meter, {
    system: WRITER_SYSTEM,
    effort: "high",
    schema: DRAFT_SCHEMA,
    user: `Topic: ${display}
Learner: ${LEVELS[level]}.

Evidence:
${evidenceBlock(facts)}

Write 10 items:
- 3 "true_false": the prompt is one statement; choices exactly ["True", "False"]; answer_indices [0] if the statement is true, [1] if false. At least 2 must be false traps (is_trap true).
- 3 "multiple_choice" (single answer): the prompt is a question; exactly 4 choices, one correct, the others plausible; answer_indices holds the correct one. Set is_trap true when the most tempting wrong choice is a common misconception.
- 2 "select_all": the prompt is a question ending "Select all that apply."; 4 or 5 choices, of which 2 or 3 are correct and the rest are plausible but wrong; answer_indices lists every correct choice. Set is_trap true when a wrong choice is a common misconception.
- 2 "spot_the_error": the prompt is "One of these statements is wrong. Which one?"; 3 or 4 statements, all true except one subtle trap; answer_indices points to the wrong one; is_trap true.
misconception: for traps, name the misconception in a few words; otherwise "".
difficulty: 1 (core idea) to 3 (expert detail).
fact_ids: the evidence numbers the item depends on.`,
  });

  const drafts = draft.items.filter(wellFormed);
  if (!drafts.length) return [];

  progress("Double-checking every answer against the sources…");
  const check = await structured<{ results: Check[] }>(env, meter, {
    system: CHECKER_SYSTEM,
    effort: "medium",
    schema: CHECK_SCHEMA,
    user: `Evidence:
${evidenceBlock(facts)}

Items:
${drafts
  .map((d, i) => {
    const choices = d.choices.map((c, j) => `   ${j}. ${c}`).join("\n");
    return `Item ${i}: (${d.kind})\n${d.prompt}\n${choices}`;
  })
  .join("\n\n")}`,
  });

  const byId = new Map<number, Evidence>(facts.map((f) => [f.id, f]));
  const items: QuizItem[] = [];
  drafts.forEach((d, i) => {
    const verdict = check.results.find((r) => r.item === i);
    if (!verdict?.ok || !sameAnswers(verdict.answer_indices, d.answer_indices)) return;
    const answers = [...d.answer_indices].sort((a, b) => a - b);
    const sources: Source[] = [];
    for (const id of d.fact_ids) {
      for (const s of byId.get(id)?.sources ?? []) {
        if (!sources.some((x) => x.url === s.url)) sources.push(s);
      }
    }
    if (!sources.length) return;
    items.push(
      shuffleChoices({
        id: newId(),
        topic: display,
        kind: d.kind,
        prompt: d.prompt.trim(),
        choices: d.choices.map((c) => c.trim()),
        answerIndex: answers[0],
        answerIndices: answers,
        isTrap: d.is_trap,
        explanation: d.explanation.trim(),
        misconception: d.misconception.trim(),
        difficulty: Math.min(3, Math.max(1, d.difficulty)),
        sources: sources.slice(0, 3),
      }),
    );
  });
  return items;
}

async function saveItems(env: Env, key: string, level: Level, items: QuizItem[]) {
  if (!items.length) return;
  const now = Date.now();
  const stmt = env.DB.prepare(
    "INSERT INTO items (id, topic, level, payload, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
  );
  await env.DB.batch(items.map((it) => stmt.bind(it.id, key, level, JSON.stringify(it), now)));
}

async function loadBank(env: Env, key: string, level: Level): Promise<QuizItem[]> {
  const rows = await env.DB.prepare(
    "SELECT payload FROM items WHERE topic = ?1 AND level = ?2 AND retired = 0 ORDER BY created_at DESC LIMIT 300",
  )
    .bind(key, level)
    .all<{ payload: string }>();
  return rows.results.map((r) => JSON.parse(r.payload) as QuizItem);
}

/** Claims the right to generate for a topic for three minutes; false if someone else holds it. */
async function lockTopic(env: Env, key: string, level: Level): Promise<boolean> {
  const now = Date.now();
  const res = await env.DB.prepare(
    "UPDATE topics SET generating_until = ?1 WHERE topic = ?2 AND level = ?3 AND generating_until < ?4",
  )
    .bind(now + 180_000, key, level, now)
    .run();
  return res.meta.changes === 1;
}

async function unlockTopic(env: Env, key: string, level: Level, extra = "") {
  await env.DB.prepare(`UPDATE topics SET generating_until = 0${extra} WHERE topic = ?1 AND level = ?2`)
    .bind(key, level)
    .run();
}

/**
 * Generates and stores a batch for one topic, holding the topic lock. Returns
 * false (without generating) when another request is already doing it.
 */
async function refillTopic(
  env: Env,
  install: string,
  key: string,
  display: string,
  level: Level,
  progress: (m: string) => void,
): Promise<boolean> {
  if (!(await lockTopic(env, key, level))) return false;
  const meter = new Meter();
  try {
    const items = await generateBatch(env, meter, display, level, progress);
    await saveItems(env, key, level, items);
    await unlockTopic(env, key, level, ", needs_refill = 0");
    return true;
  } catch (err) {
    await unlockTopic(env, key, level, err instanceof RefusedError ? ", blocked = 1" : "");
    throw err;
  } finally {
    if (meter.input) await recordUsage(env, install, meter);
  }
}

type Line = Record<string, unknown>;

/**
 * POST /v1/session — streams NDJSON: progress lines while any missing questions
 * are generated, then one {"type":"session","items":[…]} line.
 */
export async function sessionStream(
  env: Env,
  install: string,
  body: { topics?: unknown; level?: unknown; count?: unknown; seen?: unknown },
  send: (line: Line) => Promise<void>,
) {
  const level: Level = body.level === "curious" || body.level === "pro" ? body.level : "student";
  const count = Math.min(20, Math.max(3, Number(body.count) || 10));
  const seen = new Set(Array.isArray(body.seen) ? body.seen.filter((s) => typeof s === "string").slice(-2000) : []);
  const topics = (Array.isArray(body.topics) ? body.topics : [])
    .filter((t): t is string => typeof t === "string")
    .map(normalizeTopic)
    .filter((t): t is { key: string; display: string } => t !== null)
    .slice(0, 5);
  if (!topics.length) {
    await send({ type: "error", message: "Add at least one topic (2–48 letters or numbers)." });
    return;
  }

  const now = Date.now();
  await env.DB.batch(
    topics.map((t) =>
      env.DB.prepare(
        `INSERT INTO topics (topic, level, display, last_requested) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (topic, level) DO UPDATE SET last_requested = excluded.last_requested`,
      ).bind(t.key, level, t.display, now),
    ),
  );
  const blocked = await env.DB.prepare(
    `SELECT topic FROM topics WHERE level = ?1 AND blocked = 1 AND topic IN (${topics.map((_, i) => `?${i + 2}`).join(",")})`,
  )
    .bind(level, ...topics.map((t) => t.key))
    .all<{ topic: string }>();
  const usable = topics.filter((t) => !blocked.results.some((b) => b.topic === t.key));
  if (!usable.length) {
    await send({ type: "error", message: "Sharpy can't make questions about these topics. Try different ones." });
    return;
  }

  const perTopic = Math.ceil(count / usable.length);
  const unseenFor = async (key: string) => (await loadBank(env, key, level)).filter((it) => !seen.has(it.id));

  let fresh = await Promise.all(usable.map((t) => unseenFor(t.key)));
  // Generate for (at most two) topics that can't fill their share, in parallel.
  const short = usable
    .map((t, i) => ({ t, have: fresh[i].length }))
    .filter((x) => x.have < perTopic)
    .sort((a, b) => a.have - b.have)
    .slice(0, 2);
  if (short.length) {
    const problem = await quotaProblem(env, install);
    if (problem) {
      if (fresh.every((f) => f.length === 0)) {
        await send({ type: "error", message: problem });
        return;
      }
    } else {
      const progress = (message: string) => void send({ type: "progress", message });
      const results = await Promise.allSettled(
        short.map(async ({ t }) => {
          if (await refillTopic(env, install, t.key, t.display, level, progress)) return;
          // Someone else is generating this topic; wait for their items to land.
          progress(`Another learner is generating “${t.display}”. Hang tight…`);
          for (let i = 0; i < 30; i++) {
            await new Promise((r) => setTimeout(r, 5000));
            if ((await unseenFor(t.key)).length >= perTopic) return;
          }
        }),
      );
      for (const r of results) {
        if (r.status === "rejected") {
          console.error("generation failed", r.reason);
          const shown =
            r.reason instanceof GenerationError
              ? r.reason.message
              : r.reason instanceof RefusedError
                ? "Sharpy can't make questions about one of your topics."
                : "Sharpy's question writer had a hiccup with one topic.";
          await send({ type: "progress", message: shown });
        }
      }
      fresh = await Promise.all(usable.map((t) => unseenFor(t.key)));
    }
  }

  // Oldest unseen first so banks are worked through in order; interleave topics,
  // letting a well-stocked topic cover for one that came up short.
  const queues = fresh.map((f) => [...f].reverse());
  const items: QuizItem[] = [];
  for (let round = 0; items.length < count && queues.some((q) => q.length); round++) {
    for (const q of queues) {
      const next = q.shift();
      if (next && items.length < count) items.push(next);
    }
  }

  // Ask the hourly job to top up banks that are now running low for this learner.
  const low = usable.filter((_, i) => fresh[i].length - perTopic < perTopic * 2);
  if (low.length) {
    await env.DB.batch(
      low.map((t) =>
        env.DB.prepare("UPDATE topics SET needs_refill = 1 WHERE topic = ?1 AND level = ?2").bind(t.key, level),
      ),
    );
  }

  if (!items.length) {
    await send({ type: "error", message: "Couldn't prepare questions right now. Please try again in a few minutes." });
    return;
  }
  await send({ type: "session", items });
}

/** Hourly job: refill up to `limit` banks that recent sessions flagged as low. */
export async function refillLowBanks(env: Env, limit: number) {
  const rows = await env.DB.prepare(
    `SELECT topic, level, display FROM topics
     WHERE needs_refill = 1 AND blocked = 0 AND last_requested > ?1
     ORDER BY last_requested DESC LIMIT ?2`,
  )
    .bind(Date.now() - 3 * 86_400_000, limit)
    .all<{ topic: string; level: Level; display: string }>();
  for (const row of rows.results) {
    if (await quotaProblem(env, "cron")) return;
    try {
      await refillTopic(env, "cron", row.topic, row.display, row.level, () => {});
    } catch (err) {
      console.error("refill failed", row.topic, err);
    }
  }
}

/** POST /v1/report — two independent reports retire an item for everyone. */
export async function reportItem(env: Env, install: string, body: { itemId?: unknown; reason?: unknown; note?: unknown }) {
  const itemId = typeof body.itemId === "string" ? body.itemId.slice(0, 32) : "";
  const reason = typeof body.reason === "string" ? body.reason.slice(0, 40) : "other";
  const note = typeof body.note === "string" ? body.note.slice(0, 500) : null;
  if (!itemId) return;
  const res = await env.DB.prepare(
    "INSERT OR IGNORE INTO reports (item_id, install, reason, note, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
  )
    .bind(itemId, install, reason, note, Date.now())
    .run();
  if (res.meta.changes === 1) {
    await env.DB.prepare(
      "UPDATE items SET reports = reports + 1, retired = CASE WHEN reports + 1 >= 2 THEN 1 ELSE retired END WHERE id = ?1",
    )
      .bind(itemId)
      .run();
  }
}
