# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-29

### Added
- Initial release of `supabase-rails` (formerly `supabase-server`)
- Rack middleware (`Supabase::Rails::Middleware`) and controller concern (`Supabase::Rails::Controller`)
- Per-request `SupabaseContext` with RLS-scoped client, admin client, and JWT-derived user claims
- Auth modes: `:user` (JWT), `:publishable`, `:secret`, `:none`, plus array syntax and named keys
- JWT verification with JWKS caching (inline JSON or remote URL)
- CORS handling with supabase-js-compatible defaults
- Railtie that auto-inserts the middleware and exposes `config.supabase.*` in host Rails apps (loaded conditionally — gem still works in non-Rails contexts)

[Unreleased]: https://github.com/supabase-ruby/supabase-rails/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/supabase-ruby/supabase-rails/releases/tag/v0.1.0
