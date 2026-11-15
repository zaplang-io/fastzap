# Contributing to fastzap

Thanks for contributing! fastzap is the official coroutine-native web framework
for the [Zap](https://github.com/zaplang-io/zap) language. This guide covers the
contribution flow and the few rules we hold firm on.

> Most of this file is **portable boilerplate** shared across official Zap library
> repos. The parts that are **fastzap-specific** are called out inline (build
> layout, the file list, the example-is-built-not-run note).

## Where things go

- **Bugs** → a [Bug report issue](../../issues/new/choose) with the *smallest*
  reproducing example.
- **Concrete, testable features** → a [Feature request issue](../../issues/new/choose).
- **Open questions, "how do I…", half-formed ideas** → [Discussions](../../discussions).
  Categories: **Q&A** (usage), **Ideas** (design proposals), **General**,
  **Announcements**, **Show and tell**. A settled Ideas discussion graduates to a
  feature issue and a `DECISIONS.md` entry.
- **A bug in the Zap compiler or stdlib** (not in fastzap) → file it in
  [`zaplang-io/zap`](https://github.com/zaplang-io/zap/issues). See
  [Core defects](#core-defects-language-first) below.

## Contribution flow

1. **Find or open an issue first.** Work is tracked one issue at a time (see
   [One PR, one issue](#one-pr-one-issue)). For anything non-trivial, agree on the
   approach in the issue before writing code.
2. **Fork and branch from the latest `main`.**
   ```bash
   git clone https://github.com/<you>/fastzap && cd fastzap
   git remote add upstream https://github.com/zaplang-io/fastzap
   git fetch upstream && git checkout -b feat/short-topic upstream/main
   ```
3. **Make the change** with tests and docs (both are required — see below).
4. **Rebase on `upstream/main`** before opening the PR and before any later push
   (we have limited CI minutes — don't let a stale branch burn reruns):
   ```bash
   git fetch upstream && git rebase upstream/main
   ```
5. **Open one PR** that closes exactly one issue. Fill in the PR template.
6. **Get CI green and one approving review**, then a maintainer merges. Contributors
   do not self-merge.

## One PR, one issue

Every PR closes **exactly one** issue (`Closes #NNN`). If a change feels like it
needs two issues' worth of work, it needs two PRs. (Maintainers may occasionally
combine a few *small* issues into one PR; contributors never do.)

Default issue size is **M**. A theme that genuinely spans several PRs becomes an
**Epic** with linked sub-issues — ask a maintainer to set that up rather than
opening one giant issue or over-splitting into trivial "S" issues.

## Tests: exhaustive, positive **and** negative

Tests are **intent documentation** and a **walled garden** around the codebase —
they pin down what the code promises so a later change can't quietly break it.

- Tests must be **exhaustive, never minimal**. Every PR covers the **positive**
  path *and* the **negative / edge** cases: bad input, missing values, boundaries,
  wrong method, the error status codes (`400`/`404`/`405`/`422`/`500`).
- **Fixing a bug? Write the failing test first**, then make it pass. The test that
  reproduces the bug ships with the fix.
- Each test driver prints a stable `ok <label>` token per check (never a raw
  value) so goldens are independent of float/JSON formatting and a break localizes
  to one line.

**fastzap-specific test wiring.** A new test is `tests/<name>_test.zap` plus a
non-empty `tests/<name>_test.expected` golden, and it must be registered in
`tools/run-tests.sh` with a `run_one <name>` line. The `hygiene` CI job fails if a
test driver is missing its golden or isn't wired into the runner.

## Running the suite

**fastzap-specific.** The tests and examples compile and run through the prebuilt
Zap toolchain image (no need to build the compiler):

```bash
# Run the offline test suite (compile + run each driver, diff against its golden):
docker run --rm -v "$PWD":/w -w /w ghcr.io/zaplang-io/zap:latest sh tools/run-tests.sh

# Compile-smoke the examples (they block on accept(), so they are BUILT, not run):
docker run --rm -v "$PWD":/w -w /w ghcr.io/zaplang-io/zap:latest sh tools/build-examples.sh
```

If you can't run Docker/LLVM locally, that's fine — **CI is the gate** and runs
exactly these. Push and let CI tell you.

## Code style

- **`zap fmt` is canonical** (4-space indent, the formatter's spacing). CI runs
  `zap fmt --check src tests examples` (the `fmt` job); a PR that isn't formatted
  fails. Format with:
  ```bash
  docker run --rm -v "$PWD":/w -w /w ghcr.io/zaplang-io/zap:latest zap fmt src tests examples
  ```
- The vendored dependency under `vendor/` is third-party — don't reformat it.
- No CRLF line endings and no literal tabs in first-party `.zap` sources.

## Documentation stays current with every PR

A change isn't done until its docs are. Update, as applicable:

- **`DESIGN.md`** — architecture, request lifecycle, concurrency/shutdown, testing.
- **`DECISIONS.md`** — a new `D-FZ-NNNN` entry for any design decision (and mark
  what it supersedes). This is the ratified record; keep it authoritative.
- **`README.md`** — the user-facing surface, examples, and the `v1 scope` section.
- **`CHANGELOG.md`** — an entry under `Unreleased` (Keep a Changelog format).

The PR template has the checklist; a docs-only PR is welcome.

## Core defects: language-first

fastzap is a *library*. When something can't be built here because of a gap or bug
in the Zap compiler or stdlib, **report it in
[`zaplang-io/zap`](https://github.com/zaplang-io/zap/issues)** and stop there — do
**not** hand-roll a workaround in fastzap. Keep the dependent fastzap issue/PR
blocked (or draft), link the core issue, and continue only independent work. A
maintainer decides who fixes the core issue and when.

## Review & merge bar

Before a PR merges:

- **CI is green** — all required checks (`hygiene`, `fmt`, `tests`) pass.
- **At least one approving review from someone other than the PR author.**
- Conversations are resolved.

These are enforced by branch protection on `main`; a maintainer merges.

## No AI / agent attribution in git or issue/PR text

Commit messages, PR titles, PR descriptions, and issue bodies carry **no** AI/agent
attribution — no `Co-Authored-By:` a tool, no "Generated with …", no model name.
Use the author's own name. (The one place attribution is fine is review
**comments**, phrased "Reviewed by …" / "<tool> input on …".)

## License

By contributing you agree your contributions are licensed under the repository's
[Apache-2.0](LICENSE) license.
