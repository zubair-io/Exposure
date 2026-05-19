# 05 — Editor state

**Status:** Active.
**Applies to:** All editor-mode code in `src/web/` and `src/apple/`.
**Scope:** Slider drags, undo/redo, two-phase rendering, render cancellation,
and the mid-edit sidecar write loop. Browse / view / select state is
**out of scope** — see `01-frontend-architecture.md` and
`02-apple-architecture.md`.

This is the spec the two architecture specs deliberately punted to. It is
the hardest of the foundational specs because it is exactly where we grew
god-objects last time.

## The rule

Editor state is **three layers**, not one. Each layer has one owner per
platform, one obvious API surface, and is independently testable.

| Layer                   | Responsibility                                                                                                            | Lifetime               |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| **Render coordination** | Owns the GPU/canvas. One source of truth for "what is being drawn right now." Two-phase, cancellable, generation-guarded. | Editor session         |
| **Edit state**          | Live working values — current adjustments, selection, active tool. UI-facing, fast, no GPU coupling.                      | Edit session per image |
| **History**             | Undo/redo as a discrete data structure: `apply(op)` / `undo()` / `redo()`. Diff-based, not snapshots.                     | Edit session per image |

Render coordination subscribes to edit state. History mutates edit state.
The view reads edit state through its VM (per the patterns in specs 01 and
02). No layer reaches across another to do its job.

## Why three layers

We've already lived the alternative. One Swift type, `EditSession`, grew to
1,950 lines holding session lifecycle, render scheduling, undo stack, asset
I/O, culling, and source-agnostic adapters. The web equivalent,
`library-state.service.ts`, was 1,621 lines collapsing browse, cache, and
edit. The `PipelineRenderer` next door was 956 lines of Metal dispatch plus
scheduling plus quality. None of this was independently testable; none of
it was independently replaceable; everything in it became coupled to
everything else.

Splitting along **what kind of state is this** makes the boundaries
mechanical:

- "Does this drive pixels onto a surface?" → render coordination.
- "Is this the user's current working value?" → edit state.
- "Is this a record of how we got here?" → history.

Each layer:

- has one obvious owner per platform,
- has a small, documented API surface (the contract),
- is testable as a unit (render: against a fake pipeline; edit state: as a
  data type; history: as a pure function over an operation log),
- composes via subscription, not by reaching imperatively into a sibling.

The litmus test: if a single new class wants to expose `render()`,
`setExposure()`, and `undo()` on its public surface, it has already failed
this spec.

## Render coordination contract

The render coordinator owns the GPU surface — the WebGL2 canvas on web, the
Metal command queue on apple — and nothing else owns it. Edit state does
not know it exists; the view talks to it only to read the current frame
status.

### Request shape

```
RenderRequest {
  adjustments:  AdjustmentModel,   // value-typed snapshot of the slider state
  viewport:     Viewport,          // pixel size + DPR
  generation:   u64,               // monotonically increasing
  phase:        Fast | Refine,
}
```

`adjustments` is **value-typed**. Coordinator never holds a reference into
edit state — it gets a snapshot at the moment of dispatch.

### Two phases

| Phase      | Resolution      | Cancellable | Debounce        | Goal                                   |
| ---------- | --------------- | ----------- | --------------- | -------------------------------------- |
| **Fast**   | Viewport-sized  | Yes         | None (per tick) | New preview inside one frame (~16 ms)  |
| **Refine** | Full resolution | Yes         | 150 ms idle     | Final-quality pass when the user stops |

The fast phase fires on every edit-state change while the user is
interacting. The refine phase fires 150 ms after the last edit-state change,
once the slider is at rest. A new fast request cancels the pending refine —
the refine timer only starts again when the next idle window opens.

### Generation counter

Every request carries a generation number. The coordinator bumps the
counter on each new request and checks it on every response. A response
whose generation is stale is dropped on the floor — never blitted, never
cached. This is non-negotiable; without it, an in-flight refine can land
_after_ a faster newer fast and paint last-frame pixels over the user's
current scrubbing.

The Swift app already had this pattern in `EditSession.generation` and the
web app needs the same idea. Both platforms expose it the same way: a
single `u64` counter inside the coordinator, incremented before dispatch.

### Cancellation and backpressure

- Fast renders are cancellable mid-flight — the coordinator signals the
  GPU layer to abandon work in progress.
- Refine renders are cancelled by any newer fast request.
- **Backpressure:** at most one fast render in flight + one queued. If a
  third arrives while the queue is occupied, the queued one is **replaced**
  (newest wins). Old request data is not interesting; only the latest user
  intent is.

The 16 ms slider budget exists because of this: the coordinator must clear
its queue inside one frame, or the user sees stutter.

### Web subsection

`RenderService` is an Angular `@Injectable({ providedIn: 'root' })` (or, if
scoped per editor route, a route-level provider). It is injected into the
editor component and into nothing else.

- Owns the `WebGL2RenderingContext` and the raw-wasm bindings.
- Exposes `currentFrame: Signal<RenderedFrame | null>` and
  `status: Signal<RenderStatus>` for the view to read via its VM.
- Exposes `request(req: RenderRequest): void`. Synchronous, fire-and-forget.
- Owns the debounce timer for the refine phase internally; consumers do not
  pass debounce ms.
- The canvas drawing buffer is tagged `colorSpace: 'srgb'`. Wide-gamut
  browsers shift warm tones pink without it — this is project lore, not a
  knob.

### Apple subsection

`RenderActor` is a Swift `actor` constructed once per editor session and
held by the screen VM. It is not an app service — it is screen-scoped.

- Owns the `MTLCommandQueue`, the per-image Metal textures, and the FFI
  handle into `raw-core`.
- Exposes `currentFrame: RenderedFrame?` and `status: RenderStatus` as
  `@Observable` properties on a sibling `@MainActor` view-facing wrapper
  (`RenderActor` itself is not `@Observable` — it's off the main actor).
- Exposes `func request(_ req: RenderRequest) async` and an internal queue.
- Hands frames back to `@MainActor` for display. The view never awaits the
  actor directly; it reads the wrapper's published frame field.
- Integrates with the strict-concurrency build setting per spec 02. Every
  type that crosses the boundary is `Sendable`.

## Edit state contract

Edit state is the user's current working values: the live adjustments, the
current selection, the active tool. It is what the sliders are bound to,
what the inspector reads, what serializes to the sidecar.

It does **not** know about the GPU, command buffers, debouncing, or
history. It is a plain data carrier with mutators.

### Web subsection

Edit state lives in screen-scoped signals exposed by an `EditSession`
service provided at the editor route:

```ts
@Injectable() // route-scoped
export class EditSession {
  readonly adjustments = signal<AdjustmentModel>(AdjustmentModel.default());
  readonly selection = signal<Selection>(Selection.none());
  readonly tool = signal<Tool>('exposure');

  setExposure(ev: number): void {
    this.adjustments.update((m) => ({ ...m, exposure: ev }));
  }
  // … one mutator per field.
}
```

Sliders write directly via the mutators. Reactivity wakes the render
service through a `computed()` it subscribes to. **The template never reads
`adjustments()` directly** — it reads the editor view model, per spec 01.

### Apple subsection

Edit state is a `@MainActor` `@Observable` class exposed via
`@Environment`:

```swift
@Observable
@MainActor
final class EditSession {
    private(set) var adjustments: AdjustmentModel = .default
    private(set) var selection: Selection = .none
    private(set) var tool: Tool = .exposure

    func setExposure(_ ev: Double) {
        adjustments.exposure = ev
    }
    // … one mutator per field.
}
```

Mutators are methods, not direct `var` assignments by callers. The
`private(set)` ensures the view layer cannot bypass the mutator — every
write goes through a known surface, which is what history hooks into.

### Cross-platform rule

Edit state is **read by the VM builder, never directly by the template /
`body`**. This is the same rule as specs 01 and 02. The reason is the same:
one render trigger, one thing to unit-test, no hidden subscriptions.

## Undo/redo contract

History is an append-only operation log with a cursor.

### Shape

```
type Operation = {
  kind:      OperationKind,   // 'setExposure' | 'setContrast' | 'reset' | 'pastePreset' | ...
  prevValue: Json,            // value before
  nextValue: Json,            // value after
  timestamp: ISO8601String,
};

type History = {
  operations: Operation[],
  cursor:     number,         // index of the next operation slot
};
```

- `apply(op)`: mutates edit state, appends `op`, advances cursor, **clears
  any forward operations** past the cursor (standard redo semantics).
- `undo()`: applies `prevValue` of the operation at `cursor - 1`, decrements
  cursor.
- `redo()`: applies `nextValue` of the operation at `cursor`, increments
  cursor.

### Why diff-based, not snapshots

A 100 MP RAW round-tripped through the full pipeline can produce hundreds
of MB of intermediate state. Snapshotting edit state per operation is
cheap, but if we ever extend "edit state" to include derived caches, the
snapshot model rots immediately. Worse, the team's instinct under the
snapshot model is "snapshot the rendered preview" — at which point undo is
gigabytes.

Diff-based ops avoid all of this. An op carries the field's old and new
value only. Undoing 200 operations costs 200 small struct writes, not
200 frame buffers.

### Append-only forward; redo cleared on new op

This is the standard editor semantic. If the user undoes three steps and
then changes a slider, the three undone ops are gone. We do not attempt
branching history. (If we add it later, it's a separate spec.)

### Web subsection

```ts
@Injectable() // route-scoped, sibling to EditSession
export class HistoryService {
  private readonly operations = signal<Operation[]>([]);
  private readonly cursor = signal(0);

  readonly canUndo = computed(() => this.cursor() > 0);
  readonly canRedo = computed(() => this.cursor() < this.operations().length);

  commit(op: Operation): void {
    /* truncate forward, append, advance */
  }
  undo(): void {
    /* apply prev, decrement */
  }
  redo(): void {
    /* apply next, increment */
  }
}
```

`HistoryService` does **not** import the WebGL context or call the render
service. It mutates `EditSession`; the render service picks up the change
via its existing subscription. One direction, no cycles.

### Apple subsection

```swift
@Observable
@MainActor
final class History {
    private(set) var operations: [Operation] = []
    private(set) var cursor: Int = 0

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < operations.count }

    func commit(_ op: Operation, into session: EditSession) { /* … */ }
    func undo(into session: EditSession)                    { /* … */ }
    func redo(into session: EditSession)                    { /* … */ }
}
```

`History` and `EditSession` are both `@MainActor`. History methods take the
session explicitly rather than holding a reference — keeps the
dependency direction visible and makes the type trivially testable with a
freshly-built session.

### Testability

History is testable as a pure function over an operation log:

```
applyAll(initialState, operations[0..cursor]) == currentState
```

Tests build a sequence of ops, fold them, and assert. No GPU, no XMP, no
Angular / SwiftUI. This is the entire point of separating the layer.

## Slider-drag semantics (the hard case)

The user drags an exposure slider for 800 ms. The render coordinator sees
~50 ticks. The history should record **one** operation, not 50. The XMP
should be written **once**, after the drag settles.

### Lifecycle

1. **`drag-start`** — capture `prevValue` from edit state. Do NOT commit
   anything to history yet.
2. **Tick (60 Hz)** — write the new value to edit state via its mutator.
   Edit state's signal/`@Observable` change wakes the render service. Fast
   phase fires. **No history write. No XMP write.**
3. **`drag-end`** — capture `nextValue` from edit state. Commit ONE op to
   history: `{ kind, prevValue, nextValue }`. The refine timer is already
   running off the last tick; it fires 150 ms later.
4. **After 500 ms of edit-state idle** — sidecar writer serializes the
   current adjustments and flushes to disk.

If the user drags, stops, and immediately drags again before the 500 ms
window elapses, the sidecar timer **resets**. We don't want a half-written
state on disk in the middle of an interaction.

### Web

Sliders emit drag-start / input / drag-end as DOM events. A small adapter
maps these to the lifecycle:

```ts
// In the slider component.
onPointerDown() { this.editSession.beginDrag('exposure'); }
onInput(v: number) { this.editSession.setExposure(v); }   // every tick
onPointerUp(v: number) { this.editSession.endDrag('exposure', v); }
```

`beginDrag` records `prevValue` in a transient field. `endDrag` builds
the op and hands it to `HistoryService.commit(...)`. Single keyboard nudges
(arrow keys) skip the begin/end pair and call `commit(...)` directly with
`prevValue` = current, `nextValue` = nudged.

### Apple

SwiftUI's `Slider` doesn't expose drag begin/end natively. Wrap with
`DragGesture` or use `onEditingChanged: (Bool) -> Void`:

```swift
Slider(value: bindingForExposure, in: -5...5, onEditingChanged: { editing in
    if editing {
        editSession.beginDrag(.exposure)
    } else {
        editSession.endDrag(.exposure, value: editSession.adjustments.exposure)
    }
})
```

`bindingForExposure` is a custom `Binding` that calls `editSession.setExposure(_:)`
in its setter — no per-tick history side effect. The `editing` flag from
SwiftUI is the begin/end signal.

### Reset / paste preset

These are single ops that touch multiple fields. The op kind is
`reset` or `pastePreset`; `prevValue` and `nextValue` are full
`AdjustmentModel`s. One op, one history entry, regardless of how many
fields changed.

## Sidecar (XMP) write semantics

Edits go to `.xmp` sidecars; originals are never touched. (This is a
project invariant, not an editor-state choice.) The question is **when** to
write.

### Rules

- **No write per slider tick.** Disk doesn't care; the user's edit isn't
  semantically committed yet.
- **500 ms debounce** after the last edit-state change. If the user is
  actively dragging, the timer keeps resetting; we only write when they
  settle.
- **Flush immediately on:**
  - app background / window close / before navigation away,
  - explicit save action,
  - opening a different image (writes the previous image's pending state
    before swapping).

### Web

`SidecarWriter` is an Angular service. The XMP serialization runs on the
main thread today (we don't have a Worker pool yet); if profiling shows
serialization stalling the slider, that's the trigger to move it into a
Worker. The IndexedDB write is async by nature.

```ts
@Injectable()
export class SidecarWriter {
  private debounce?: ReturnType<typeof setTimeout>;

  scheduleWrite(image: ImageRef, model: AdjustmentModel): void {
    clearTimeout(this.debounce);
    this.debounce = setTimeout(() => this.flush(image, model), 500);
  }
  async flush(image: ImageRef, model: AdjustmentModel): Promise<void> {
    /* serialize XMP, write */
  }
}
```

Edit state subscribes the writer to its own changes (a single `effect()` in
the editor component, not in the service — keeps the writer pure).

### Apple

`SidecarWriter` is an `actor`. The 500 ms debounce is a Swift `Task` with a
`Task.sleep` that is cancelled and re-issued on each new change:

```swift
actor SidecarWriter {
    private var pending: Task<Void, Never>?

    func scheduleWrite(for image: ImageRef, model: AdjustmentModel) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self.flush(image: image, model: model)
        }
    }
    func flush(image: ImageRef, model: AdjustmentModel) async { /* serialize, write */ }
}
```

Flush-on-background is wired by the screen VM observing `ScenePhase` (or
the equivalent app-lifecycle hook) and calling `flush(...)` directly,
bypassing the debounce.

### Testing

Per `CONTRIBUTING.md` § Testing: **no mocks for the sidecar layer**.
Tests round-trip against real `.xmp` files in a temp directory created by
the test. The sidecar is the contract; mocks let bugs through. This applies
to both `apple/` and `web/`.

## Anti-patterns

Reject in review.

- **Putting render coordination + edit state + history in one class.** The
  `EditSession.swift` smell — it's the literal reason this spec exists.
- **Snapshot-based undo.** Memory bloat for 100 MP RAWs; rots when "state"
  grows to include caches. Diff ops only.
- **Pushing every slider tick to history.** History pollution; undo becomes
  unusable. One op per gesture.
- **Writing XMP on every tick.** Disk thrash, sub-millisecond writes
  pointless. 500 ms debounce, always.
- **Reading from history during render.** History is the mutation log, not
  state. The renderer reads edit state. If you find yourself reading
  `history.operations` to figure out what to draw, you have inverted the
  layers.
- **Edit state outside `@MainActor` in Swift.** UI race conditions, period.
- **Render service / actor reaching into edit state imperatively** (polling,
  direct field reads in a loop). Subscribe via signals / `@Observable`;
  reactivity is the contract.
- **Mocking the sidecar layer in tests.** Real files, temp dir, round-trip.
- **Render request without a generation counter.** Stale frames will land
  out of order under any real workload; this is not optional.
- **Holding a reference to `EditSession` inside `RenderActor` /
  `RenderService` for direct field access.** The render layer subscribes to
  reactive values; it does not call `editSession.adjustments.exposure`
  directly. Keeping the dependency reactive is what allows the renderer to
  be replaced or tested independently.
- **Two-way coupling between History and Render.** History mutates edit
  state. Render reads edit state. History never calls render directly; if
  the renderer needs to know an undo happened, it learns through the edit
  state change.

## Code template (web and apple side-by-side)

Worked example: the user drags the exposure slider from `0.0` to `+1.0` over
~800 ms, then stops.

### Web

```ts
// editor.component.ts
@Component({
  selector: 'app-editor',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [EditSession, HistoryService, SidecarWriter, RenderService],
  templateUrl: './editor.component.html',
  styleUrl: './editor.component.scss',
})
export class EditorComponent {
  protected readonly editSession = inject(EditSession);
  protected readonly history = inject(HistoryService);
  private readonly render = inject(RenderService);
  private readonly sidecar = inject(SidecarWriter);

  // VM, per spec 01.
  protected vm = computed<EditorVM>(() =>
    buildEditorVM({
      adjustments: this.editSession.adjustments(),
      selection: this.editSession.selection(),
      tool: this.editSession.tool(),
      canUndo: this.history.canUndo(),
      canRedo: this.history.canRedo(),
      frame: this.render.currentFrame(),
      status: this.render.status(),
    }),
  );

  constructor() {
    // Reactivity wires the renderer + sidecar to edit state. One arrow each.
    effect(() => {
      const model = this.editSession.adjustments();
      this.render.request({ adjustments: model, viewport: this.viewport(), phase: 'Fast' });
      this.sidecar.scheduleWrite(this.imageRef(), model);
    });
  }
}
```

```ts
// exposure-slider.component.ts (excerpt)
onPointerDown() { this.editSession.beginDrag('exposure'); }
onInput(ev: Event) {
  const v = (ev.target as HTMLInputElement).valueAsNumber;
  this.editSession.setExposure(v);          // tick → effect → render.request(Fast)
}
onPointerUp() {
  const op = this.editSession.endDrag('exposure');
  this.history.commit(op);                  // one op, regardless of tick count
}
```

### Apple

```swift
// EditorView.swift
struct EditorView: View {
    @State private var editSession = EditSession()
    @State private var history = History()
    @State private var render = RenderCoordinator()        // @MainActor wrapper around RenderActor
    @State private var sidecar = SidecarWriter()

    var body: some View {
        let vm = buildEditorVM(
            adjustments: editSession.adjustments,
            selection: editSession.selection,
            tool: editSession.tool,
            canUndo: history.canUndo,
            canRedo: history.canRedo,
            frame: render.currentFrame,
            status: render.status
        )

        EditorChromeView(vm: vm)
            .onChange(of: editSession.adjustments) { _, newValue in
                render.request(.init(adjustments: newValue, viewport: vm.viewport, phase: .fast))
                Task { await sidecar.scheduleWrite(for: vm.imageRef, model: newValue) }
            }
    }
}
```

```swift
// ExposureSlider.swift (excerpt)
Slider(
    value: Binding(
        get: { editSession.adjustments.exposure },
        set: { editSession.setExposure($0) }      // tick → onChange → render.request(.fast)
    ),
    in: -5...5,
    onEditingChanged: { editing in
        if editing {
            editSession.beginDrag(.exposure)
        } else {
            let op = editSession.endDrag(.exposure)
            history.commit(op, into: editSession)  // one op, regardless of tick count
        }
    }
)
```

What both share:

- The slider talks to edit state. Nothing else.
- Edit state's change drives render (via subscription) and sidecar (via
  subscription). The slider does not know either exists.
- History records once per gesture, at `endDrag`.
- The view reads through a VM, never directly from any of the three layers.

## Performance contract

The slider tick budget is **16 ms** target, **50 ms** hard limit, on the
reference scene set (a 100 MP Hasselblad L3D-100c RAW is the reference).
This applies to the fast phase only — the refine phase is allowed to take
as long as the full-resolution render genuinely needs, because by then the
slider is at rest and the user is no longer scrubbing.

The CI parity harness validates render correctness and (eventually) frame
timing. See the testing spec — to be added once the first renderer lands.

## Layer ownership (the table)

If you remember one image from this spec, this is it.

| Concern                  | Web owner                                     | Apple owner                                      |
| ------------------------ | --------------------------------------------- | ------------------------------------------------ |
| Render coordination      | `RenderService` (signals)                     | `RenderActor` + `@MainActor` `RenderCoordinator` |
| Live working adjustments | `EditSession` (signals)                       | `@Observable @MainActor EditSession`             |
| Selection / tool         | `EditSession` (signals)                       | `@Observable @MainActor EditSession`             |
| Undo/redo                | `HistoryService` (signals)                    | `@Observable @MainActor History`                 |
| XMP write debounce       | `SidecarWriter` service                       | `SidecarWriter` actor                            |
| GPU surface              | `WebGL2RenderingContext` (in `RenderService`) | `MTLCommandQueue` (in `RenderActor`)             |
| FFI handle               | raw-wasm bindings                             | `raw-core` via C-FFI                             |

## What this spec deliberately does not cover

- **Multi-image batch edit** (apply preset to N images, sync edits across
  selection). → `batch-edit.md` (TBD).
- **Crop / straighten / rotate.** Viewport / geometry ops are not slider
  adjustments — they change framing, not pixel values. They will need their
  own state slot. → `geometry-ops.md` (TBD).
- **Layer-based local adjustments** (brush, gradient, mask). If/when added,
  this spec extends; until then, every adjustment in edit state is global
  to the image. → TBD.
- **Mid-edit sidecar conflict resolution.** Another process (Bridge,
  Lightroom, a sync agent) writes the XMP while we have it open. Out of
  scope here; needs a contract for "external change detected" + a merge or
  prompt UX. → `sidecar-conflicts.md` (TBD).
- **Photo metadata edits** (rating, color label, keywords). These do NOT go
  through the render pipeline — they are XMP changes with no pixel impact.
  The contract: metadata writes go through `SidecarWriter` the same way,
  but they do not touch edit state in the render sense (`AdjustmentModel`)
  and do not trigger `RenderService.request(...)`. They live in a sibling
  `MetadataSession` with its own undo stack. → `photo-metadata.md` (TBD).
- **Color pipeline internals.** What the GPU actually computes — DCP
  matrices, dehaze, deconvolution. → `color-pipeline.md` (TBD).

## When in doubt

- Three layers, not one.
- Diff ops, not snapshots.
- One op per gesture, not one per tick.
- Subscribe to state; never poll it.
- Generation counters on every render request.
- Real `.xmp` files in tests; no mocks.
- 16 ms or it doesn't ship.
