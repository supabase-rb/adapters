# `server-rb` — Product Requirements Document

**Status:** Draft
**Owner:** TBD
**Last updated:** 2026-05-29
**Reference:** [`server-ts`](../server-ts) v1.1.0 — feature parity target
**Client dependency:** [`supabase-rb`](../supabase-rb) — local Ruby client

---

## 1. Overview

`server-rb` is a Ruby gem that brings the server-side primitives of [`@supabase/server`](../server-ts) (TypeScript) to Ruby web applications. It handles environment resolution, credential extraction, JWT verification, and per-request Supabase client creation — so application code can focus on business logic instead of auth boilerplate.

It ships **framework-agnostic core primitives** plus a **first-class adapter for Rails**, mirroring how `server-ts` ships adapters for Hono, H3, Elysia, and NestJS.

The Ruby client used internally is [`supabase-rb`](../supabase-rb).

---

## 2. Goals & non-goals

### Goals

- **Feature parity** with `server-ts` v1.1.0 public API (auth modes, env var contract, error semantics, context shape).
- **Idiomatic Ruby** API — `keyword args`, `Result`-like return tuples, `raise` for unrecoverable errors, lowercase snake_case throughout.
- **One framework adapter** at launch: Rails (≥ 7.1).
- **Thread-safe** — works under Puma (multi-threaded) without per-thread setup.
- **No global state** — context lives in the Rack request, not class variables.
- **Single gem with optional requires** for adapters, mirroring `supabase-rb`'s monorepo layout.

### Non-goals

- Sinatra, Roda, Grape, Hanami, or other Rack frameworks at launch (community adapters welcome later).
- Async I/O (`async-http`) at launch. Sync-only; `supabase-rb` is sync.
- Replacing `supabase-rb` — `server-rb` consumes it, never reimplements it.
- A CLI, generators, or scaffolding tools.
- Cookie-based session refresh (`@supabase/ssr` equivalent). Out of scope; `server-rb` is for **stateless** API auth.

---

## 3. Target users

- Ruby teams running a Supabase project who need a server with RLS-aware queries.
- Mobile/SPA backends written in Rails that already use Supabase auth on the client and need server-side verification of the same JWTs.
- Service-to-service callers that authenticate with a secret API key.

---

## 4. User stories

| # | As a... | I want to... | So that... |
|---|---|---|---|
| US-1 | Rails dev | add `before_action :verify_supabase_auth` to a controller | I can require a valid Supabase JWT on a route |
| US-2 | Rails dev | access `supabase_context.supabase` in any controller action | I can run RLS-aware queries scoped to the caller |
| US-3 | Rails dev | configure `SUPABASE_URL` / keys / JWKS via env vars | I don't have to wire anything in code |
| US-4 | Rails dev | switch between `:user`, `:publishable`, `:secret`, `:none` auth modes per route | I can mix end-user and service auth without duplicating code |
| US-5 | Rails dev | reach `supabase_admin` for privileged operations | I can bypass RLS in trusted code paths |
| US-6 | Platform team | run multiple named publishable / secret keys | I can support mobile + web + server with distinct keys |

---

## 5. Functional requirements

### 5.1 Core module (`Supabase::Server`)

Pure-Ruby, framework-agnostic. All requirements below must be satisfied without depending on Rack or Rails.

#### FR-1: Environment resolution (`Supabase::Server::Env.resolve`)

Parse and validate the following env vars, returning a `SupabaseEnv` struct:

| Env var | Required | Maps to |
|---|---|---|
| `SUPABASE_URL` | Yes | `env.url` |
| `SUPABASE_PUBLISHABLE_KEY` | One of the two | `env.publishable_keys = { "default" => value }` |
| `SUPABASE_PUBLISHABLE_KEYS` | One of the two | `env.publishable_keys` (parsed JSON object) |
| `SUPABASE_SECRET_KEY` | One of the two | `env.secret_keys = { "default" => value }` |
| `SUPABASE_SECRET_KEYS` | One of the two | `env.secret_keys` (parsed JSON object) |
| `SUPABASE_JWKS` | One of (optional) | `env.jwks` (inline `JsonWebKeySet`) |
| `SUPABASE_JWKS_URL` | One of (optional) | `env.jwks` (URI; HTTPS-only except loopback hosts) |

**Validation:**
- `SUPABASE_URL` missing → raise `Supabase::Server::EnvError` (code `MISSING_SUPABASE_URL`).
- Malformed JSON in `*_KEYS` env var → resolve to empty hash (do **not** fall through to the single-key var); log warning.
- `SUPABASE_JWKS_URL` with non-`https://` scheme on a non-loopback host → reject (`nil`).
- Each `_KEYS` env var is authoritative when set (matches server-ts behavior).

#### FR-2: Credential extraction (`Supabase::Server::Core.extract_credentials(headers)`)

Given a hash-like headers object, return a `Credentials` struct:
- `token`: stripped bearer token from `Authorization: Bearer <token>` (case-insensitive scheme match), else `nil`.
- `apikey`: value of the `apikey` header (case-insensitive lookup), else `nil`.

#### FR-3: Credential verification (`Supabase::Server::Core.verify_credentials`)

Given credentials and a list of auth modes, return `AuthResult` or raise `AuthError`. Behavior must match `server-ts`:

- **Modes:** `:none`, `:publishable`, `:secret`, `:user`; also `"publishable:<name>"`, `"secret:<name>"`, `"publishable:*"`, `"secret:*"`.
- **First-match wins** on the mode list.
- A mode is **tried only when its credential is present**.
- A present-but-invalid JWT **short-circuits** the chain with `InvalidCredentialsError` (does not fall through to subsequent modes).
- API key comparison uses `OpenSSL.fixed_length_secure_compare` (constant-time).
- `:user` mode requires JWKS configured; if not, raise `AuthError` with status 500.

#### FR-4: JWT verification (`Supabase::Server::JWT.verify(token, env:)`)

- Verify signature against `env.jwks` (inline) or fetch+cache from `env.jwks` (URL).
- Verify `exp`, `iat` (with leeway of 30s, matching `jose` defaults).
- Support algorithms: `RS256`, `ES256`, `HS256` (the three Supabase uses).
- Return `{ user_claims: UserClaims, jwt_claims: JWTClaims }`.
- **Remote JWKS caching:** thread-safe, in-memory, keyed by URL, TTL = 10 minutes, with cooldown on miss (don't re-fetch on every invalid token).

#### FR-5: Context client creation (`Supabase::Server::Core.create_context_client`)

Return a `Supabase::Client` (from `supabase-rb`) configured with:
- The matched publishable key (named or `default` fallback).
- If `auth.token` present → inject `Authorization: Bearer <token>` into client headers so PostgREST/Storage/Realtime requests run as the caller.
- Force-disable session persistence and auto-refresh (server-safe defaults).

#### FR-6: Admin client creation (`Supabase::Server::Core.create_admin_client`)

Same as FR-5 but uses the matched secret (service-role) key. **Never** injects a user token.

#### FR-7: Context assembly (`Supabase::Server.create_context(request, **opts)`)

Top-level entry point. Returns a result tuple:

```ruby
ctx, error = Supabase::Server.create_context(request, auth: :user)
return render_error(error) if error
ctx.supabase.from(:games).select.execute
```

`ctx` is a `SupabaseContext` with:
- `supabase` — context client (RLS applies).
- `supabase_admin` — admin client (RLS bypassed).
- `user_claims` — normalized identity, or `nil`.
- `jwt_claims` — raw JWT payload, or `nil`.
- `auth_mode` — `:none | :publishable | :secret | :user`.
- `auth_key_name` — matched key name, or `nil`.

#### FR-8: Error types

- `Supabase::Server::EnvError` (status 500; codes: `MISSING_SUPABASE_URL`, `MISSING_PUBLISHABLE_KEY`, `MISSING_DEFAULT_PUBLISHABLE_KEY`, `MISSING_SECRET_KEY`, `MISSING_DEFAULT_SECRET_KEY`).
- `Supabase::Server::AuthError` (status 401 or 500; codes: `AUTH_ERROR`, `INVALID_CREDENTIALS`, `CREATE_SUPABASE_CLIENT_ERROR`).
- Both expose `#status` (Integer), `#code` (String), `#message` (String). Inherit from `StandardError`.

#### FR-9: CORS (`Supabase::Server::CORS`)

- Default: emits `supabase-js`-equivalent CORS headers (`Access-Control-Allow-Origin: *`, etc.).
- Disabled when adapter opts out (Rails passes `cors: false` — the framework has its own CORS stack).
- Custom hash supported.

### 5.2 Rails adapter (`Supabase::Server::Rails`)

#### FR-10: Rack middleware

```ruby
# config/application.rb
config.middleware.use Supabase::Server::Rails::Middleware, auth: :user
```

- Resolves context on every request that matches.
- On success, stashes `SupabaseContext` in `request.env["supabase.context"]`.
- On failure, short-circuits with JSON error response (`status` from `AuthError`).

#### FR-11: Controller concern

```ruby
class GamesController < ApplicationController
  include Supabase::Server::Rails::Controller

  before_action :verify_supabase_auth, only: [:index, :create]

  def index
    render json: supabase_context.supabase.from(:games).select.execute
  end
end
```

- `supabase_context` helper exposes the context.
- `verify_supabase_auth` raises if absent → handled by Rails into 401.
- Per-route override: `before_action -> { verify_supabase_auth(auth: :secret) }`.

---

## 6. Non-functional requirements

### NFR-1: Thread safety

- Puma multi-thread mode is the primary target.
- No mutable class-level state in the request path.
- JWKS cache uses `Mutex` for reads/writes.
- Context lives in Rack env (per-request, per-thread).

### NFR-2: Performance budget

- Cold-path (first request, JWKS fetch needed): < 50 ms overhead vs. raw Supabase call.
- Hot-path (JWKS cached, JWT valid): < 2 ms verification overhead on a 2024-vintage laptop.
- No allocation churn — reuse `Supabase::Client` instances per `(key_name, token)` if profiling justifies it. **Optimization deferred until measured.**

### NFR-3: Ruby compatibility

- Ruby ≥ 3.0 (matches `supabase-rb`).
- Frozen string literals throughout.
- No `eval`, no `method_missing`, no monkey-patches outside of opt-in concerns.

### NFR-4: Security

- All API key comparisons constant-time.
- JWT verification uses signature checks; never trust `alg: "none"`.
- Reject non-HTTPS JWKS URLs on non-loopback hosts.
- Default error messages do not leak which credential failed (return generic "Invalid credentials").

### NFR-5: Observability

- Errors carry `code` for log filtering.
- Optional `Supabase::Server.logger = …` hook; default is `nil` (no logging).
- No telemetry, no phone-home.

---

## 7. Public API (Ruby surface)

### 7.1 Core

```ruby
# Top-level context creation (mirrors createSupabaseContext)
ctx, err = Supabase::Server.create_context(
  request,                # Rack::Request, Hash, or anything with #headers/#env
  auth: :user,            # Symbol, String, or Array
  env: { url: "..." },    # Optional override
  supabase_options: {}    # Forwarded to Supabase::Client
)

# Individual primitives (for advanced use)
Supabase::Server::Env.resolve(overrides = {})
Supabase::Server::Core.extract_credentials(headers)
Supabase::Server::Core.verify_credentials(credentials, auth:, env:)
Supabase::Server::JWT.verify(token, env:)
Supabase::Server::Core.create_context_client(auth:, env:, supabase_options:)
Supabase::Server::Core.create_admin_client(auth:, env:, supabase_options:)

# Errors
Supabase::Server::EnvError    # < StandardError, #status, #code
Supabase::Server::AuthError   # < StandardError, #status, #code
```

### 7.2 Rails

```ruby
require "supabase/server/rails"

# Middleware
config.middleware.use Supabase::Server::Rails::Middleware, auth: :user

# Controller mixin
class ApplicationController < ActionController::API
  include Supabase::Server::Rails::Controller
end
```

---

## 8. Dependencies

### Runtime

- `supabase` (from `supabase-rb`, ≥ current version) — umbrella client.
- `supabase-auth` (from `supabase-rb`) — auth helpers, `getUser` equivalent.
- `json-jwt` — JWT verification + remote JWKS endpoint support. **Chosen over `ruby-jwt`** because it ships `JSON::JWK::Set#find` and HTTP fetch out of the box.
- `faraday` — HTTP client for JWKS fetch (already a transitive dep of `supabase-rb`).
- No new dep on Rack — adapters declare framework as a runtime dep.

### Adapter peer-deps

- Rails adapter: `rails ≥ 7.1` (or `actionpack ≥ 7.1` + `railties ≥ 7.1`).
- Declared as a **soft** dep (`add_development_dependency` only); the require fails fast with a clear message if the framework isn't present.

### Dev / test

- `rspec`, `simplecov`, `rack-test`, `rails` — see `Gemfile`.
- `webmock` — stub remote JWKS fetches.
- `vcr` (optional) — record real Supabase responses for integration tests.

---

## 9. Package structure

Single gem with optional requires, mirroring `supabase-rb`:

```
server-rb/
├── PRD.md                              # this file
├── README.md
├── CHANGELOG.md
├── LICENSE
├── Gemfile
├── supabase-server.gemspec             # the gem
├── lib/
│   ├── supabase/server.rb              # public entry (`require "supabase/server"`)
│   └── supabase/server/
│       ├── version.rb
│       ├── env.rb                      # FR-1
│       ├── core.rb                     # FR-2, 3, 5, 6
│       ├── jwt.rb                      # FR-4
│       ├── jwks_cache.rb               # remote JWKS caching
│       ├── context.rb                  # FR-7 result struct
│       ├── errors.rb                   # FR-8
│       ├── cors.rb                     # FR-9
│       ├── rails.rb                    # `require "supabase/server/rails"` → loads adapter
│       └── rails/
│           ├── middleware.rb           # FR-10
│           └── controller.rb           # FR-11
├── spec/
│   ├── spec_helper.rb
│   ├── supabase/server/
│   │   ├── env_spec.rb
│   │   ├── core_spec.rb
│   │   ├── jwt_spec.rb
│   │   ├── jwks_cache_spec.rb
│   │   ├── context_spec.rb
│   │   ├── errors_spec.rb
│   │   └── cors_spec.rb
│   ├── adapters/
│   │   └── rails_spec.rb               # integration: dummy Rails app
│   └── fixtures/
│       ├── jwks.json
│       └── tokens/                     # pre-signed JWTs
└── docs/
    ├── adapters/
    │   └── rails.md
    └── migration-from-server-ts.md
```

---

## 10. Testing strategy

### 10.1 Unit tests

Mirror `server-ts/src/**/*.test.ts` file-by-file. Every primitive (env, extract, verify, JWT, JWKS cache, client creation, errors, CORS) gets its own spec.

### 10.2 Adapter integration tests

- **Rails:** boot a minimal `rails new`-style app inside `spec/adapters/rails_spec.rb`, mount middleware, hit it with `rack-test`. Cover: all four auth modes, named keys, error responses, per-route override via `before_action`.

### 10.3 Coverage targets

- ≥ 95 % line coverage on `lib/supabase/server/core.rb`, `env.rb`, `jwt.rb`.
- ≥ 90 % on adapters.
- SimpleCov enforced in CI.

### 10.4 Cross-impl conformance

A `spec/conformance/` suite mirrors the auth-mode matrix tested by `server-ts/src/core/verify-credentials.test.ts` so behavioral parity is provable, not just claimed.

---

## 11. Release plan

### Phase 0 — Setup (½ week)

- Gemspec, Gemfile, RSpec, SimpleCov, RuboCop, CI (GitHub Actions matrix on Ruby 3.0/3.2/3.3, Rails 7.1/7.2).
- README skeleton, LICENSE (MIT, matches `server-ts`).

### Phase 1 — Core (1 week)

- FR-1 env resolution.
- FR-2 credential extraction.
- FR-3 verify_credentials.
- FR-4 JWT verification + JWKS cache.
- FR-5, FR-6 client creation.
- FR-7 create_context.
- FR-8 errors, FR-9 CORS.
- **Milestone:** all `server-ts/src/core/*.test.ts` analogs pass.

### Phase 2 — Rails adapter (½ week)

- Middleware + controller concern.
- Dummy Rails app integration tests.

### Phase 3 — Docs & polish (½ week)

- README.
- `docs/adapters/rails.md` (structure mirrors `server-ts/docs/adapters/hono.md`).
- `docs/migration-from-server-ts.md` for users porting from a Node service.
- CHANGELOG.

### Phase 4 — `0.1.0` release

- Publish to RubyGems alongside `supabase-auth`.
- Announce in `supabase-rb` README.

**Estimated total: 2.5 – 3 weeks of focused work.**

---

## 12. Open questions

| # | Question | Owner | Resolve by |
|---|---|---|---|
| OQ-1 | Confirm `json-jwt` over `ruby-jwt` after a head-to-head spike on remote-JWKS support. | TBD | Phase 1, day 1 |
| OQ-2 | Should context tuple be `[ctx, err]` (Go-style) or a `Result` object with `.success?` / `.failure?`? Affects every call site. | TBD | Before Phase 1 |
| OQ-3 | Should `Supabase::Server::Rails::Controller` raise `ActionController::ParameterMissing`-equivalent or render a JSON 401 directly? Rails-idiomatic vs. matching `server-ts` semantics. | TBD | Phase 2, day 1 |
| OQ-4 | Should the adapter live in the same gem (current plan) or be a separate gem (`supabase-server-rails`)? Current plan: single gem, optional requires — matches `server-ts`. | TBD | Before Phase 0 |
| OQ-5 | Cookie-based session auth (Supabase SSR equivalent) — defer to v0.2, or out of scope entirely? | TBD | Post-launch |

---

## 13. Out-of-scope (explicitly)

- Sinatra / Roda / Grape / Hanami / Cuba adapters — community contributions welcome post-v0.1.
- Async I/O (`async-http-faraday`) — sync only.
- Cookie session refresh / `@supabase/ssr` parity.
- Generators (`rails g supabase:install`) — not at v0.1.
- A built-in PostgREST query DSL — that's `supabase-rb`'s job.

---

## 14. Success criteria

`server-rb` v0.1 ships when **all** of the following are true:

- [ ] All FR-1 through FR-11 implemented and tested.
- [ ] Conformance suite mirrors `server-ts/src/core/verify-credentials.test.ts` and passes.
- [ ] Rails dummy app demonstrates US-1, US-2, US-4, US-5.
- [ ] README quickstart works end-to-end against a real Supabase project.
- [ ] CI green on Ruby 3.0 / 3.2 / 3.3 × Rails 7.1 / 7.2.
- [ ] ≥ 90 % line coverage overall, ≥ 95 % on core.
- [ ] Gem published to RubyGems as `supabase-server`.
