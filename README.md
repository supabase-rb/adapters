# supabase-server

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Gem](https://img.shields.io/badge/gem-supabase--server-CC342D?logo=rubygems&logoColor=white)](https://rubygems.org/gems/supabase-server)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.0-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)

> **v0.x — Pre-release.** API may change before the `1.0` cut. The Ruby port of [`@supabase/server`](https://github.com/supabase/server); track feature parity in [PRD.md](PRD.md). Found a rough edge? [Open an issue](https://github.com/supabase-rb/adapters/issues) or send a PR.

`supabase-server` gives you batteries-included access to the
[supabase-rb client](https://github.com/supabase-community/supabase-rb), including client
creation and authentication automatically scoped to the inbound request to your Rails app.

```ruby
class GamesController < ApplicationController
  include Supabase::Server::Rails::Controller

  before_action :verify_supabase_auth

  def index
    # RLS-scoped — this user only sees their own favorites
    my_games = supabase_context.supabase.from(:favorite_games).select.execute
    render json: my_games
  end
end
```

One mixin. One `before_action`. Auth is validated, clients are ready, CORS is handled. Your action only runs on successful auth.

## Installation

Add to your `Gemfile`:

```ruby
gem "supabase-server"
```

Then:

```bash
bundle install
```

Or install directly:

```bash
gem install supabase-server
```

## Quick Start

Imagine you're building an app where users track their favorite games. They sign in and manage their own list. Pre-login screens browse the public catalog. An admin dashboard curates featured titles. A cron job refreshes the "popular this week" rankings. Here's how each piece looks.

Mount the middleware once in `config/application.rb`:

```ruby
config.middleware.use Supabase::Server::Rails::Middleware, auth: :user
```

Then include the controller concern in `ApplicationController`:

```ruby
class ApplicationController < ActionController::API
  include Supabase::Server::Rails::Controller
end
```

### Authenticated endpoint

```ruby
# A signed-in user fetches their favorite games.
class FavoriteGamesController < ApplicationController
  before_action :verify_supabase_auth

  def index
    ctx = supabase_context
    # ctx.supabase        — RLS-scoped to the authenticated user
    # ctx.supabase_admin  — bypasses RLS (service role)
    # ctx.user_claims     — user identity from JWT (id, email, role)
    # ctx.jwt_claims      — full JWT claims
    # ctx.auth_mode       — which auth mode matched

    # RLS-scoped — this user only sees their own favorites
    my_games = ctx.supabase.from(:favorite_games).select.execute
    render json: my_games
  end
end
```

### Public endpoint (no auth)

```ruby
# The frontend hits this before showing the login screen.
# auth: :none means no credentials required.
class HealthController < ApplicationController
  before_action -> { verify_supabase_auth(auth: :none) }

  def show
    render json: { status: "ok" }
  end
end
```

### Publishable-key endpoint

```ruby
# The mobile app browses the game catalog before the user signs in.
# auth: :publishable validates the apikey header against a publishable key —
# gating the endpoint to your own clients while staying anonymous to the DB.
class CatalogController < ApplicationController
  before_action -> { verify_supabase_auth(auth: :publishable) }

  def index
    ctx = supabase_context
    # ctx.supabase  — anonymous (anon role); RLS still applies
    # ctx.user_claims, ctx.jwt_claims — nil (no JWT)
    # ctx.auth_mode == :publishable, ctx.auth_key_name == "default"
    catalog = ctx.supabase.from(:games).select("id, name, cover_url").execute
    render json: catalog
  end
end
```

The mobile app sends the publishable key in the `apikey` header:

```ruby
catalog_url    = "https://<project>.supabase.co/rest/v1/games"
publishable    = "sb_publishable_..."

Net::HTTP.get(URI(catalog_url), { "apikey" => publishable })
```

> Unlike `auth: :secret`, the `supabase` client here is anonymous, not admin — RLS is the source of truth for what's visible. The publishable key acts as a coarse "this request came from a known client" gate; it isn't a user identity.

### API key protected

```ruby
# An admin dashboard fetches the list of featured games to curate.
# Secret key auth (not a user JWT) — supabase_admin bypasses RLS.
class Admin::FeaturedGamesController < ApplicationController
  before_action -> { verify_supabase_auth(auth: :secret) }

  def index
    featured = supabase_context.supabase_admin.from(:featured_games).select.execute
    render json: featured
  end
end
```

### Dual auth (user or service)

```ruby
# Users view their own play stats from the app (JWT).
# A backend service pulls stats for any user (secret key + user_id in body).
class PlayStatsController < ApplicationController
  before_action -> { verify_supabase_auth(auth: [:user, :secret]) }

  def index
    ctx = supabase_context
    caller_is_user = ctx.auth_mode == :user

    if caller_is_user
      # RLS-scoped — the database enforces "own stats only"
      my_stats = ctx.supabase.from(:play_stats).select.execute
      render(json: my_stats)
    else
      # Service path — bypass RLS to pull stats for any user
      user_id = params.require(:user_id)
      stats = ctx.supabase_admin.from(:play_stats).select.eq(:user_id, user_id).execute
      render(json: stats)
    end
  end
end
```

### Server-to-server

```ruby
# A cron job refreshes the "popular this week" list every hour.
# Named key ("cron") so it can be rotated without touching other services.
class RefreshPopularController < ApplicationController
  before_action -> { verify_supabase_auth(auth: "secret:cron") }

  def create
    one_week_ago = (Time.now - 7 * 24 * 60 * 60).iso8601
    admin = supabase_context.supabase_admin

    popular = admin.rpc("get_most_favorited_since", since: one_week_ago, limit_count: 10).execute
    admin.from(:featured_games).upsert(
      popular.map { |g| { game_id: g["id"], reason: "popular" } }
    ).execute

    render json: { popular_this_week: popular }
  end
end
```

The cron job sends the named secret key in the `apikey` header:

```bash
curl -X POST https://api.example.com/refresh_popular \
  -H "apikey: sb_secret_..." # the "cron" named secret key
```

## Auth Modes

| Mode           | Credential            | Use case                                            |
| -------------- | --------------------- | --------------------------------------------------- |
| `:user` (default) | Valid JWT          | Authenticated user endpoints                        |
| `:publishable` | Valid publishable key | Client-facing, key-validated endpoints              |
| `:secret`      | Valid secret key      | Server-to-server, internal calls                    |
| `:none`        | None                  | Open endpoints, wrappers that handle their own auth |

Array syntax (`auth: [:user, :secret]`) accepts multiple auth methods — first match wins. An absent credential falls through to the next mode; a present-but-invalid JWT rejects the request (no silent downgrade).

Named key validation: `auth: "publishable:web_app"` or `auth: "secret:automations"` validates against a specific named key in `SUPABASE_PUBLISHABLE_KEYS` or `SUPABASE_SECRET_KEYS`.

## Context

Every action with `verify_supabase_auth` receives a `SupabaseContext` via the `supabase_context` helper:

```ruby
SupabaseContext = Data.define(
  :supabase,        # Supabase::Client — RLS-scoped (user or anon depending on auth)
  :supabase_admin,  # Supabase::Client — bypasses RLS
  :user_claims,     # UserClaims | nil — JWT-derived identity (id, role, email, ...)
  :jwt_claims,      # Hash       | nil — raw JWT payload
  :auth_mode,       # Symbol           — :user | :publishable | :secret | :none
  :auth_key_name    # String     | nil — matched named key, when applicable
)
```

`supabase` is always the safe client — it respects RLS. When `auth_mode` is `:user`, it's scoped to that user's permissions. Otherwise, it's initialized as anonymous.

`supabase_admin` always bypasses RLS. Use it for operations that need full database access.

## Config

The middleware accepts the same options as `verify_supabase_auth`:

```ruby
config.middleware.use Supabase::Server::Rails::Middleware,
  auth: :user,                # who can call this app
  cors: false,                # disable CORS (default: supabase-js CORS headers)
  env: { url: "..." },        # env overrides (optional)
  supabase_options: {}        # forwarded to Supabase::Client.new
```

`cors` defaults to the standard supabase-js CORS headers. Pass a `Hash` to set custom headers, or `false` to disable CORS handling (e.g. when using `rack-cors` or Rails' own CORS stack).

```ruby
config.middleware.use Supabase::Server::Rails::Middleware,
  auth: :user,
  cors: {
    "Access-Control-Allow-Origin"  => "https://myapp.com",
    "Access-Control-Allow-Headers" => "authorization, content-type"
  }
```

`env` overrides environment variable resolution. Defaults to reading `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, and `SUPABASE_JWKS` from the runtime environment.

## Framework Adapters

Adapters wrap the core primitives for a specific framework's middleware/controller contract. They ship inside `supabase-server`, so a single `gem install supabase-server` covers the framework you're using — no separate gem per adapter.

> **Adapters are a community-driven initiative.** They're developed, maintained, and evolved by contributors — including responding to upstream framework changes. See [CONTRIBUTING.md](CONTRIBUTING.md) for the requirements (tests, docs, and integration coverage) if you'd like to add or help maintain one.

| Framework | Require                          | Framework version | Docs                                         |
| --------- | -------------------------------- | ----------------- | -------------------------------------------- |
| Rails     | `supabase/server/rails`          | `>= 7.1`          | [docs/adapters/rails.md](docs/adapters/rails.md) |

Sinatra, Roda, Grape, Hanami, and Cuba adapters are welcome contributions for the post-`0.1` releases — see the [adapter checklist](CONTRIBUTING.md).

### Rails

```ruby
# config/application.rb
require "supabase/server/rails"

module MyApp
  class Application < Rails::Application
    # Protected — middleware resolves SupabaseContext before any controller runs
    config.middleware.use Supabase::Server::Rails::Middleware, auth: :user
  end
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  include Supabase::Server::Rails::Controller
end

# app/controllers/games_controller.rb
class GamesController < ApplicationController
  before_action :verify_supabase_auth

  def index
    games = supabase_context.supabase.from(:favorite_games).select.execute
    render json: games
  end
end
```

Per-route auth overrides flow through `verify_supabase_auth`:

```ruby
class Admin::GamesController < ApplicationController
  before_action -> { verify_supabase_auth(auth: :secret) }

  def index
    render json: supabase_context.supabase_admin.from(:games).select.execute
  end
end
```

`Supabase::Server::AuthError` raised inside an action is automatically rendered as a JSON error response by the included `rescue_from` handler.

## Primitives

For when you need more control than the Rails adapter provides — multi-tenant routing, custom error responses, or building your own adapter.

All primitives live under `Supabase::Server`.

```ruby
require "supabase/server"

Supabase::Server::Core.extract_credentials(headers)
Supabase::Server::Core.verify_credentials(credentials, auth: :user)
Supabase::Server::Core.create_context_client(auth: { token: jwt })
Supabase::Server::Core.create_admin_client
Supabase::Server::JWT.verify(token, env: env)
Supabase::Server::Env.resolve(overrides)
```

### `Supabase::Server.create_context`

Full context assembly from a Rack request — credential extraction, verification, and client creation in one call. Returns a `Result` exposing `.value` / `.error` and `success?` / `failure?`:

```ruby
result = Supabase::Server.create_context(request, auth: :user)
return render(json: { message: result.error.message }, status: result.error.status) if result.failure?

result.value.supabase.from(:games).select.execute
```

### `Supabase::Server::Core.verify_credentials`

Low-level — works with raw credentials (no Request). Used by custom adapters and SSR flows.

```ruby
credentials = Supabase::Server::Credentials.new(token: jwt, apikey: nil)
result = Supabase::Server::Core.verify_credentials(credentials, auth: :user)
# raises Supabase::Server::AuthError on failure
```

### `Supabase::Server::Core.create_context_client` / `create_admin_client`

```ruby
user_scoped  = Supabase::Server::Core.create_context_client(auth: { token: jwt })   # RLS applies as this user
anonymous    = Supabase::Server::Core.create_context_client                          # RLS applies as anon role
admin        = Supabase::Server::Core.create_admin_client                            # bypasses RLS entirely
```

### Example: custom Rack handler

The same favorite-games API and health check, built from primitives instead of the Rails concern:

```ruby
require "supabase/server"

class SupabaseApp
  def call(env)
    request = Rack::Request.new(env)

    # Public — no auth needed
    return [200, { "Content-Type" => "application/json" }, [%({"status":"ok"})]] if request.path == "/health"

    # Protected — verify the JWT, then create a user-scoped client
    if request.path == "/games"
      result = Supabase::Server.create_context(request, auth: :user)
      if result.failure?
        err = result.error
        return [err.status, { "Content-Type" => "application/json" },
                [JSON.generate(message: err.message, code: err.code)]]
      end

      games = result.value.supabase.from(:favorite_games).select.execute
      return [200, { "Content-Type" => "application/json" }, [JSON.generate(games)]]
    end

    [404, {}, ["Not found"]]
  end
end
```

## Environment Variables

| Variable                    | Format                                                        | Description                                  |
| --------------------------- | ------------------------------------------------------------- | -------------------------------------------- |
| `SUPABASE_URL`              | `https://<ref>.supabase.co`                                   | Your project URL                             |
| `SUPABASE_PUBLISHABLE_KEYS` | `{"default":"sb_publishable_...","web":"sb_publishable_..."}` | Publishable API keys (named)                 |
| `SUPABASE_SECRET_KEYS`      | `{"default":"sb_secret_...","web":"sb_secret_..."}`           | Secret API keys (named)                      |
| `SUPABASE_JWKS`             | `{"keys":[...]}` or `[...]`                                   | Inline JSON Web Key Set for JWT verification |

Also supported (for local dev, self-hosted, or simpler setups):

| Variable                   | Format               | Description                                               |
| -------------------------- | -------------------- | --------------------------------------------------------- |
| `SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_...` | Single publishable key                                    |
| `SUPABASE_SECRET_KEY`      | `sb_secret_...`      | Single secret key                                         |
| `SUPABASE_JWKS_URL`        | `https://...`        | Remote JWKS endpoint (used when `SUPABASE_JWKS` is unset) |

When both singular and plural forms are set, plural takes priority.

For other environments, pass overrides via the middleware's `env:` option or `Supabase::Server::Env.resolve(overrides)`.

## Runtimes

`supabase-server` is thread-safe and runs on any Rack-compatible server.

| Target                    | Notes                                                                          |
| ------------------------- | ------------------------------------------------------------------------------ |
| **Puma (multi-threaded)** | Primary target. No per-thread setup required.                                  |
| **Puma (clustered)**      | Each worker gets its own JWKS cache; threads inside the worker share it.       |
| **Falcon**                | Sync I/O only at v0.x — async fibres work, but no `async-http` integration.    |
| **Passenger / Unicorn**   | Works; multi-process isolation means each worker re-fetches JWKS on cold path. |
| **WEBrick / Thin**        | Works for development.                                                         |

### Does this replace `supabase-auth`?

No. `supabase-auth` handles client-side and stateful auth flows (sign-in, session refresh, cookies). `supabase-server` handles stateless, header-based auth for backend APIs that already receive a JWT or API key from a Supabase-authenticated caller. The two libraries are complementary, not replacements.

## Public surface

| Module / class                           | What's in it                                                        |
| ---------------------------------------- | ------------------------------------------------------------------- |
| `Supabase::Server`                       | `create_context`, `Result`, `SupabaseContext`, `Credentials`, `AuthResult` |
| `Supabase::Server::Core`                 | `extract_credentials`, `verify_credentials`, `create_context_client`, `create_admin_client` |
| `Supabase::Server::JWT`                  | `verify` (with JWKS caching)                                        |
| `Supabase::Server::Env`                  | `resolve`                                                           |
| `Supabase::Server::CORS`                 | `build_headers`, `add_headers`                                      |
| `Supabase::Server::Logging`              | `logger=`, `log`                                                    |
| `Supabase::Server::EnvError`             | `< StandardError`, `#status`, `#code`                               |
| `Supabase::Server::AuthError`            | `< StandardError`, `#status`, `#code`                               |
| `Supabase::Server::Rails::Middleware`    | Rack middleware (mount in `config.middleware.use`)                  |
| `Supabase::Server::Rails::Controller`    | Controller concern (`include` in `ApplicationController`)           |

## Documentation

| Question                                                | Doc file                                             |
| ------------------------------------------------------- | ---------------------------------------------------- |
| What does the design target?                            | [PRD.md](PRD.md)                                     |
| How do I use this with Rails?                           | [docs/adapters/rails.md](docs/adapters/rails.md)     |
| How do environment variables work?                      | [docs/environment-variables.md](docs/environment-variables.md) |
| What error codes exist?                                 | [docs/error-handling.md](docs/error-handling.md)     |
| How do I write a community adapter?                     | [CONTRIBUTING.md](CONTRIBUTING.md)                   |

## Development

```bash
bundle install
bundle exec rspec
```

The test suite covers core primitives, the Rails adapter, plus dedicated non-functional suites: thread safety (NFR-1), performance budget (NFR-2), Ruby compatibility (NFR-3), security (NFR-4), and observability (NFR-5).

## License

MIT
