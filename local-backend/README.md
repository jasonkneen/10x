# 10x Local Backend

A minimal local stand-in for the 10x backend API proxy. Lets you run the 10x
macOS app fully locally — no hosted backend, no Supabase project, no database.

## What it does

The macOS app talks to a backend at `http://localhost:8000` for Claude
generation and a few supporting endpoints. This server implements that surface
using your own Anthropic API key:

| Endpoint | Behavior |
|---|---|
| `POST /api/v1/builder/claude/stream` | Proxies to the Anthropic Messages API (streaming) |
| `POST /api/v1/builder/claude/count-tokens` | Proxies to Anthropic token counting |
| `POST /api/v1/builder/chat-title` | Short Claude call (falls back to truncating the query) |
| `GET /api/v1/builder/skills` | Empty registry — the app uses its bundled skills |
| `POST /api/v1/builder/scrape-url` | Real fetch + HTML-to-text |
| `POST /api/v1/builder/web-search` | Graceful "unavailable" message |
| `GET /api/v1/billing/*` | Stubbed (payments are disabled in `Development.xcconfig`) |
| anything else | `501` with a clear message |

Projects, messages, and files are persisted locally by the app itself
(`~/Library/Developer/TenXApp/`), so no database is needed.

## Setup

```bash
cd local-backend
pnpm install
cp .env.example .env   # then add your ANTHROPIC_API_KEY
pnpm dev
```

Then build and run the 10x app in Xcode (Debug). On the login screen, click
**Continue locally (no account)** — this DEBUG-only path skips Supabase auth.

## Notes

- The default model is `claude-opus-4-7` (what the app's token counter
  assumes). Override with `TENX_MODEL` in `.env` if your key lacks access.
- `thinking` / `output_config` request fields are forwarded as the app sends
  them; if the API rejects them for your model, the proxy retries once
  without them.
- Not implemented: OpenAI image generation (app icon generation),
  Supabase management OAuth (the "connect Supabase" project integration),
  and Stripe billing. These return clear errors and degrade gracefully.
