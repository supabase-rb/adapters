# supabase-rails

[![Test](https://github.com/supabase-ruby/supabase-rails/actions/workflows/test.yml/badge.svg)](https://github.com/supabase-ruby/supabase-rails/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Gem](https://img.shields.io/badge/gem-supabase--rails-CC342D?logo=rubygems&logoColor=white)](https://rubygems.org/gems/supabase-rails)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.0-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)

## Overview

`supabase-rails` is the Supabase integration for Ruby on Rails. It plugs into the Rails middleware stack and gives every controller action a per-request Supabase context — RLS-scoped client, admin client, and JWT-derived user identity — with one mixin and one `before_action`.

The gem handles JWT validation, API-key verification, CORS, and Row-Level Security (RLS) scoping automatically. It is the Rails counterpart to [`@supabase/ssr`](https://github.com/supabase/ssr); design notes are in [PRD.md](PRD.md).

## Key Features

- Single-line authentication configuration
- Automatic CORS handling
- RLS-scoped and admin database clients
- Support for multiple auth modes (user JWT, API keys, publishable keys)
- Named-key validation for rotatable secrets

**Supported Auth Modes:**
- `:user` — JWT-authenticated users
- `:publishable` — client-facing, key-validated endpoints
- `:secret` — server-to-server authenticated calls
- `:none` — open endpoints
- Array syntax for multiple auth methods: `auth: [:user, :secret]`

## Installation

```ruby
# Gemfile
gem "supabase-rails"
```

```bash
bundle install
# or
gem install supabase-rails
```

## Basic Usage

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  include Supabase::Rails::Controller
end

# app/controllers/favorite_games_controller.rb
class FavoriteGamesController < ApplicationController
  before_action :verify_supabase_auth

  def index
    my_games = supabase_context.supabase.from(:favorite_games).select.execute
    render json: my_games
  end
end
```

That's it. In a Rails app the gem's Railtie auto-inserts the middleware on boot with `auth: :user` and default CORS — no `config.middleware.use` needed. One mixin, one `before_action`: auth is validated, clients are ready, CORS is handled. Your action only runs on successful auth.

## Context Object

Every action with `verify_supabase_auth` receives a `SupabaseContext` via the `supabase_context` helper:

- `supabase` — RLS-scoped client (respects user permissions)
- `supabase_admin` — unrestricted admin client (bypasses RLS)
- `user_claims` — extracted JWT identity (`id`, `role`, `email`, ...)
- `jwt_claims` — full JWT payload
- `auth_mode` — which authentication method matched (`:user`, `:publishable`, `:secret`, `:none`)
- `auth_key_name` — named API-key identifier when applicable

`supabase` is always the safe client. When `auth_mode` is `:user`, it is scoped to that user; otherwise it is anonymous. `supabase_admin` always bypasses RLS — use it for operations that need full database access.

## Per-Route Auth

Per-route auth overrides flow through `verify_supabase_auth`:

```ruby
class Admin::GamesController < ApplicationController
  before_action -> { verify_supabase_auth(auth: :secret) }

  def index
    render json: supabase_context.supabase_admin.from(:games).select.execute
  end
end
```

`Supabase::Rails::AuthError` raised inside an action is automatically rendered as a JSON error response by the included `rescue_from` handler.

## Primitives

For multi-tenant routing, custom error responses, or any flow where the middleware/concern aren't a fit, the underlying primitives are public:

- `Supabase::Rails.create_context(request, auth:)` — full context assembly from a Rack request
- `Supabase::Rails::Core.extract_credentials(headers)` — pull token/apikey from headers
- `Supabase::Rails::Core.verify_credentials(credentials, auth:)` — low-level credential validation
- `Supabase::Rails::Core.create_context_client(auth:)` — RLS-scoped client
- `Supabase::Rails::Core.create_admin_client` — unrestricted client
- `Supabase::Rails::JWT.verify(token, env:)` — JWT verification with JWKS caching
- `Supabase::Rails::Env.resolve(overrides)` — environment-variable resolution

```ruby
require "supabase/rails"

result = Supabase::Rails.create_context(request, auth: :user)
return render(json: { message: result.error.message }, status: result.error.status) if result.failure?

result.value.supabase.from(:games).select.execute
```

`create_context` returns a `Result` exposing `.value` / `.error` and `success?` / `failure?`.

## Environment Variables

**Standard configuration:**

| Variable                    | Format                                                        | Description                                  |
| --------------------------- | ------------------------------------------------------------- | -------------------------------------------- |
| `SUPABASE_URL`              | `https://<ref>.supabase.co`                                   | Your project URL                             |
| `SUPABASE_PUBLISHABLE_KEYS` | `{"default":"sb_publishable_...","web":"sb_publishable_..."}` | Publishable API keys (named, JSON)           |
| `SUPABASE_SECRET_KEYS`      | `{"default":"sb_secret_...","web":"sb_secret_..."}`           | Secret API keys (named, JSON)                |
| `SUPABASE_JWKS`             | `{"keys":[...]}` or `[...]`                                   | Inline JSON Web Key Set for JWT verification |

**Supported alternatives** (local dev, self-hosted, simpler setups):

| Variable                   | Format               | Description                                               |
| -------------------------- | -------------------- | --------------------------------------------------------- |
| `SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_...` | Single publishable key                                    |
| `SUPABASE_SECRET_KEY`      | `sb_secret_...`      | Single secret key                                         |
| `SUPABASE_JWKS_URL`        | `https://...`        | Remote JWKS endpoint (used when `SUPABASE_JWKS` is unset) |

Plural forms take priority when both are set. For other environments, pass overrides via the middleware's `env:` option or `Supabase::Rails::Env.resolve(overrides)`.

## Deployment Targets

`supabase-rails` is thread-safe and runs on any Rack-compatible server.

| Target                    | Notes                                                                          |
| ------------------------- | ------------------------------------------------------------------------------ |
| **Puma (multi-threaded)** | Primary target. No per-thread setup required.                                  |
| **Puma (clustered)**      | Each worker gets its own JWKS cache; threads inside the worker share it.       |
| **Falcon**                | Sync I/O only at v0.x — async fibres work, but no `async-http` integration.    |
| **Passenger / Unicorn**   | Works; multi-process isolation means each worker re-fetches JWKS on cold path. |
| **WEBrick / Thin**        | Works for development.                                                         |

## Configuration

In a Rails app, configure via `config.supabase.*` in `config/application.rb` or an environment file:

```ruby
config.supabase.auth = :user                # default auth mode for the whole app
config.supabase.cors = false                # disable built-in CORS (e.g. when using rack-cors)
config.supabase.env = { url: "..." }        # env overrides (optional)
config.supabase.supabase_options = {}       # forwarded to Supabase::Client.new
```

Defaults: `auth: :user`, CORS enabled with supabase-js-compatible headers, env resolved from `SUPABASE_*` variables.

For custom CORS headers, pass a `Hash`:

```ruby
config.supabase.cors = {
  "Access-Control-Allow-Origin"  => "https://myapp.com",
  "Access-Control-Allow-Headers" => "authorization, content-type"
}
```

Named-key validation: `auth: "publishable:web_app"` or `auth: "secret:cron"` validates against a specific named key in `SUPABASE_PUBLISHABLE_KEYS` / `SUPABASE_SECRET_KEYS`.

Array syntax (`auth: [:user, :secret]`) accepts multiple methods — first match wins. An absent credential falls through to the next mode; a present-but-invalid JWT rejects the request (no silent downgrade).

### Manual middleware insertion

The Railtie auto-inserts the middleware at the end of the stack. To position it precisely, opt out of auto-insertion and insert it yourself:

```ruby
config.supabase.insert_middleware = false
config.middleware.insert_before Rack::Runtime, Supabase::Rails::Middleware, auth: :user
```

Or use the gem in a plain Rack app (no Rails, no Railtie):

```ruby
require "supabase/rails"
use Supabase::Rails::Middleware, auth: :user
```

## Status

The gem is in public beta (v0.x). Breaking changes only ship as a major bump. The gem is still early — expect ergonomic improvements and features to land frequently in minor releases. Found a rough edge? [Open an issue](https://github.com/supabase-ruby/supabase-rails/issues) or send a PR.

## Releasing

Releases are published to RubyGems via [Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) — no API tokens stored anywhere. To cut a release:

1. Update `CHANGELOG.md`, moving items from `[Unreleased]` to a new version section.
2. Bump `Supabase::Rails::VERSION` in `lib/supabase/rails/version.rb`.
3. Commit: `git commit -am "release: v0.1.0"`
4. Tag and push: `git tag v0.1.0 && git push origin main --tags`

The [release workflow](.github/workflows/release.yml) builds the gem, runs the test suite, publishes to RubyGems via OIDC, and creates a GitHub Release with auto-generated notes.

**One-time setup** (on rubygems.org): under the `supabase-rails` gem settings → Trusted Publishers, add a GitHub Actions publisher with repo `supabase-ruby/supabase-rails`, workflow `release.yml`. Until the gem is first published, use [Pending Trusted Publishers](https://guides.rubygems.org/trusted-publishing/#pending-trusted-publishers) to reserve the name.

For added safety, gate the workflow on a [GitHub Environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) (`environment: name: rubygems` in `release.yml`) so publishing requires manual approval per release.

## License

MIT
