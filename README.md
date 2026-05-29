# supabase-server

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Gem](https://img.shields.io/badge/gem-supabase--server-CC342D?logo=rubygems&logoColor=white)](https://rubygems.org/gems/supabase-server)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.0-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)

## Overview

`supabase-server` gives you batteries-included access to the [supabase-rb client](https://github.com/supabase-rb/client), including client creation and authentication automatically scoped to the inbound request to your Rails app.

The gem streamlines backend authentication and database access by handling JWT validation, API-key verification, and Row-Level Security (RLS) scoping automatically. It is the Ruby port of [`@supabase/server`](https://github.com/supabase/server); feature parity is tracked in [PRD.md](PRD.md).

## Key Features

**Core Functionality:**
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
gem "supabase-server"
```

```bash
bundle install
# or
gem install supabase-server
```

## Basic Usage

```ruby
# config/application.rb
require "supabase/server/rails"
config.middleware.use Supabase::Server::Rails::Middleware, auth: :user

# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  include Supabase::Server::Rails::Controller
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

One mixin, one `before_action`: auth is validated, clients are ready, CORS is handled. Your action only runs on successful auth.

## Context Object

Every action with `verify_supabase_auth` receives a `SupabaseContext` via the `supabase_context` helper:

- `supabase` — RLS-scoped client (respects user permissions)
- `supabase_admin` — unrestricted admin client (bypasses RLS)
- `user_claims` — extracted JWT identity (`id`, `role`, `email`, ...)
- `jwt_claims` — full JWT payload
- `auth_mode` — which authentication method matched (`:user`, `:publishable`, `:secret`, `:none`)
- `auth_key_name` — named API-key identifier when applicable

`supabase` is always the safe client. When `auth_mode` is `:user`, it is scoped to that user; otherwise it is anonymous. `supabase_admin` always bypasses RLS — use it for operations that need full database access.

## Framework Adapters

Built-in support for:

| Framework | Require                 | Framework version |
| --------- | ----------------------- | ----------------- |
| Rails     | `supabase/server/rails` | `>= 7.1`          |

Adapters wrap the core primitives for a specific framework's middleware/controller contract. They ship inside `supabase-server`, so a single `gem install supabase-server` covers the framework you're using.

> Adapters are a community-driven initiative. Sinatra, Roda, Grape, Hanami, and Cuba adapters are welcome contributions for post-`0.1` releases.

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

## Core Primitives

For custom implementations — multi-tenant routing, custom error responses, or building your own adapter — use the primitives under `Supabase::Server`:

- `Supabase::Server.create_context(request, auth:)` — full context assembly from a Rack request
- `Supabase::Server::Core.extract_credentials(headers)` — pull token/apikey from headers
- `Supabase::Server::Core.verify_credentials(credentials, auth:)` — low-level credential validation
- `Supabase::Server::Core.create_context_client(auth:)` — RLS-scoped client
- `Supabase::Server::Core.create_admin_client` — unrestricted client
- `Supabase::Server::JWT.verify(token, env:)` — JWT verification with JWKS caching
- `Supabase::Server::Env.resolve(overrides)` — environment-variable resolution

```ruby
require "supabase/server"

result = Supabase::Server.create_context(request, auth: :user)
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

Plural forms take priority when both are set. For other environments, pass overrides via the middleware's `env:` option or `Supabase::Server::Env.resolve(overrides)`.

## Deployment Targets

`supabase-server` is thread-safe and runs on any Rack-compatible server.

| Target                    | Notes                                                                          |
| ------------------------- | ------------------------------------------------------------------------------ |
| **Puma (multi-threaded)** | Primary target. No per-thread setup required.                                  |
| **Puma (clustered)**      | Each worker gets its own JWKS cache; threads inside the worker share it.       |
| **Falcon**                | Sync I/O only at v0.x — async fibres work, but no `async-http` integration.    |
| **Passenger / Unicorn**   | Works; multi-process isolation means each worker re-fetches JWKS on cold path. |
| **WEBrick / Thin**        | Works for development.                                                         |

## Configuration

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

Named-key validation: `auth: "publishable:web_app"` or `auth: "secret:cron"` validates against a specific named key in `SUPABASE_PUBLISHABLE_KEYS` / `SUPABASE_SECRET_KEYS`.

Array syntax (`auth: [:user, :secret]`) accepts multiple methods — first match wins. An absent credential falls through to the next mode; a present-but-invalid JWT rejects the request (no silent downgrade).

## Status

The gem is in public beta (v0.x). Breaking changes only ship as a major bump. The gem is still early — expect new adapters, ergonomic improvements, and features to land frequently in minor releases. Found a rough edge? [Open an issue](https://github.com/supabase-rb/supabase-server/issues) or send a PR.

## License

MIT
