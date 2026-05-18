# 01 — Frontend architecture

**Status:** Active.
**Applies to:** All Angular code under `src/web/`.
**Scope:** Browse / view / select UI. **Editor state is out of scope** of this
spec — see `editor-state.md` (TBD) for slider, undo/redo, and render
coordination patterns.

## The rule

Three slots, one job each.

| Slot                       | Holds                                                                              | Lifetime      |
| -------------------------- | ---------------------------------------------------------------------------------- | ------------- |
| **Store**                  | Remote, shared, or persistent data (libraries, photos, sidecars, server responses) | App / session |
| **Component-local signal** | Ephemeral UI state (selection, filter input, expand/collapse, hover)               | The component |
| **Service signal**         | UI state genuinely shared across components (e.g. selection echoed in a sidebar)   | App / route   |

Derivation between them is a **pure function** called from a `computed()` —
the "view model" (VM). The VM is co-located with the component as a
`*.vm.ts` file and is tested in isolation as a function, not via component
harness.

## Why this split

We've already lived the alternative. One service grew to 1,600+ lines
holding browse data, selection, filters, cache, fetch coordination, and
XMP parsing. Everything in it became coupled to everything else; nothing in
it was independently testable; the file became a god-object that nobody
wanted to touch.

Splitting along **what kind of state is this** makes the boundaries
mechanical:

- "Would another component want this?" → store or service.
- "Does this survive a route change?" → store.
- "Is this just the user clicking around?" → component-local signal.
- "Is this a derived projection of the above?" → `computed()` calling a
  pure VM function.

## Conceptual structure of a component

```
PhotoGalleryComponent
├── injects:        LibraryStore, PhotoStore  (data)
├── owns:           selectedLibraryId = signal<string | null>(null)  (UI state)
├── derives:        vm = computed(() => buildPhotoGalleryVM(...))
└── delegates:      buildPhotoGalleryVM(...) → photo-gallery.vm.ts (pure)
```

The template binds to `vm()` only. It never reaches into stores or
individual signals — one entry point, one re-render trigger, one thing to
unit-test.

## Co-located view models

Every component with non-trivial derivation has a sibling `*.vm.ts`:

```
photo-gallery.component.ts
photo-gallery.component.html
photo-gallery.component.scss
photo-gallery.vm.ts          ← pure function + VM type
photo-gallery.vm.spec.ts     ← tested as a function, no TestBed
```

The VM function takes plain values (arrays, primitives, the selection
state), returns the shape the template wants, and does no I/O. Templates
get one input (`vm()`); tests get a function with no Angular dependencies.

## Defaults

Non-negotiable for new code:

- **Standalone components.** `standalone: true` everywhere; no NgModules.
- **OnPush change detection.** `changeDetection: ChangeDetectionStrategy.OnPush`
  on every component. Signals make this essentially free.
- **Native control flow.** `@if`, `@for`, `@switch`. Not `*ngIf` / `*ngFor` /
  `*ngSwitch`. Drop `CommonModule` from imports — it's no longer needed.
- **Separate files.** `.ts` / `.html` / `.scss`. No inline templates,
  no inline styles, except for trivial leaf components.
- **No `any`.** Especially no `$any($event.target)`. Cast the target
  properly (`event.target as HTMLSelectElement`) or — better — emit a typed
  custom event from a child component.
- **`input()` / `output()`** for component I/O, not `@Input()` / `@Output()`.
- **`inject()`** for DI, not constructor parameters.

## The escalation ladder

When state outgrows its current slot, walk **up** one rung. Never start
higher than you need.

1. **Component signal** — default starting point for any UI state.
2. **Sibling VM function** — when derivation gets non-trivial.
3. **Injectable service exposing public signals** — when a second component
   needs the same state.
4. **Full store** — when state is remote, persistent, or has its own
   commands / effects / cache.

The cheapest refactor in Angular is component-signal → service-signal.
**Defer.** A premature service makes a state shape harder to change than a
local signal does.

## Anti-patterns

These are concrete things to reject in review:

- **Selection state inside a data store.** Selection is ephemeral UI; the
  store is data. If the store has a `selectedX` field, lift it out.
- **UI flags (`isLoading`, `isExpanded`, `isHovered`) leaking into a store**
  unless they are genuinely shared (e.g. global "operation in progress"
  shell indicator).
- **`combineLatest + map + toSignal`** when the upstream streams could just
  be signals — `computed()` over signals does the same job without the
  ceremony or the `initialValue` gymnastics.
- **Pre-emptive services** for state that might be shared "one day."
  Promote on demand, not on speculation.
- **`*ngIf` / `*ngFor` / `*ngSwitch`** in new components. Migrate when you
  touch a file, not as a separate refactor.
- **VM logic inline in the template.** If the template needs a `ternary`,
  a `pipe`, or a `let` binding to compute a value, that value belongs in
  the VM.
- **Multiple stores reaching into each other.** Cross-store coordination
  is a service or effect's job, not a store's. (See the TBD coordination
  spec.)

## Store choice

The pattern is library-agnostic. Stores must expose data as
**signal-readable values** by the time a component consumes them — whether
that's via direct signal accessors, `toSignal()` at the consumer, or
something else is implementation detail of the store layer.

Two acceptable options as of writing:

- **NgRx SignalStore** — signal-first from the ground up; no `toSignal()`
  needed at the boundary; preferred for **greenfield code** in this repo.
- **Elf** — RxJS-native; existing convention if migrating Elf code over.
  Wrap exposed `*$` observables with `toSignal()` at the component (one
  call per stream, then `computed()` for derivation).

A future commit will lock in one choice; until then, new subsystems use
SignalStore unless there's a stated reason otherwise.

## Code template (one canonical example)

A typical browse-style component looks like this. The exact library API
varies; the **shape** does not:

```ts
// photo-gallery.component.ts
@Component({
  selector: 'app-photo-gallery',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './photo-gallery.component.html',
  styleUrl: './photo-gallery.component.scss',
})
export class PhotoGalleryComponent {
  private libraryStore = inject(LibraryStore);
  private photoStore = inject(PhotoStore);

  // UI state — ephemeral, component-local.
  protected selectedLibraryId = signal<string | null>(null);

  // VM — pure derivation, single template binding.
  protected vm = computed<PhotoGalleryVM>(() =>
    buildPhotoGalleryVM({
      libraries: this.libraryStore.libraries(),
      photos: this.photoStore.photos(),
      selectedLibraryId: this.selectedLibraryId(),
      isLoading: this.libraryStore.status() === 'pending' || this.photoStore.status() === 'pending',
    }),
  );

  constructor() {
    this.libraryStore.load();
    this.photoStore.load();
  }

  protected onLibraryChange(event: Event): void {
    const value = (event.target as HTMLSelectElement).value;
    this.selectedLibraryId.set(value || null);
  }
}
```

```ts
// photo-gallery.vm.ts — pure, no Angular imports.
export interface PhotoGalleryVM {
  /* ... */
}

export function buildPhotoGalleryVM(input: {
  libraries: ReadonlyArray<Library>;
  photos: ReadonlyArray<Photo>;
  selectedLibraryId: string | null;
  isLoading: boolean;
}): PhotoGalleryVM {
  /* ... */
}
```

```html
<!-- photo-gallery.component.html -->
<div class="toolbar">
  <select [value]="vm().selectedLibraryId ?? ''" (change)="onLibraryChange($event)">
    <option value="">All libraries</option>
    @for (lib of vm().libraries; track lib.id) {
    <option [value]="lib.id">{{ lib.name }} ({{ lib.photoCount }})</option>
    }
  </select>
  <span class="count">{{ vm().totalCount }} photos</span>
</div>

@if (vm().isLoading) {
<div class="loading">Loading…</div>
} @else if (vm().isEmpty) {
<div class="empty">No photos in this library</div>
} @else {
<div class="grid">
  @for (tile of vm().tiles; track tile.id) {
  <div class="tile" [class.portrait]="tile.orientation === 'portrait'">
    <div class="filename">{{ tile.filename }}</div>
    <div class="date">{{ tile.takenAtLabel }}</div>
  </div>
  }
</div>
}
```

## What this spec deliberately does not cover

Each gets its own spec when first implemented; do not extrapolate this
spec to cover them.

- **Editor state** — slider drags at 60 Hz, undo/redo stacks, render-phase
  coordination, mid-edit XMP. → `editor-state.md` (TBD).
- **Cross-store coordination** — "when library changes, refetch photos."
  Probably an effect or a derived store. → `store-coordination.md` (TBD).
- **URL state / router as source of truth** — deep-linkable selections,
  back-button behaviour. → `routing.md` (TBD).
- **Optimistic updates with rollback** — rate a photo, sync to API, undo
  on failure. → `optimistic-mutations.md` (TBD).
- **Real-time streaming state** — WebSocket subscriptions, server-sent
  events, presence. → `streaming-state.md` (TBD).

## When in doubt

- Smaller files beat bigger files.
- Component signals beat services beat stores.
- Pure functions beat reactive plumbing.
- One render trigger (`vm()`) beats many.
- Promote on demand, never on speculation.
