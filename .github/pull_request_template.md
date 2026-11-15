<!--
PORTABLE across official Zap library repos. fastzap-specific only in the docs
checklist file names. Do NOT add any AI/agent attribution to the PR title or this
description (repo policy — maintainer name only). Attribution is allowed only in
review COMMENTS ("Reviewed by …" / "<tool> input on …").
-->

## What & why

<!-- One paragraph: what this changes and the motivation. -->

## Linked issue

<!--
One PR ↔ one issue (contributors: always). Use a closing keyword so merge closes it.
A maintainer may occasionally combine small issues; contributors must not.
-->
Closes #

## Changes

<!-- Bullet the notable changes. -->
-

## Tests (positive AND negative)

Tests are intent documentation and a walled garden — exhaustive, never minimal.
For a bug fix, the failing test was written **first**.

- [ ] Added/updated tests covering the **positive** path(s).
- [ ] Added/updated tests covering the **negative / edge** cases (bad input, missing
      values, boundaries, wrong method, error status codes).
- [ ] Each new `tests/<name>_test.zap` has a non-empty `.expected` golden and a
      `run_one <name>` line in `tools/run-tests.sh` (the `hygiene` CI job enforces this).

## Documentation

Docs stay current with every PR. Tick what applies / was updated:

- [ ] `DESIGN.md` — architecture / lifecycle / testing notes.
- [ ] `DECISIONS.md` — a new `D-FZ-NNNN` entry (or amendment) for any design decision.
- [ ] `README.md` — user-facing surface, examples, `v1 scope`.
- [ ] `CHANGELOG.md` — an entry under `Unreleased`.
- [ ] No docs change needed (explain why).

## Core-dependency check

- [ ] This PR does **not** work around a core Zap language/stdlib defect. If it
      exposes one, it is reported in `zaplang-io/zap` and this PR stays blocked/draft
      until the fix lands (link the core issue).

## Merge checklist

- [ ] CI is green (`hygiene`, `fmt`, `tests` all pass — CI is the gate; most
      contributors can't run the toolchain locally).
- [ ] At least **one approving review from someone other than the author**.
- [ ] No AI/agent attribution anywhere in the commit messages, PR title, or this body.
