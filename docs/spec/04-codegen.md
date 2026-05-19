# 04 — Codegen: Rust → Swift / TypeScript

**Status:** Active.
**Applies to:** Every type that lives in Rust and needs an equivalent
representation in Swift or TypeScript — i.e. every cross-language internal
value type used by `raw-core`, the Apple `xcframework`, and the Web
`raw-wasm` consumer.
**Scope:** Internal value types only — see § "Scope boundary" below for
what this spec deliberately excludes.

This spec is the operational mechanism behind CONTRIBUTING.md rule #1:
"one source of truth for every type."

## The rule

A cross-language internal type is defined **once**, in Rust, under
`raw-core::types::*`. Equivalent Swift and TypeScript files are
**generated**, **committed**, and **carry a DO-NOT-EDIT banner**.
Regeneration is `tools/codegen.sh`. CI runs it and fails on any diff.

Three properties hold simultaneously:

1. The repo builds without running codegen (generated files are in the
   tree).
2. Hand-edits to generated files cannot survive a PR (CI re-runs codegen
   and `git diff --exit-code` fails on drift).
3. Adding or changing a Rust type without regenerating fails CI for the
   same reason — the committed Swift/TS no longer matches.

## Why

We've already lived the alternative. In a previous codebase
`AdjustmentModel` was hand-mirrored across three languages —
`raw-core/src/xmp.rs`, `MapleCore/Sources/MapleCore/AdjustmentModel.swift`,
and `web/projects/maple-common/src/lib/models/adjustment-model.ts`. The
defaults silently drifted: Swift initialised `sharpenAmount = 45`, Rust
initialised the same field to `0.0`, TypeScript to `0`. A
`// TODO codegen` comment in `webgl/pipeline.ts` was never actioned. The
three implementations produced visibly different output for the same
file. There was no CI signal because each language compiled cleanly on
its own.

Same era, related smell: `raw-ffi/src/lib.rs` ballooned to 2,477 lines.
A meaningful chunk of that bulk was a `strip_apple_gpu_stages` helper and
its supporting transforms — the C boundary trying to compensate for
Apple's specific Metal-kernel choreography. Platform-specific
choreography leaked into the FFI surface because the FFI layer was
allowed to define and reshape types. This spec disallows that pattern:
the FFI crate does not define types, period.

This spec exists so neither failure mode can recur from day 1.

## Scope boundary

**IN scope:** cross-language **internal value types** — types that live
in `raw-core` Rust and need Swift / TS equivalents because the same
value crosses the FFI or WASM boundary. Examples: `AdjustmentModel`,
`RenderRequest`, `PipelineParams`, `ColorMatrix3x3`.

**OUT of scope:**

- **HTTP DTOs.** Those are defined by Elysia route handlers and the
  TypeBox schemas next to them, with OpenAPI generated for clients.
  Different source of truth (TypeScript), different generator, different
  consumers (browser fetch / iOS networking). See
  `03-api-architecture.md`.
- **XMP sidecar schema.** The sidecar is its own contract with its own
  versioning rules — see `xmp-sidecar.md` (TBD).
- **Platform-specific UI types.** View models, presentational shapes,
  SwiftUI/Angular-side `*VM` structs. Each platform owns these in its
  own language.
- **The FFI memory contract.** Pointer ownership, alloc/free
  responsibilities, error marshalling, the lifetime of a borrowed
  buffer — `ffi-memory.md` (TBD).
- **Build orchestration.** When codegen runs in the overall build
  pipeline (pre-cargo, post-clone, etc.) belongs in the build spec when
  it exists.

If a type fits in both buckets — e.g. an HTTP DTO that contains an
`AdjustmentModel` — the inner Rust type is generated here; the outer DTO
is defined by spec 03's TypeBox schema and references the
codegen-emitted TS type by import.

## The `raw-core` ↔ `raw-ffi` boundary

This is the direct fix for the `strip_apple_gpu_stages` smell.

- **`raw-core`** defines every cross-language type. One module per type
  under `raw-core/src/types/`. Pure Rust, `serde`-derived,
  `#[derive(GenSwift, GenTs)]`. No FFI imports.
- **`raw-ffi`** holds **thin marshalling functions** — extern `"C"` fns
  that take pointers, deserialize JSON / read packed structs, call into
  `raw-core`, write the result back across the boundary. It re-exports
  types from `raw-core::types`; it does not define them.
- **`raw-wasm`** does the same on the WASM side via `wasm-bindgen`, also
  re-exporting `raw-core::types`.

A type defined inside `raw-ffi` is rejected in review. A platform-specific
transform inside `raw-ffi` ("strip these stages because Metal", "reshape
this array for SIMD") is rejected in review — that work belongs on the
consumer side (the Apple app deciding what to ask the core for) or
inside `raw-core` (a pipeline configuration parameter).

## Toolchain

Three generators, each doing one thing. The exact tools are the canonical
defaults; the spec leaves room to swap one out if it doesn't carry its
weight, but only by replacing it wholesale — never by adding a fourth.

| Output                      | Tool                                                |
| --------------------------- | --------------------------------------------------- |
| C headers (Apple)           | `cbindgen` → `.h`                                   |
| TS `.d.ts` (WASM surface)   | `wasm-bindgen` (via `wasm-pack`) → `pkg/*.d.ts`     |
| Swift `Codable` shims       | Custom proc-macro emit step (`#[derive(GenSwift)]`) |
| TS `interface` / type shims | Custom proc-macro emit step (`#[derive(GenTs)]`)    |

`cbindgen` and `wasm-bindgen` cover the FFI surface. They do **not**
emit:

- Swift `Codable` conformance with sensible defaults
- TypeScript `interface` shapes for `serde`-encoded JSON that crosses
  the boundary as bytes (not as `wasm-bindgen` argument values)

For those, a small custom emit step reads annotated Rust structs (via
proc macros `#[derive(GenSwift, GenTs)]` from a `codegen-derive` crate
inside the workspace) and writes the corresponding Swift / TS files.

**Why proc macros, not `serde_reflection` + a Python emitter:** the
rejected alternative parses Rust at runtime (slow, fragile across
compiler upgrades), needs a separate Python toolchain in CI, and pushes
all type fidelity through `serde_reflection`'s lossy mid-format —
defaults, doc comments, and `#[deprecated]` annotations disappear. The
proc-macro path keeps the emit step inside the Rust workspace, runs at
build time, sees the full token stream, and can preserve attribute-level
information end-to-end. More code to maintain initially; far more
type-safe to evolve.

If the proc-macro crate ever becomes a maintenance burden, the
replacement is one wholesale swap (e.g. a `cargo-expand`-based emitter
or a vendored fork of `serde-generate`) — not a second concurrent
generator.

## `tools/codegen.sh`

The canonical regeneration script. Idempotent: running it twice in a
row produces no diff. Lands in the same PR that introduces the first
cross-language type.

```bash
#!/usr/bin/env bash
# Regenerate all cross-language type bindings from `raw-core`.
# CI runs this then `git diff --exit-code`; any drift fails the build.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# 1. C headers for the Apple xcframework.
cbindgen \
  --config src/raw-pipeline/raw-ffi/cbindgen.toml \
  --crate raw-ffi \
  --output src/apple/Frameworks/RawPipeline.xcframework/Headers/raw_ffi.h

# 2. WASM bindings for the web. wasm-bindgen lives inside wasm-pack;
#    output goes into raw-wasm/pkg/ which Angular consumes directly.
( cd src/raw-pipeline/raw-wasm && wasm-pack build --target web --out-dir pkg )

# 3. Swift Codable shims + TS interface shims via the custom emit step.
#    The `codegen` binary lives in src/raw-pipeline/codegen/; it scans
#    `raw-core::types::*` and writes the emitted files in place.
cargo run --quiet --manifest-path src/raw-pipeline/codegen/Cargo.toml -- \
  --swift-out src/apple/Packages/ExposureCore/Sources/Generated \
  --ts-out    src/web/projects/maple-common/src/lib/raw-pipeline/generated

# 4. Formatters — generated files are formatted by the same rules as
#    hand-written files so the file-budget pre-commit hook and prettier
#    don't fight CI.
bunx prettier --write \
  src/web/projects/maple-common/src/lib/raw-pipeline/generated
xcrun swift-format format --in-place --recursive \
  src/apple/Packages/ExposureCore/Sources/Generated

echo "codegen: ok"
```

The script is the only sanctioned regeneration entry point. No hidden
"convenience" wrappers, no per-language sub-scripts that drift in
isolation — one script, all outputs, every time.

## Generated file layout

All committed paths. The directory names are stable; tooling (CI, the
emit step, downstream imports) hard-codes them.

| Output                          | Path                                                                |
| ------------------------------- | ------------------------------------------------------------------- |
| C headers                       | `src/apple/Frameworks/RawPipeline.xcframework/Headers/*.h`          |
| Swift `Codable` shims           | `src/apple/Packages/ExposureCore/Sources/Generated/*.swift`         |
| WASM bindings (`.js` + `.d.ts`) | `src/raw-pipeline/raw-wasm/pkg/`                                    |
| TS type shims                   | `src/web/projects/maple-common/src/lib/raw-pipeline/generated/*.ts` |

`src/raw-pipeline/raw-wasm/pkg/` is the only output where third-party
tooling owns the directory layout — `wasm-pack` writes the `package.json`,
the `.wasm` blob, and the `.js`/`.d.ts` glue together. Treat the whole
directory as generated.

## DO-NOT-EDIT banner

Every emitted file starts with the exact two lines below (in the
language's comment syntax). The banner names the regenerate command so a
reader who tries to edit immediately sees the fix:

```
// AUTO-GENERATED by tools/codegen.sh from raw-core::types — DO NOT EDIT.
// To change this file, edit the Rust type and re-run `tools/codegen.sh`.
```

Equivalent for `.ts` (`//`), Swift (`//`), and `.h` (`/* … */`). For
`raw-wasm/pkg/` output, `wasm-pack` controls the header; the spec's
contract is that the directory is treated as generated even though the
banner text differs.

## Generated files ARE committed

Two reasons, both load-bearing:

1. **The repo builds without running codegen.** Cloning, opening Xcode,
   running `bun install && bun x ng serve` — none of these require a
   Rust toolchain on a contributor's machine just to look at the Angular
   code or the SwiftUI views.
2. **Git diff is the drift signal.** With generated files in-tree, a
   stale `tools/codegen.sh` run shows up as a code-review artifact and a
   CI failure. With generated files out-of-tree, drift becomes invisible
   between runs.

The trade-off is repo size and noisier diffs on type changes. Both are
acceptable given the alternative (silent defaults drift across three
languages).

## CI workflow

A `codegen.yml` GitHub Actions workflow lives next to the existing
`cross.yml`:

```yaml
name: codegen
on:
  pull_request:
    paths:
      - 'src/raw-pipeline/**'
      - 'tools/codegen.sh'
      - '.github/workflows/codegen.yml'
  push:
    branches: [main]
    paths:
      - 'src/raw-pipeline/**'
      - 'tools/codegen.sh'

jobs:
  drift-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with: { components: rustfmt, clippy }
      - run: cargo install --locked cbindgen
      - uses: jetli/wasm-pack-action@v0.4.0
      - uses: oven-sh/setup-bun@v2
      - run: bash tools/codegen.sh
      - name: Fail on drift
        run: |
          if ! git diff --exit-code; then
            echo "::error::codegen drift detected — run tools/codegen.sh and commit."
            exit 1
          fi
```

Path filter so it only runs when `src/raw-pipeline/**` or
`tools/codegen.sh` itself changes. Lands with the **first** raw-pipeline
commit, not preemptively — there's nothing to check until there's a
`raw-core::types::` module to drift from.

## Defaults

Non-negotiable for new code:

- **All cross-language types live in `raw-core::types::`**, one module
  per type. `raw-core::types::adjustment_model`,
  `raw-core::types::render_request`, etc.
- **One type per file.** Clearer ownership, friendlier git history,
  smaller diffs when defaults change.
- **Field defaults are in Rust.** Use `#[serde(default = "…")]` or
  `Default` derived; the emit step propagates the value into Swift
  (initialiser default) and TS (interface optional with a constant in
  the same file).
- **Wire format is `camelCase` everywhere.** Apply
  `#[serde(rename_all = "camelCase")]` at the struct level. Do **not**
  use platform-specific `serde(rename = …)` to paper over case
  differences per consumer.
- **New fields are `#[serde(default)]`.** Older Swift / TS clients can
  decode newer payloads; CI re-emits the bindings with the new optional
  field.
- **No platform-specific shaping.** A field that exists in Rust exists
  in Swift and TS, with the same name and the same default.

## Anti-patterns

These are concrete things to reject in review:

- **Hand-mirrored types in another language.** The historical bug. A
  Swift struct that "mirrors" a Rust struct without being emitted by
  `tools/codegen.sh` is the bug; delete it and regenerate.
- **Editing a generated file.** The banner forbids it; CI catches it.
  If you need a change, edit the Rust source and re-run codegen.
- **Adding a Rust type in `raw-core::types::` without regenerating.**
  CI fails; rerun `tools/codegen.sh` and commit the output.
- **Manual `#[derive(Serialize, Deserialize)]` with platform-specific
  `serde(rename = …)`** intended to make a single field look different
  in one language. If the field needs to look different, the emit step
  needs to learn how to express that — but it almost never does.
- **Putting type definitions in `raw-ffi`.** Types live in `raw-core`;
  `raw-ffi` re-exports them. A `pub struct` inside `raw-ffi` is a smell.
- **Custom transforms at the FFI boundary that hide type changes from
  the codegen.** If the C boundary "fixes up" a struct on the way out,
  the Swift consumer sees something the codegen never described.
  Transform on the consumer side or in `raw-core`; the FFI is dumb.
- **A second concurrent generator.** Adding a third tool to the
  three-generator set ("just a small Python script for X") is rejected;
  the replacement is wholesale swap of one of the three.

## Code template (one canonical example)

A small surrogate for `AdjustmentModel` — exposure compensation and
sharpen amount — to keep the example self-contained.

**Rust source — `raw-core/src/types/exposure_adjustment.rs`:**

```rust
use serde::{Deserialize, Serialize};
use codegen_derive::{GenSwift, GenTs};

/// User-facing tone adjustments for a single render request.
///
/// Defaults are the no-op edit: no exposure change, no sharpening.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, GenSwift, GenTs)]
#[serde(rename_all = "camelCase")]
pub struct ExposureAdjustment {
    /// Exposure compensation in stops. Linear multiplier `2^value`.
    #[serde(default)]
    pub exposure_compensation: f32,

    /// Sharpening amount in ACR-equivalent units, [0, 150].
    #[serde(default)]
    pub sharpen_amount: f32,
}

impl Default for ExposureAdjustment {
    fn default() -> Self {
        Self {
            exposure_compensation: 0.0,
            sharpen_amount: 0.0,
        }
    }
}
```

**Generated C header — `src/apple/Frameworks/RawPipeline.xcframework/Headers/raw_ffi.h` (excerpt):**

```c
/* AUTO-GENERATED by tools/codegen.sh from raw-core::types — DO NOT EDIT.
 * To change this file, edit the Rust type and re-run `tools/codegen.sh`. */

typedef struct ExposureAdjustment {
    float exposure_compensation;
    float sharpen_amount;
} ExposureAdjustment;
```

**Generated Swift — `src/apple/Packages/ExposureCore/Sources/Generated/ExposureAdjustment.swift`:**

```swift
// AUTO-GENERATED by tools/codegen.sh from raw-core::types — DO NOT EDIT.
// To change this file, edit the Rust type and re-run `tools/codegen.sh`.

import Foundation

public struct ExposureAdjustment: Codable, Hashable, Sendable {
    public var exposureCompensation: Float
    public var sharpenAmount: Float

    public init(
        exposureCompensation: Float = 0.0,
        sharpenAmount: Float = 0.0
    ) {
        self.exposureCompensation = exposureCompensation
        self.sharpenAmount = sharpenAmount
    }
}
```

**Generated TypeScript — `src/web/projects/maple-common/src/lib/raw-pipeline/generated/exposure-adjustment.ts`:**

```ts
// AUTO-GENERATED by tools/codegen.sh from raw-core::types — DO NOT EDIT.
// To change this file, edit the Rust type and re-run `tools/codegen.sh`.

export interface ExposureAdjustment {
  exposureCompensation: number;
  sharpenAmount: number;
}

export const EXPOSURE_ADJUSTMENT_DEFAULTS: ExposureAdjustment = {
  exposureCompensation: 0.0,
  sharpenAmount: 0.0,
};
```

The three outputs agree on field names (`camelCase`), agree on default
values (`0.0`), and agree on the wire format that `serde_json` and the
TS `JSON.parse` will exchange across the FFI / WASM boundary. There is
no surface on which they can drift independently.

## Versioning

Internal types evolve. The rules are minimal because the codegen
shoulders most of the work.

- **Adding an optional field** is non-breaking. Annotate
  `#[serde(default)]`, regenerate, ship. Older Swift / TS clients still
  decode newer payloads (the new field is initialised to its default).
- **Adding a required field** is breaking. Stage it as optional first,
  populate everywhere, then promote to required in a follow-up.
- **Renaming a field** is breaking. Two-step: introduce the new name,
  emit both, mark the old name `#[deprecated]`, give consumers one
  release to migrate, then remove. The codegen emits the deprecation
  marker into Swift (`@available(*, deprecated, …)`) and TS (`/** @deprecated */`).
- **Changing a default value** is a behavioural break, even if the type
  is unchanged. Treat it like a renamed field: stage, document in the
  PR, give consumers a release to react.

The shape of a deprecation comment in Rust:

```rust
/// Sharpening amount.
///
/// **Deprecated** — use `sharpen_amount_v2` (matches ACR's new
/// `Sharpness` curve). To be removed after 0.5.0.
#[deprecated(since = "0.4.0", note = "use sharpen_amount_v2")]
#[serde(default)]
pub sharpen_amount: f32,
```

The emit step propagates the `#[deprecated]` attribute into Swift
(`@available(*, deprecated, message: "use sharpenAmountV2")`) and TS
(`/** @deprecated use sharpenAmountV2 */`).

## Relationship to OpenAPI codegen (spec 03)

Both `04-codegen` (this spec) and `03-api-architecture` are
"codegen from a source of truth," and both have a CI drift check. They
are deliberately **separate pipelines**:

- This spec generates **internal value types** from **Rust** in
  `raw-core` for Swift and TypeScript consumers.
- Spec 03 generates **HTTP client SDKs** from **TypeBox schemas** in
  Elysia routes for browser and iOS HTTP clients.

Different source of truth, different generator, different consumers,
different cadence. Merging them under one tool would force the wire
format on the HTTP boundary to match the FFI struct layout, which is the
wrong constraint — HTTP payloads care about evolution and backwards
compatibility on a network; FFI structs care about packed binary layout
and pointer ownership.

A type from `raw-core::types::` is permitted (and expected) to appear
inside an HTTP DTO. The HTTP DTO's TypeBox schema imports the generated
TS interface; the SDK consumer sees one consistent type.

## What this spec deliberately does not cover

Each gets its own spec when first implemented; do not extrapolate this
spec to cover them.

- **HTTP DTOs.** TypeBox + OpenAPI in Elysia routes →
  `03-api-architecture.md`.
- **XMP sidecar schema.** A separately versioned on-disk format with
  passthrough rules for unknown elements → `xmp-sidecar.md` (TBD).
- **DB schema.** Mongo collection shapes and repository pattern → spec
  03's repository section.
- **The FFI memory contract.** Pointer ownership, alloc/free, error
  marshalling, lifetime of borrowed buffers → `ffi-memory.md` (TBD).
- **Build orchestration.** When codegen runs in the build pipeline,
  whether `cargo build` should depend on `tools/codegen.sh`, how the
  xcframework is rebuilt → the build spec when it exists.
- **Visual / behavioural parity testing.** Per-platform pipeline
  output matching the Rust reference is a parity gate, not a codegen
  gate → `parity-testing.md` (TBD).

## When in doubt

- One source of truth beats two.
- Generated code beats hand-synced code.
- The Rust type is the source of truth; everything else is a derived
  artifact.
- `raw-ffi` re-exports; it does not define.
- If you're tempted to edit a generated file, you've found the bug —
  edit the Rust and regenerate.
