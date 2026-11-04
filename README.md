# Sharpy

A daily practice app for staying sharp in the age of AI. You pick your topics; Sharpy
serves a short daily workout of questions researched from trusted sources, with
convincing **wrong** statements (traps) mixed in. Every answer explains itself and
cites the exact excerpt it came from. A second tab, **Discover**, has something new to
learn each day plus summaries of new papers in your fields. Streaks and daily
reminders work like Duolingo's.

- `Sharpy/` — native SwiftUI app (iOS 17+, SwiftData, no third-party packages)
- `Sharpy/Engine/` — everything that talks to AI providers and public sources, on the phone
- `.github/workflows/ios.yml` — builds on macOS runners (no Mac needed), simulator screenshots, TestFlight upload

There is no server. Each learner brings their own API key, which stays in the iPhone's Keychain,
and the app calls the provider directly:

| Provider | API | Research |
|---|---|---|
| Anthropic (Claude) | Messages API, `anthropic-version: 2026-10-21` | Claude's web search, limited to trusted sites |
| OpenRouter | OpenAI-style chat completions | Sharpy reads Wikipedia itself |
| OpenCode Zen | Chat completions (Claude models via `/messages`) | Sharpy reads Wikipedia itself |
| Other | Any OpenAI-compatible endpoint, including local servers | Sharpy reads Wikipedia itself |

## How content stays honest

**Quiz items** (`Engine/QuestionWriter.swift`), made in batches of about 10 per topic and level
and kept in an on-device bank (`Engine/QuestionBank.swift`):

1. **Research** (`Engine/Research.swift`). With Claude, the model searches the web restricted to
   ~60 trusted domains (`Engine/TrustedSources.swift`: encyclopedias, journals, .gov/.edu,
   official docs) and writes one `FACT:` line per finding; only facts carrying an API citation to a
   trusted page are kept. With any other model, Sharpy fetches a few Wikipedia articles on the
   topic, the model picks facts and quotes them, and a fact survives only if its quote appears word
   for word in the article. Either way, every quote comes from a real page, not from memory.
2. **Write.** From those numbered facts the model writes 10 items: true/false, single-answer
   multiple choice, "select all that apply" and "spot the error", several of them traps.
   Select-all items are scored all or nothing.
3. **Check.** An independent pass answers every item from the evidence alone. Items where it
   disagrees with the key, or the evidence doesn't settle it, are dropped.
4. **Report.** "Something's wrong" removes an item from the learner's phone and reviews.

New batches are told what the learner already has, so they cover new ground. After a session,
topics with fewer than 8 questions waiting are topped up in the background.

**Discover cards** (`Engine/DiscoverBuilder.swift`) are written once a day from Wikipedia's
featured feed, NASA APOD, Quanta Magazine and a "field of the day", and cached on the phone. Each
card's quote is checked to appear word for word in its source. **Field updates** summarize new
papers from Crossref and arXiv; preprints are labelled.

## Costs

Every batch, Discover build and paper briefing is billed to the learner's own provider account.
The You → AI provider screen shows this month's tokens, web searches and an estimated cost
(from list prices for Claude; OpenRouter reports its own; other providers may not). As a safety
stop against bugs or loops, the app makes at most 12 question batches a day
(`UsageStore.dailyBatchCap`).

## Building the app

CI runs `xcodegen generate` and builds on every push. Manual runs (Actions → iOS → Run
workflow) can capture demo screenshots (`-ui-demo -ui-tab train|answered|discover|profile|onboarding`)
or sign and upload to TestFlight. Signing uses the same 7 secrets as Billow; see
`scripts/signing.sh`.

The icon is drawn by `tools/make_icon.py` (Pillow).

## Intro video

A 3-minute 1920x1080 intro is cut from a scripted UI tour (`SharpyUITests/TourUITests.swift`,
demo data, `-ui-tour` adds realistic research pauses):

1. Actions → iOS → Run workflow → **video**. Download the `tour` artifact (raw.mp4, marks.txt, rec_start.txt).
2. `python tools/make_music.py music.wav --seconds 180` — an original synthesized background track.
3. `python tools/make_intro.py --tour <tour dir> --icon Sharpy/Assets.xcassets/AppIcon.appiconset/icon-1024.png --music music.wav --out marketing/sharpy-intro-1920x1080.mp4`

Captions and cards live at the top of `make_intro.py`; per-step hold lengths decide how long
still screens stay, and are scaled so the cut lands on exactly 3:00.

## Promo film

"Sharpen" is a 2-minute animated story film (its script, `marketing/sharpy-promo-film-script.md`,
lives in the git-ignored marketing folder).
It is drawn in code as a top-down world of flat objects, with no actors or voiceover, and cuts
to the same tour footage for its three app shots. Music and sound effects are synthesized
(`tools/promo_audio.py`).

```bash
python tools/make_promo.py --tour <tour dir> --icon Sharpy/Assets.xcassets/AppIcon.appiconset/icon-1024.png --out marketing/sharpy-promo-1920x1080.mp4
```

`--still 12.5,40` writes single frames as PNGs for checking a shot; `--audio-only` redoes the
soundtrack on the last rendered picture. Scene lengths, dialogue and sound cues are at the top of
`make_promo.py`.
