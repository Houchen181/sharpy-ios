# Sharpy

A daily practice app for staying sharp in the age of AI. You pick your topics; Sharpy
serves a short daily workout of questions researched from trusted sources, with
convincing **wrong** statements (traps) mixed in. Every answer explains itself and
cites the exact excerpt it came from. A second tab, **Discover**, has something new to
learn each day plus summaries of new papers in your fields. Streaks and daily
reminders work like Duolingo's.

- `Sharpy/` — native SwiftUI app (iOS 17+, SwiftData, no third-party packages)
- `server/` — Cloudflare Worker that holds the Claude API key, plus a D1 database
- `.github/workflows/ios.yml` — builds on macOS runners (no Mac needed), simulator screenshots, TestFlight upload

## How content stays honest

**Quiz items** (`server/src/quiz.ts`), built per topic + level and shared by everyone who picks them:

1. **Research.** Claude searches the web, restricted to ~60 trusted domains
   (`server/src/sources.ts`: encyclopedias, journals, .gov/.edu, official docs), and writes one
   `FACT:` line per finding. Only facts carrying an API citation to a trusted page are kept, so
   every URL and quote comes from the search results, not from the model's memory.
2. **Write.** From those numbered facts, Claude writes 10 items: true/false, multiple choice and
   "spot the error", at least 4 of them traps.
3. **Check.** An independent pass answers every item from the evidence alone. Items where it
   disagrees with the key, or the evidence doesn't settle it, are dropped.
4. **Report.** Two learner reports retire an item for everyone.

**Discover cards** (`server/src/discover.ts`) are written from Wikipedia's featured feed,
NASA APOD, Quanta Magazine and a web-searched "field of the day". Each card's quote is checked
to appear word for word in its source. **Field updates** (`server/src/updates.ts`) summarize new
papers from Crossref (or OpenAlex with a key) and arXiv; preprints are labelled.

## Server setup (once)

```bash
cd server
npm install
npx wrangler login                     # opens the browser for your Cloudflare account
npx wrangler d1 create sharpy          # paste the printed database_id into wrangler.toml
npx wrangler d1 migrations apply sharpy --remote
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ADMIN_TOKEN    # any long random string; protects /v1/admin/usage
npx wrangler deploy
```

Optional secrets: `NASA_API_KEY` (free at api.nasa.gov; `DEMO_KEY` is used otherwise) and
`OPENALEX_API_KEY` (free; better paper search than Crossref).

The app reads the Worker URL from `SHARPY_API_BASE_URL` in `project.yml`.

### Cost controls

Every generation is a paid Claude call (`MODEL` in `wrangler.toml`, default `claude-opus-5-5`).
A fresh 10-item batch costs roughly $0.30–0.60; Discover is one build a day for everyone.
Caps in `wrangler.toml`: `DAILY_GENERATION_CAP` for the whole app and
`PER_INSTALL_DAILY_GENERATIONS` per device. Past them, learners get cached questions only.
Check spend with:

```bash
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://sharpy-api.<your-subdomain>.workers.dev/v1/admin/usage
```

Before a public launch, add App Attest so only the real app can call the Worker; today it
relies on per-install and global caps.

## Building the app

CI runs `xcodegen generate` and builds on every push. Manual runs (Actions → iOS → Run
workflow) can capture demo screenshots (`-ui-demo -ui-tab train|answered|discover|profile|onboarding`)
or sign and upload to TestFlight. Signing uses the same 7 secrets as Billow; see
`scripts/signing.sh`.

The icon is drawn by `tools/make_icon.py` (Pillow).
