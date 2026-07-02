// Local development stand-in for the 10x backend API proxy.
//
// The 10x macOS app expects a backend at http://localhost:8000 that proxies
// Claude requests and serves a handful of supporting endpoints. This server
// implements just enough of that surface to run the app fully locally with
// your own ANTHROPIC_API_KEY. No database is required — projects and messages
// are persisted locally by the app itself (LocalProjectStore).
//
// Endpoints implemented:
//   POST /api/v1/builder/claude/stream        → Anthropic /v1/messages (streaming, NDJSON passthrough)
//   POST /api/v1/builder/claude/count-tokens  → Anthropic /v1/messages/count_tokens
//   POST /api/v1/builder/chat-title           → short Claude call (falls back to truncation)
//   GET  /api/v1/builder/skills               → empty registry (app falls back to bundled skills)
//   POST /api/v1/builder/web-search           → graceful "unavailable" result
//   POST /api/v1/builder/scrape-url           → real fetch + HTML-to-text
//   GET  /api/v1/billing/bootstrap            → stubbed credits so billing UI stays quiet
//   GET  /api/v1/billing/invoices             → empty list
//   everything else                           → 501 with a clear message

import { readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { serve } from '@hono/node-server'
import { Hono } from 'hono'

// --- tiny .env loader (no dependency) ---------------------------------------

const rootDir = join(dirname(fileURLToPath(import.meta.url)), '..')
const envPath = join(rootDir, '.env')
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/)
    if (!match) continue
    const [, key, raw] = match
    if (process.env[key] !== undefined) continue
    process.env[key] = raw.replace(/^["']|["']$/g, '')
  }
}

// --- config ------------------------------------------------------------------

const PORT = Number(process.env.PORT ?? 8000)
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY ?? ''
const ANTHROPIC_BASE_URL = process.env.ANTHROPIC_BASE_URL ?? 'https://api.anthropic.com'
const ANTHROPIC_VERSION = process.env.ANTHROPIC_VERSION ?? '2023-06-01'
// The production backend chooses the model server-side; the app never sends one
// for streaming. The app's own token counter assumes claude-opus-4-7, so that
// is the default here. Override with TENX_MODEL if your key lacks access.
const MODEL = process.env.TENX_MODEL ?? 'claude-opus-4-7'
const TITLE_MODEL = process.env.TENX_TITLE_MODEL ?? MODEL

if (!ANTHROPIC_API_KEY) {
  console.error('[local-backend] ANTHROPIC_API_KEY is not set. Copy .env.example to .env and add your key.')
}

// Fields the real backend consumes for billing/telemetry; never forwarded.
const BACKEND_ONLY_FIELDS = [
  'idempotency_key',
  'billing_group_id',
  'billing_message_preview',
  'project_id',
  'session_id',
] as const

type Json = Record<string, unknown>

const anthropicHeaders = {
  'content-type': 'application/json',
  'x-api-key': ANTHROPIC_API_KEY,
  'anthropic-version': ANTHROPIC_VERSION,
}

function stripBackendFields(body: Json): Json {
  const result = { ...body }
  for (const field of BACKEND_ONLY_FIELDS) delete result[field]
  return result
}

// The app sends a top-level `cache_control`; the real API wants it on a content
// block. Apply it to the system prompt so prompt caching still works.
function applyCacheControl(payload: Json): Json {
  const cacheControl = payload.cache_control
  delete payload.cache_control
  if (cacheControl && typeof payload.system === 'string') {
    payload.system = [{ type: 'text', text: payload.system, cache_control: cacheControl }]
  }
  return payload
}

// `thinking` / `output_config` come from the app as the production backend
// expects them. If the Anthropic API rejects them for the configured model,
// retry once without them rather than failing the whole request.
async function postWithParamFallback(url: string, payload: Json): Promise<Response> {
  const response = await fetch(url, {
    method: 'POST',
    headers: anthropicHeaders,
    body: JSON.stringify(payload),
  })
  if (response.status !== 400) return response

  const retryPayload = { ...payload }
  delete retryPayload.thinking
  delete retryPayload.output_config
  if (JSON.stringify(retryPayload) === JSON.stringify(payload)) return response

  const errorBody = await response.text()
  console.warn(`[local-backend] Anthropic 400, retrying without thinking/output_config: ${errorBody.slice(0, 300)}`)
  return fetch(url, {
    method: 'POST',
    headers: anthropicHeaders,
    body: JSON.stringify(retryPayload),
  })
}

async function upstreamErrorDetail(response: Response): Promise<string> {
  const text = await response.text()
  try {
    const parsed = JSON.parse(text)
    return parsed?.error?.message ?? parsed?.message ?? text
  } catch {
    return text || `Anthropic returned status ${response.status}`
  }
}

// Convert Anthropic SSE into the NDJSON lines the app parses, remapping error
// events from {type:"error",error:{message}} to the {type:"error",message}
// shape GenerationService expects.
function sseToNdjson(upstream: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder()
  const encoder = new TextEncoder()
  let buffer = ''

  return upstream.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        buffer += decoder.decode(chunk, { stream: true })
        let newlineIndex: number
        while ((newlineIndex = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newlineIndex).replace(/\r$/, '')
          buffer = buffer.slice(newlineIndex + 1)
          if (!line.startsWith('data:')) continue
          const data = line.slice(5).trim()
          if (!data || data === '[DONE]') continue
          try {
            const event = JSON.parse(data)
            const out = event?.type === 'error'
              ? { type: 'error', message: event.error?.message ?? 'Upstream error' }
              : event
            controller.enqueue(encoder.encode(JSON.stringify(out) + '\n'))
          } catch {
            // Ignore partial/unparseable SSE payloads.
          }
        }
      },
    }),
  )
}

// --- app ----------------------------------------------------------------------

const app = new Hono()

app.use('*', async (c, next) => {
  await next()
  console.log(`[local-backend] ${c.req.method} ${c.req.path} → ${c.res.status}`)
})

app.post('/api/v1/builder/claude/stream', async (c) => {
  if (!ANTHROPIC_API_KEY) {
    return c.json({ detail: 'ANTHROPIC_API_KEY is not configured in local-backend/.env' }, 500)
  }

  const body = stripBackendFields(await c.req.json<Json>())
  const payload = applyCacheControl({
    model: MODEL,
    stream: true,
    ...body,
  })

  const response = await postWithParamFallback(`${ANTHROPIC_BASE_URL}/v1/messages`, payload)
  if (!response.ok || !response.body) {
    const detail = await upstreamErrorDetail(response)
    console.error(`[local-backend] claude/stream upstream error ${response.status}: ${detail}`)
    return c.json({ detail }, response.status as 400)
  }

  return new Response(sseToNdjson(response.body), {
    status: 200,
    headers: { 'content-type': 'application/x-ndjson' },
  })
})

app.post('/api/v1/builder/claude/count-tokens', async (c) => {
  if (!ANTHROPIC_API_KEY) {
    return c.json({ detail: 'ANTHROPIC_API_KEY is not configured in local-backend/.env' }, 500)
  }

  const body = stripBackendFields(await c.req.json<Json>())
  delete body.cache_control
  delete body.output_config
  const payload: Json = { model: MODEL, ...body }

  const response = await postWithParamFallback(`${ANTHROPIC_BASE_URL}/v1/messages/count_tokens`, payload)
  if (!response.ok) {
    const detail = await upstreamErrorDetail(response)
    return c.json({ detail }, response.status as 400)
  }
  return c.json(await response.json())
})

app.post('/api/v1/builder/chat-title', async (c) => {
  const body = await c.req.json<{ user_query?: string; project_name?: string }>()
  const query = (body.user_query ?? '').trim()
  const fallbackTitle = query.length > 40 ? `${query.slice(0, 40).trimEnd()}…` : query || 'New Chat'

  if (!ANTHROPIC_API_KEY) return c.json({ title: fallbackTitle })

  try {
    const response = await fetch(`${ANTHROPIC_BASE_URL}/v1/messages`, {
      method: 'POST',
      headers: anthropicHeaders,
      body: JSON.stringify({
        model: TITLE_MODEL,
        max_tokens: 32,
        system: 'Generate a concise 2-5 word title for a chat in an iOS app builder. Reply with the title only — no quotes, no punctuation at the end.',
        messages: [{
          role: 'user',
          content: `Project: ${body.project_name ?? 'Untitled'}\nFirst message: ${query.slice(0, 500)}`,
        }],
      }),
    })
    if (!response.ok) return c.json({ title: fallbackTitle })
    const result = await response.json() as { content?: Array<{ type: string; text?: string }> }
    const title = result.content?.find((block) => block.type === 'text')?.text?.trim()
    return c.json({ title: title || fallbackTitle })
  } catch {
    return c.json({ title: fallbackTitle })
  }
})

app.get('/api/v1/builder/skills', (c) => c.json({ skills: [] }))
app.get('/api/v1/builder/skills/:name', (c) =>
  c.json({ detail: `Skill '${c.req.param('name')}' is not available in the local backend.` }, 404))

app.post('/api/v1/builder/web-search', (c) =>
  c.json({ result: 'Web search is not available in the local development backend. Rely on existing knowledge or ask the user for the information you need.' }))

app.post('/api/v1/builder/scrape-url', async (c) => {
  const { url } = await c.req.json<{ url?: string }>()
  if (!url) return c.json({ result: 'URL scrape failed: no URL provided.' })

  try {
    const response = await fetch(url, {
      signal: AbortSignal.timeout(15_000),
      headers: { 'user-agent': 'tenx-local-backend/0.1' },
      redirect: 'follow',
    })
    if (!response.ok) return c.json({ result: `URL scrape failed: HTTP ${response.status}.` })

    const html = await response.text()
    const text = html
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&#39;|&apos;/g, "'")
      .replace(/&quot;/g, '"')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 20_000)
    return c.json({ result: text || 'No page contents found.' })
  } catch (error) {
    return c.json({ result: `URL scrape failed: ${error instanceof Error ? error.message : String(error)}` })
  }
})

// --- billing stubs (keeps the billing UI quiet; payments are disabled in
// Development.xcconfig, so no checkout flow ever runs) -------------------------

app.get('/api/v1/billing/bootstrap', (c) =>
  c.json({
    summary: {
      total_credits: 999999,
      daily_used: 0,
      daily_limit: null,
      daily_remaining: null,
      subscription: null,
      plan: null,
      current_subscription: null,
      balances: [],
      latest_usage: null,
      billing_customer: null,
      payment_method: {
        has_customer: false,
        has_payment_method: false,
        stripe_customer_id: null,
        default_payment_method_id: null,
        brand: null,
        last4: null,
        exp_month: null,
        exp_year: null,
        funding: null,
        country: null,
        updated_at: null,
      },
      promo: {
        enabled: false,
        claim_method: 'none',
        requires_phone_verification: false,
        phone_verified: false,
        phone_last4: null,
        signup_bonus_amount: 0,
        signup_bonus_credit_type_code: 'promo',
        signup_bonus_claimed: false,
        signup_bonus_claimed_at: null,
        signup_bonus_eligible: false,
        phone_verification_provider: null,
        claim_once_per_user: true,
        claim_once_per_device: true,
        subscription_multiplier: 1,
        subscription_offer_active: false,
        subscription_offer_duration_periods: null,
        apply_to_paid_subscriptions: false,
        apply_to_credit_packs: false,
        apply_to_signup_bonus: false,
      },
    },
    history: { usage_logs: [], credit_events: [] },
    catalog: { current_plan_id: null, subscriptions: [], credit_packs: [] },
  }))

app.get('/api/v1/billing/invoices', (c) => c.json({ invoices: [] }))

// --- everything else -----------------------------------------------------------

app.all('/api/*', (c) => {
  console.warn(`[local-backend] Unimplemented endpoint: ${c.req.method} ${c.req.path}`)
  return c.json({ detail: `${c.req.path} is not implemented in the local development backend.` }, 501)
})

serve({ fetch: app.fetch, port: PORT }, (info) => {
  console.log(`[local-backend] 10x local backend listening on http://localhost:${info.port}`)
  console.log(`[local-backend] Model: ${MODEL} (override with TENX_MODEL)`)
  console.log(`[local-backend] Anthropic key: ${ANTHROPIC_API_KEY ? 'configured' : 'MISSING — set it in local-backend/.env'}`)
})
