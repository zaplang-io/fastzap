# Changelog

All notable changes to fastzap are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every user-visible change adds an entry under **Unreleased** in the same PR (see
`CONTRIBUTING.md`).

## [Unreleased]

### Added
- Contributor governance: `CONTRIBUTING.md`, `AGENTS.md`, issue forms (bug report
  + feature request) and `config.yml`, a pull request template, and an Ideas
  discussion template.
- CI split into three nameable, required jobs — `hygiene`, `fmt`, `tests` — with a
  guard that every `tests/*_test.zap` ships a golden and is wired into
  `tools/run-tests.sh`.

<!--
No tagged releases yet. fastzap v1 and its feature set (decorator routing, typed
params + 422, dependency injection, OpenAPI 3, middleware, keep-alive/streaming,
HTTPS/TLS termination, staged graceful shutdown) were built pre-changelog; see
DECISIONS.md (D-FZ-0001 … D-FZ-0015) for that history. Start the first tagged
release section here when v1 is cut.
-->
