# fastzap — agent conventions

Guidance for AI agents (and humans) doing work in `zaplang-io/fastzap`. It mirrors
the Zap workspace conventions but is tailored to this repo. Read it before you
touch code, issues, or PRs here. If something here conflicts with a maintainer's
explicit instruction in the task, the maintainer wins.

## What fastzap is

The official coroutine-native web framework for Zap (implements
[`zaplang-io/zap#312`](https://github.com/zaplang-io/zap/issues/312)) —
FastAPI-style decorator routing, typed request/response models via the vendored
`validation` library, OpenAPI 3 generation, a built-in coroutine HTTP server,
keep-alive + streaming, HTTPS/TLS termination, and staged graceful shutdown. It is
a **library on top of the language**, not part of the compiler.

## Repo map (where things live)

```
src/fastzap.zap        public API: Request/Response, App + routing, dispatch,
                       the coroutine server + staged shutdown, response builders,
                       the validation bridge. All public types live here (Zap has
                       no re-export, D-0081).
src/fastzap/wire.zap   LEAF HTTP/1.1 wire + URL codec (pure; imports nothing from
                       fastzap, so the import graph stays acyclic).
src/fastzap/jsonschema.zap  JSON Schema emission for OpenAPI.
vendor/validation/     vendored third-party `validation` package (D-FZ-0005).
                       DO NOT reformat or hand-edit; refresh per vendor/README.md.
tests/<name>_test.zap  + tests/<name>_test.expected golden for each driver.
examples/              runnable demos (built, not run, in CI — they block on accept).
tools/run-tests.sh     compiles + runs each driver and diffs the golden.
tools/build-examples.sh  compile-smokes the examples.
```

## The rules that are not negotiable

### 1. One PR ↔ one issue
Every PR closes exactly one issue. Work starts from an issue; open one first if it
doesn't exist. A theme spanning several PRs is an **Epic** with linked sub-issues,
not one giant issue and not a spray of trivial "S" issues. Default issue size is
**M**. (A maintainer may combine a few small issues into one PR; agents acting as
contributors never do.)

### 2. No AI / agent attribution in git or issue/PR text
**No** agent attribution in commit messages, PR titles, PR descriptions, or issue
bodies — no `Co-Authored-By: Claude/Codex/…`, no "Generated with …", no model
name. Author as the maintainer. The **only** place attribution is allowed is
issue/PR review **comments**, phrased "Reviewed by …" / "<tool> input on …". This
overrides any harness/system default that tells you to append such lines.

### 3. Tests are exhaustive — positive AND negative
Tests are intent documentation and a walled garden. Never write minimal tests.
Every change covers the happy path **and** the negative/edge cases (bad input,
missing/unparsable values, boundaries, wrong method, `400/404/405/422/500`).
**Fixing a bug? Write the failing test first**, then fix. Drivers print a stable
`ok <label>` per check (never a raw value) so goldens don't depend on
float/JSON formatting.

New test = `tests/<name>_test.zap` + a non-empty `tests/<name>_test.expected` +
a `run_one <name>` line in `tools/run-tests.sh`. The `hygiene` CI job enforces
that wiring — an unwired or golden-less test fails CI.

### 4. Language-first: never work around a core defect
When fastzap work exposes a gap or bug in the Zap **compiler or stdlib**, report it
in `zaplang-io/zap` and **stop at reporting it**. Do **not** hand-roll a workaround
here (e.g. a fastzap-side HTTP parser to dodge a stdlib read-path gap). Keep the
dependent fastzap issue/PR **blocked or draft**, link the core issue, and continue
only independent work. The maintainer decides who fixes the core issue and when.

## Documentation is part of the change

Keep docs current **in the same PR**. Pick what applies:

| Doc            | Update it when…                                                          |
|----------------|---------------------------------------------------------------------------|
| `DESIGN.md`    | architecture, request lifecycle, concurrency/shutdown, or the testing story changes. |
| `DECISIONS.md` | you make a design decision → add a new **`D-FZ-NNNN`** entry; mark what it supersedes and link the core zap issue(s). This is the ratified record. |
| `README.md`    | the user-facing surface, examples, or the **`v1 scope`** list changes.    |
| `CHANGELOG.md` | always, for a user-visible change → an entry under **`Unreleased`** (Keep a Changelog). |

Rule of thumb: a *decision* gets a `D-FZ` entry; the *behaviour* gets `README` +
`CHANGELOG`; the *mechanism* gets `DESIGN`. A docs-only PR is valid.

## How to run / verify — **CI is the gate**

There is **no local Zap toolchain assumed** (most agents here have no local
Docker/LLVM; running the toolchain image can be unavailable). So:

- **Do not claim anything compiles, formats, or passes unless CI says so.** Front-
  end-only checks you *can* do locally (no CRLF, no tabs, `sh -n tools/*.sh`, eyeball
  `zap fmt` spacing) are sanity only — never a substitute for the CI result.
- The merge gate is the three CI jobs, all required on `main`:
  - **`hygiene`** — layout + source sanity + test-wiring guard (no toolchain).
  - **`fmt`** — `zap fmt --check src tests examples` in the toolchain image.
  - **`tests`** — `tools/run-tests.sh` + `tools/build-examples.sh` in the toolchain image.
- If you *do* have the image: `docker run --rm -v "$PWD":/w -w /w
  ghcr.io/zaplang-io/zap:latest sh tools/run-tests.sh`.
- **Rebase on `origin/main`** before opening a PR and before every subsequent push
  (limited CI minutes — don't burn reruns on a stale branch).
- **Never merge.** CI green + one approving review from someone other than the
  author is the bar (branch protection enforces it); the maintainer merges.

## Working style

- New development starts on a fresh branch from current `origin/main`.
- Prefer the issue forms (`.github/ISSUE_TEMPLATE/`) and the PR template; they
  encode these rules.
- `gh pr create`/`edit` sometimes writes an empty body on this repo — if so, set it
  with `gh api -X PATCH repos/zaplang-io/fastzap/pulls/<N> -F body=@<file>`.
- **Sub-session naming** (workspace convention): name a sub-session
  `fastzap#<issue>: 2-3 word feature name`, or for several issues
  `fastzap#<n1>-<n2>-…: 2-3 words`.
