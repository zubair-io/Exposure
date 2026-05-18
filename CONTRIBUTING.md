# Contributing to Exposure

This document is the engineering contract for the repo. Read it before your
first commit. The rules exist because we walked into the alternative once
already.

## Project identity

- **Product name:** Exposure
- **GitHub:** [zubair-io/Exposure](https://github.com/zubair-io/Exposure)
- **Apple bundle ID:** `io.lawrence.exposure` (tests append `.Tests` / `.UITests`)
- **There is one name.** No alternate codenames, no "internal" project names,
  no historical prefixes carried forward. If a doc, file, or identifier wants
  to use a name, it is `Exposure` (or `exposure` in lowercase contexts).

## The three load-bearing rules

These three rules are non-negotiable. Everything else in this file is detail
in service of them.

### 1. One source of truth for every type

A type that crosses a language boundary is defined **once**, in Rust, and
generated for every other language by `tools/codegen.sh`. Generated files
carry a banner saying "DO NOT EDIT" and are committed (so the repo builds
without running codegen). CI re-runs codegen and fails on diff.

The forbidden pattern: a struct hand-mirrored across Rust, Swift, and
TypeScript that drifts at the defaults level. We caught that already.

Implementation lives in `tools/codegen.sh` (added when the first
cross-language type lands; see `docs/spec/NN-*.md`).

### 2. File-size budget — 400 soft / 600 hard

Source files have:

- **400 lines:** soft limit. CI warns; reviewers should challenge.
- **600 lines:** hard limit. CI fails.

Applies to `*.rs`, `*.swift`, `*.ts`, `*.tsx`, `*.js`, `*.py`.

Exceptions go in `tools/budget-allowlist.txt`. Adding a line requires a
justification in the PR description **and** a follow-up issue to split the
file. **The allowlist can only shrink, never grow.** This is mechanically
checked in CI by diffing the allowlist against `main`.

Why: when files cross ~600 lines they become "god objects" — multiple
responsibilities, hard to test in isolation, painful to review. We caught
that already too.

### 3. One spec tier, no orphan docs

Documentation has exactly two tiers:

- **`docs/spec/NN-*.md`** — evergreen, numbered specs. These are the
  contract. Code may link to them; they are kept current.
- **`docs/operations/*.md`** — how to run/build/deploy. Lives next to
  whatever it documents; brief.

Things that do **not** belong in `docs/`:

- Session plans, working notes, agent transcripts → use a GitHub Issue, a
  draft PR, or `.notes/` (gitignored).
- Status updates, retros, "what we did last sprint" → GitHub
  Issues/Discussions.
- Marketing copy, pitches, decks → separate repo.
- Multiple competing specs for the same thing → pick one, fold the rest in,
  delete the orphan.

The smell test: every file in `docs/` should still be useful in six months.
If it won't be, it's not a spec — find it another home.

## Task tracking

- **GitHub Issues is the single source of truth** for backlog, bugs, and
  scoped work. Not `docs/`. Not Linear (yet).
- One issue per discrete piece of work; close via PR (`Closes #NN`).
- Use labels for routing, milestones for releases, projects (v2) for the
  rare cross-issue view.

## Commits

- **Conventional Commits** format: `type(scope): subject` (≤ 72 chars).
  - Types: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`, `perf`, `ci`,
    `build`, `revert`.
  - Scopes are subsystem names: `rust`, `apple`, `web`, `api`, `tools`,
    `ci`, etc.
  - Example: `fix(api): handle missing Mongo collection on first boot`.
- **Sign your commits.** `git config commit.gpgsign true` once, then forget
  about it. Branch protection on `main` will require signatures.
- **Squash on merge.** PR title becomes the squash commit message; clean it
  up before merging.
- **No `--amend` after pushing.** Push a follow-up commit instead.
- **No skipping hooks.** `--no-verify` is reserved for emergencies that need
  a written justification in the PR.

## Pull requests

- Branch from `main`. Branch naming is freeform; keep it short.
- A PR must:
  - Pass `cross.yml` and any per-subsystem workflow it touches.
  - Have a one-line summary and a "why" paragraph.
  - Link the issue it closes.
- Reviews: one approver minimum. Author dismisses stale reviews after a
  rewrite.
- Merge button: **squash**. Never "Create a merge commit." Never "Rebase
  and merge."

## Tooling — what runs when

| Phase | Tool | Catches |
|---|---|---|
| Editor save | `.editorconfig` | indent/EOL drift |
| `git commit` | `lefthook` | formatting, file-budget, secrets |
| `git push` / PR | `cross.yml` + per-subsystem CI | everything in the pre-commit + tests + linters + build |
| Weekly cron | `audit.yml` (added with first lockfile) | `cargo audit`, `bun audit` CVEs |

The pre-commit hooks are aggressive on purpose; they catch the trivial
stuff so reviewers don't have to. If you're tempted to skip them, the right
move is usually to fix the file, not bypass the check.

### Per-language formatter / linter

| Language | Format | Lint |
|---|---|---|
| Rust | `cargo fmt` | `cargo clippy -- -D warnings` |
| Swift | `xcrun swift-format` | `swiftlint` |
| TypeScript | `prettier` | `eslint` (typescript-eslint + Angular where applicable) |
| Python | `ruff format` | `ruff check` |
| Shell | `shfmt` | `shellcheck` |

Type-strictness defaults:

- **Rust:** `#![deny(warnings)]` under CI feature; `clippy::pedantic` opt-in
  per crate.
- **Swift:** `-warnings-as-errors`, strict concurrency.
- **TypeScript:** `strict: true`, `noUncheckedIndexedAccess`,
  `exactOptionalPropertyTypes`, `noImplicitOverride`.

## Layout (planned)

The repo will grow into this shape. Each subsystem lands as its own PR with
the per-subsystem CI workflow in the same PR:

```
src/
  raw-pipeline/    # Rust workspace (image-processing core)
    raw-core/      # Pure image math
    raw-ffi/       # cbindgen → C headers for Apple
    raw-wasm/      # wasm-bindgen → browser bindings
  apple/           # Swift app (macOS / iOS / iPadOS)
  web/             # Angular workspace
  api/             # Bun + Elysia + MongoDB
  scripts/         # Codegen + parity harnesses
docs/
  spec/            # NN-*.md, evergreen
  operations/      # Build/run/deploy notes
tools/             # Repo-level scripts (check-file-budget.sh, codegen.sh, ...)
test-fixtures/     # Large binaries, gitignored except budgets.json
.github/workflows/ # CI
```

## Testing

- **No mocks for the sidecar layer.** Round-trip against real `.xmp` files
  in a temp directory. The sidecar is the contract; mocks let bugs through.
- **One shared `test-fixtures/`** at repo root. Every platform's test runner
  reads from there. Parity is a CI assertion, not a manual harness.
- **Performance is a feature.** If a change blows the 16ms slider budget on
  the reference scene set, it does not merge.

## When in doubt

- Smaller files beat bigger files.
- Generated code beats hand-synced code.
- One source of truth beats two.
- A GitHub Issue beats a markdown file.
- Read this doc again.
