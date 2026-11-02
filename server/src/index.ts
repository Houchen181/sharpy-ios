import { ensureDiscover, latestDiscover } from "./discover";
import { type Env, today } from "./env";
import { refillLowBanks, reportItem, sessionStream } from "./quiz";
import { updatesStream } from "./updates";

type Send = (line: Record<string, unknown>) => Promise<void>;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

/**
 * Streams newline-delimited JSON. Claude calls can take a minute or more, so a
 * ping goes out every 15 s to keep the connection from idling out.
 */
function ndjson(ctx: ExecutionContext, work: (send: Send) => Promise<void>): Response {
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const encoder = new TextEncoder();
  let open = true;
  const send: Send = async (line) => {
    if (!open) return;
    try {
      await writer.write(encoder.encode(JSON.stringify(line) + "\n"));
    } catch {
      open = false; // the app went away; let the work finish so its results are saved
    }
  };
  const ping = setInterval(() => void send({ type: "ping" }), 15_000);
  const run = (async () => {
    try {
      await work(send);
    } catch (err) {
      console.error("stream failed", err);
      await send({ type: "error", message: "Something went wrong on Sharpy's side. Please try again." });
    } finally {
      clearInterval(ping);
      open = false;
      await writer.close().catch(() => {});
    }
  })();
  ctx.waitUntil(run);
  return new Response(readable, {
    headers: { "Content-Type": "application/x-ndjson", "Cache-Control": "no-store" },
  });
}

// USD per million tokens (input, output) for the usage report.
const PRICES: Record<string, [number, number]> = {
  "claude-opus-5-5": [4, 20],
  "claude-sonnet-5-5": [2, 10],
  "claude-haiku-5-5": [0.1, 0.5],
};

async function usageReport(env: Env): Promise<Response> {
  const rows = await env.DB.prepare(
    "SELECT day, generations, input_tokens, output_tokens, searches FROM usage WHERE subject = 'global' ORDER BY day DESC LIMIT 30",
  ).all<{ day: string; generations: number; input_tokens: number; output_tokens: number; searches: number }>();
  const [pin, pout] = PRICES[env.MODEL] ?? PRICES["claude-opus-5-5"];
  const days = rows.results.map((r) => ({
    ...r,
    estimatedUSD: Math.round(((r.input_tokens * pin + r.output_tokens * pout) / 1e6 + r.searches * 0.01) * 100) / 100,
  }));
  const installs = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM usage WHERE day = ?1 AND subject LIKE 'install:%'",
  )
    .bind(today())
    .first<{ n: number }>();
  return json({ model: env.MODEL, activeInstallsToday: installs?.n ?? 0, days });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;

    if (route === "GET /v1/health") return json({ ok: true, model: env.MODEL });

    if (route === "GET /v1/admin/usage") {
      const auth = request.headers.get("Authorization");
      if (!env.ADMIN_TOKEN || auth !== `Bearer ${env.ADMIN_TOKEN}`) return json({ error: "Not allowed." }, 401);
      return usageReport(env);
    }

    // Each install has a random UUID it keeps in its Keychain; quotas hang off it.
    const install = request.headers.get("X-Sharpy-Install") ?? "";
    if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(install)) {
      return json({ error: "Missing install ID." }, 401);
    }
    const { success } = await env.BURST.limit({ key: install });
    if (!success) return json({ error: "Too many requests. Take a breath and try again in a minute." }, 429);

    const body = async () => {
      try {
        return (await request.json()) as Record<string, unknown>;
      } catch {
        return {};
      }
    };

    switch (route) {
      case "POST /v1/session": {
        const b = await body();
        return ndjson(ctx, (send) => sessionStream(env, install, b, send));
      }
      case "POST /v1/updates": {
        const b = await body();
        return ndjson(ctx, (send) => updatesStream(env, install, b, send));
      }
      case "GET /v1/discover": {
        const date = /^\d{4}-\d{2}-\d{2}$/.test(url.searchParams.get("date") ?? "")
          ? url.searchParams.get("date")!
          : today();
        const feed = (await latestDiscover(env, date)) ?? (await ensureDiscover(env, today()));
        return feed ? json(feed) : json({ error: "Today's cards are still being prepared." }, 503);
      }
      case "POST /v1/report": {
        await reportItem(env, install, await body());
        return json({ ok: true });
      }
      default:
        return json({ error: "Not found." }, 404);
    }
  },

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(
      (async () => {
        try {
          await ensureDiscover(env, today());
        } catch (err) {
          console.error("discover build failed", err);
        }
        await refillLowBanks(env, 3);
      })(),
    );
  },
} satisfies ExportedHandler<Env>;
