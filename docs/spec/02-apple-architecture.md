# 02 — Apple architecture

**Status:** Active.
**Applies to:** All Swift code under `src/apple/`.
**Scope:** SwiftUI screens (browse / view / select) and the state plumbing
behind them. **Editor state is out of scope** of this spec — see
`05-editor-state.md` for slider, undo/redo, and render coordination
patterns.

This spec is the Apple-side parallel to `01-frontend-architecture.md`. The
rule is the same; the primitives are SwiftUI's.

## The rule

Three slots, one job each.

| Slot                  | Primitive                                                                        | Holds                                                                              | Lifetime      |
| --------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------- |
| **App service**       | `@Observable final class` injected via `@Environment`                            | Remote, shared, or persistent data (libraries, photos, sidecars, server responses) | App / session |
| **Screen view-model** | `@State` of a small `@Observable` class, or a pure VM struct built inside `body` | Screen-scoped state with commands / async lifecycle                                | The screen    |
| **View-local state**  | `@State` primitive (`String?`, `Bool`, enum)                                     | Ephemeral UI state (selection, hover, expand/collapse, search input)               | The view      |

Derivation between them is a **pure function** (or a computed property) that
returns a `ViewModel` struct consumed by `body`. The VM is co-located with
the view as a sibling `*+VM.swift` file and tested as a function, not via
ViewInspector or snapshot.

## Why this split

Same story as the web side. One view grew to 1,950 lines holding session +
render coordination + undo + asset I/O + source-agnostic adapters. The
file became untouchable. Splitting along **what kind of state is this**
makes the boundaries mechanical:

- "Would another screen want this?" → app service.
- "Does this survive the screen being torn down?" → app service or screen VM.
- "Is this just the user clicking around?" → `@State` primitive.
- "Is this a derived projection of the above?" → VM function called from
  `body`.

## Conceptual structure of a screen

```
PhotoGalleryView
├── @Environment(LibraryStore.self)   ← app service (data)
├── @Environment(PhotoStore.self)     ← app service (data)
├── @State selectedLibraryID = nil    ← UI state (component-local)
├── body { let vm = buildVM(...);     ← pure derivation
│         render(vm) }
└── PhotoGalleryView+VM.swift         ← pure function + VM type
```

The view's `body` reads stores + `@State`, calls one VM builder, and
returns view code. It does not perform I/O, does not handle errors itself
(it shows the state the store reports), and does not branch into
sub-renders bigger than a few lines without extracting a sub-view.

## Co-located view models

Every view with non-trivial derivation has a sibling `*+VM.swift`:

```
PhotoGalleryView.swift
PhotoGalleryView+VM.swift          ← pure function + VM type
PhotoGalleryView+Previews.swift    ← #Preview blocks (see next section)
PhotoGalleryViewVMTests.swift      ← XCTest of the function, no UI
```

The VM builder takes plain values (arrays, primitives, the selection
state), returns the shape the view wants, and imports nothing from
SwiftUI. Tests run as plain XCTest cases against the function, not via UI
harness.

## View previews: `#Preview`

Every `View` has at least one `#Preview` block. Views with meaningfully
different states get a `#Preview` per state. Xcode Previews are the
canonical "isolated view" harness for SwiftUI; no third-party tool
(Storybook-equivalent, Component-kit, etc.) is introduced — the framework
support is sufficient and the previews are also build-validated by Xcode.

### Required previews per view

| Preview (named) | When                                                           |
| --------------- | -------------------------------------------------------------- |
| `"Default"`     | Always. The view in its typical state.                         |
| `"Loading"`     | If the view shows a loading state.                             |
| `"Empty"`       | If the view can render with no data.                           |
| `"Error"`       | If the view handles an error state.                            |
| `"EdgeCases"`   | Long text, missing images, extreme values — author discretion. |

Use the new `#Preview("name")` macro; the label appears in the Xcode
canvas selector. Skip previews only for trivial leaf views with no
meaningful state (e.g. a static icon).

### Stub stores via `.preview(...)` factories

Each `@Observable` app service exposes a `static func preview(...)` that
returns a pre-populated instance. The factory lives in the same file as
the service. Views inject stubs into previews via `.environment(...)` the
same way the app does at the root:

```swift
// In LibraryStore.swift
extension LibraryStore {
    static func preview(
        libraries: [Library] = [.sample, .sample2],
        isLoading: Bool = false
    ) -> LibraryStore {
        let store = LibraryStore(repository: .preview)
        store.applyForPreview(libraries: libraries, isLoading: isLoading)
        return store
    }
}

// In PhotoGalleryView+Previews.swift
#Preview("Default") {
    PhotoGalleryView()
        .environment(LibraryStore.preview())
        .environment(PhotoStore.preview())
}

#Preview("Loading") {
    PhotoGalleryView()
        .environment(LibraryStore.preview(isLoading: true))
        .environment(PhotoStore.preview(isLoading: true))
}

#Preview("Empty") {
    PhotoGalleryView()
        .environment(LibraryStore.preview(libraries: []))
        .environment(PhotoStore.preview(photos: []))
}
```

The `.preview` factory is the only sanctioned way to construct stub
stores. Hand-rolled `LibraryStore(...)` calls inside previews are a smell
— they leak production wiring into a preview file.

### Preview traits

Pin layout for screen-level views so previews render at a realistic size
instead of intrinsic-content shrinking:

```swift
#Preview("macOS Default", traits: .fixedLayout(width: 1200, height: 800)) {
    PhotoGalleryView()
        .environment(LibraryStore.preview())
}
```

For per-platform divergence, name the preview accordingly
(`"macOS Default"`, `"iPad Default"`).

### Catalog views

For a "wall of views" overview (the Storybook screen-wall use case),
build a one-off `PreviewCatalogView` that arranges target screens in a
`LazyVStack`. Don't reach for a third-party tool.

### CI gate

`xcodebuild` automatically validates that all `#Preview` blocks compile.
That's the contract: previews must build. Visual rendering is checked by
the XCUITest visual harness for chrome screens; a per-screen visual
regression layer is deferred.

## Defaults

Non-negotiable for new code:

- **`@Observable` (Observation framework).** Never `ObservableObject` /
  `@Published` / `@StateObject` / `@ObservedObject` /
  `@EnvironmentObject` in new code. The deployment target supports
  Observation; use it.
- **`@MainActor`** on every class that touches UI or is read by `body`.
  Application services (`LibraryStore`, `PhotoStore`, screen VMs) are
  `@MainActor`. I/O machinery (repositories, file handles, network
  clients) lives on its own actor and crosses to `@MainActor` only at the
  return.
- **`@State` for view-local primitives.** Never a reference type in
  `@State` — that's a `@Bindable` / `@Environment` smell.
- **`@Environment(Service.self)`** for app services. `@Bindable` when you
  need two-way binding into an environment object.
- **`.task { … }` modifier** for async work attached to a view. Never
  `.onAppear { Task { … } }` — `.task` auto-cancels on disappear and
  participates in structured concurrency.
- **`.task(id: someValue)`** when the work must re-run on input change.
- **Actor-isolated I/O.** Anything that hits disk, network, sidecar, or
  Mongo lives in an `actor` (or is `@MainActor`-isolated for trivial UI
  state). No raw `DispatchQueue` for new code.
- **Generation-counter guards** for cancellable async state. When a screen
  issues a load, bump a counter; when the response arrives, drop it on
  the floor if the counter has advanced. (See existing
  `EditSession.generation` precedent.)
- **Accessibility identifiers** on every interactive element. UI tests
  read the accessibility tree, not screen coordinates.
- **No force unwraps (`!`)** outside test fixtures.
- **`os.Logger`**, not `print()`, in app code.
- **Strict concurrency.** Build with
  `SWIFT_STRICT_CONCURRENCY = complete` (warning ladder while migrating,
  error once a target is clean).
- **`Sendable` audit.** Anything crossing an actor boundary is `Sendable`
  or has a documented `@unchecked Sendable` justification.
- **Separate files** for separate views. `body` for a screen should fit on
  one editor page (~80 lines). Extract sub-views, not `@ViewBuilder`
  private vars, once it grows.

## The escalation ladder

When state outgrows its current slot, walk **up** one rung. Never start
higher than you need.

1. **`@State` primitive** — default for any UI state.
2. **`@State` of a small `@Observable` screen VM class** — when the
   screen has commands, async, or non-trivial derivation.
3. **`@Environment(SomeService.self)`** — when a second screen needs the
   same state.
4. **SPM sub-package** under `src/apple/Packages/` — when a domain has
   more than ~3 files of shared state + logic. (`ExposureCore` is the
   ground-floor package; promote new domains into siblings rather than
   piling into `ExposureCore`.)

The cheapest refactor in SwiftUI is `@State` → `@Environment`. **Defer.**
Promoting state too early makes its shape harder to change than a local
`@State` does.

## Anti-patterns

These are concrete things to reject in review:

- **`ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` /
  `@EnvironmentObject` in new code.** Use `@Observable` + `@State` /
  `@Environment` / `@Bindable`.
- **God-view (>400 lines).** Symptom of state + layout + I/O collapsing
  into one type. Split into sub-views and a screen VM.
- **File / network / sidecar I/O inside `body` or `View` methods.** All
  I/O goes through an actor-isolated service; the view reads its result
  from an `@Observable` field.
- **Singletons pretending to be services.** Never `static let shared`.
  Inject via `@Environment` so tests can substitute.
- **Inline `Task { … }` in `.onAppear`.** Use `.task { }` so cancellation
  is structured.
- **Combine pipelines for new async work.** Use `async/await` and
  `AsyncSequence`. Combine remains acceptable when interoperating with
  Apple framework APIs that only expose `Publisher`s, but don't reach for
  it for green-field code.
- **`@Binding` chains** more than one level deep. Pass a `@Bindable` value
  or pass a closure; don't propagate a `@Binding` through three views.
- **`AnyView`.** Almost always a sign that the view is over-generic; use
  `@ViewBuilder` or extract a typed sub-view.
- **Force unwraps (`!`).** Pattern-match or fail loudly with `fatalError`
  carrying a message.
- **Conditional compilation (`#if os(macOS)`) inside large views.** Push
  the divergence to per-platform files when it spans more than a few
  lines.
- **`print()` in app code.** Use `os.Logger` so output goes to the unified
  log with subsystem + category tags.

## SPM module boundaries

Pure Swift goes in SPM packages under `src/apple/Packages/`. SwiftUI shell
code lives in the Xcode app target.

- **`ExposureCore`** — pipeline glue, sidecar model + I/O, source
  adapters (filesystem / PhotoKit / cloud), caches. Pure Swift, no
  `SwiftUI` import.
- **`ExposureFileProvider`** (eventually) — the File Provider extension
  isolated as its own target, with shared types pulled from
  `ExposureCore`.
- **App target** — SwiftUI views, scene/navigation plumbing, app
  lifecycle. Imports `ExposureCore`.

A new feature graduates to its own SPM module once it has more than ~3
files of state/logic; until then it's a folder in `ExposureCore` or in the
app target.

## Code template (one canonical example)

A typical browse-style screen. The exact store API varies; the **shape**
does not.

```swift
// PhotoGalleryView.swift
import SwiftUI

struct PhotoGalleryView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PhotoStore.self) private var photoStore

    // UI state — ephemeral, view-local.
    @State private var selectedLibraryID: String?

    var body: some View {
        let vm = buildPhotoGalleryVM(
            libraries: libraryStore.libraries,
            photos: photoStore.photos,
            selectedLibraryID: selectedLibraryID,
            isLoading: libraryStore.isLoading || photoStore.isLoading
        )

        VStack(spacing: 0) {
            toolbar(vm: vm)
            content(vm: vm)
        }
        .task {
            async let libs: () = libraryStore.load()
            async let pix: () = photoStore.load()
            _ = await (libs, pix)
        }
    }

    @ViewBuilder
    private func toolbar(vm: PhotoGalleryVM) -> some View {
        HStack {
            Picker("Library", selection: $selectedLibraryID) {
                Text("All libraries").tag(String?.none)
                ForEach(vm.libraries) { lib in
                    Text("\(lib.name) (\(lib.photoCount))").tag(String?.some(lib.id))
                }
            }
            .accessibilityIdentifier("library-picker")
            Spacer()
            Text("\(vm.totalCount) photos")
        }
        .padding()
    }

    @ViewBuilder
    private func content(vm: PhotoGalleryVM) -> some View {
        if vm.isLoading {
            ProgressView("Loading…")
                .accessibilityIdentifier("loading-indicator")
        } else if vm.isEmpty {
            ContentUnavailableView("No photos in this library", systemImage: "photo")
        } else {
            PhotoGridView(tiles: vm.tiles)
        }
    }
}
```

```swift
// PhotoGalleryView+VM.swift — pure functions, no SwiftUI import.
import Foundation

struct PhotoGalleryVM {
    var libraries: [LibrarySummary]
    var tiles: [PhotoTile]
    var totalCount: Int
    var isLoading: Bool
    var isEmpty: Bool
}

func buildPhotoGalleryVM(
    libraries: [Library],
    photos: [Photo],
    selectedLibraryID: String?,
    isLoading: Bool
) -> PhotoGalleryVM { /* … */ }
```

```swift
// LibraryStore.swift — app service.
import Foundation
import Observation

@Observable
@MainActor
final class LibraryStore {
    private(set) var libraries: [Library] = []
    private(set) var isLoading: Bool = false

    private let repository: LibraryRepository
    private var loadGeneration: Int = 0

    init(repository: LibraryRepository) {
        self.repository = repository
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let result = try await repository.fetchAll()
            guard generation == loadGeneration else { return }  // stale
            libraries = result
        } catch {
            guard generation == loadGeneration else { return }
            // Surface to a shared error sink — never silently swallow.
        }
    }
}

actor LibraryRepository {
    private let http: HTTPClient
    init(http: HTTPClient) { self.http = http }

    func fetchAll() async throws -> [Library] {
        try await http.get("/libraries")
    }
}
```

## Wiring at the app root

App services are constructed once and injected into the environment:

```swift
@main
struct ExposureApp: App {
    @State private var libraryStore = LibraryStore(repository: LibraryRepository(http: .default))
    @State private var photoStore = PhotoStore(repository: PhotoRepository(http: .default))

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(libraryStore)
                .environment(photoStore)
        }
    }
}
```

For previews and tests, construct stubs and inject the same way.

## What this spec deliberately does not cover

Each gets its own spec when first implemented; do not extrapolate this
spec to cover them.

- **Editor state** — slider drags at 60 Hz, undo/redo stacks, two-phase
  rendering, render-phase cancellation, mid-edit XMP. →
  `05-editor-state.md`.
- **Metal pipeline** — Metal kernels, command-buffer scheduling, GPU
  resource lifetime. → `color-pipeline.md` (TBD).
- **File Provider extension** — extension lifecycle, capabilities, sandbox
  boundary, the apple/server bridge. → `file-provider.md` (TBD).
- **Cross-platform parity** — how Apple consumes the shared Rust core, how
  Swift constants are kept in sync with Rust/TS. → `codegen.md` (TBD).
- **Navigation / deep links** — `NavigationStack`, scene restoration,
  universal links. → `navigation.md` (TBD).

## When in doubt

- Smaller files beat bigger files.
- `@State` beats `@Environment` beats SPM module.
- Pure functions beat reactive plumbing.
- One render trigger (`vm` from `buildVM`) beats many scattered reads.
- Promote on demand, never on speculation.
