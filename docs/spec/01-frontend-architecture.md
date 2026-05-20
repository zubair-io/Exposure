# 01 — Frontend architecture

**Status:** Active.
**Applies to:** All Angular code under `src/web/`.
**Scope:** Browse / view / select UI. **Editor state is out of scope** of this
spec — see `05-editor-state.md` for slider, undo/redo, and render
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
photo-gallery.stories.ts     ← Storybook stories (see next section)
```

The VM function takes plain values (arrays, primitives, the selection
state), returns the shape the template wants, and does no I/O. Templates
get one input (`vm()`); tests get a function with no Angular dependencies.

## Component documentation: Storybook

Every reusable component and every screen-level component has a sibling
`*.stories.ts`. Stories run in isolation against stub stores so the
component can be developed, reviewed, and accessibility-checked without
the rest of the app. Skip stories only for purely structural shells
(`AppShell`, route containers) where "in isolation" has no meaning.

### Required stories per component

| Story       | When                                                           |
| ----------- | -------------------------------------------------------------- |
| `Default`   | Always. The component in its typical state.                    |
| `Loading`   | If the component shows a loading state.                        |
| `Empty`     | If the component can render with no data.                      |
| `Error`     | If the component handles an error state.                       |
| `EdgeCases` | Long text, missing images, extreme values — author discretion. |

Stories use **Component Story Format 3** (typed `Meta` + `StoryObj`
exports). No `storiesOf`, no default-export-only stories.

### Mocked dependencies

Stores are stubbed via `moduleMetadata` providers — a plain object
exposing the same signal accessors, not a real store instance. Convention:
each store exports a `stub<StoreName>(overrides)` helper next to it.

```ts
const meta: Meta<PhotoGalleryComponent> = {
  component: PhotoGalleryComponent,
  decorators: [
    moduleMetadata({
      providers: [
        { provide: LibraryStore, useValue: stubLibraryStore() },
        { provide: PhotoStore, useValue: stubPhotoStore() },
      ],
    }),
  ],
};

export const Default: StoryObj<PhotoGalleryComponent> = {};
export const Loading: StoryObj<PhotoGalleryComponent> = {
  decorators: [
    moduleMetadata({
      providers: [{ provide: LibraryStore, useValue: stubLibraryStore({ status: 'pending' }) }],
    }),
  ],
};
```

### Addons (CI-enforced)

- **`@storybook/addon-a11y`** — runs axe-core on every story. Zero
  serious/critical violations; CI fails otherwise.
- **`@storybook/addon-interactions`** — interaction tests live in the
  story's `play` function (click, type, assert). Required for any
  component with non-trivial user input.

### CI gate

The web subsystem CI workflow runs `storybook build` (static export) on
every PR; the build must succeed. Visual-regression snapshotting
(Chromatic / Loki) is deferred until there's a designer in the review
loop.

### Local commands

```bash
cd src/web
bun run storybook          # dev server on port 6006
bun run storybook:build    # static export to storybook-static/
```

Setup (`@storybook/angular`, `.storybook/main.ts`, `.storybook/preview.ts`,
scripts) lands with the first web subsystem commit; this spec defines the
contract for what stories must exist once the harness is in place.

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
- **Importing a store library.** No `@ngrx/*`, no `@ngneat/elf`. The
  canonical shape (see § Stores) is plain `@Injectable` + `httpResource` +
  `signal` / `computed` / `effect`. If you think you need a library, write
  it up in a doc first and convince the spec.
- **Clearing the local cache on input change.** Causes an empty flash
  before the new id's IDB entry loads. Let the load effect repopulate; the
  race guard handles staleness.
- **Silently swallowing IDB errors.** Wrap every IDB read in `try/catch`
  and every IDB write in `.catch()`, both with a structured `console.warn`.
  A full-disk quota error must not be invisible.
- **Pre-emptive services** for state that might be shared "one day."
  Promote on demand, not on speculation.
- **`*ngIf` / `*ngFor` / `*ngSwitch`** in new components. Migrate when you
  touch a file, not as a separate refactor.
- **VM logic inline in the template.** If the template needs a `ternary`,
  a `pipe`, or a `let` binding to compute a value, that value belongs in
  the VM.
- **Components coordinating multiple stores manually.** Cross-store
  dependencies live inside the dependent store (see § Multi-store
  coordination), not in a `combineLatest` or `effect` in the component.

## Stores: the canonical shape

We use plain Angular services exposing signals, with `httpResource` for
network reads and `effect()` for local-cache write-through. **No external
store library** — no NgRx, no NgRx SignalStore, no Elf. The Angular signal
primitives are now expressive enough; everything a store library used to
add was a workaround for `Observable`-based HTTP being out of step with the
rest of the framework. `httpResource` (Angular 19+) closes that gap.

### The `Store<T>` interface

Every store satisfies a small shared interface. This keeps the read
surface uniform across the codebase and makes generic helpers (for VMs,
stories, and tests) possible:

```ts
// src/web/projects/maple-common/src/lib/state/store.ts
import { Signal } from '@angular/core';

export interface Store<T> {
  readonly data: Signal<T | null>;
  readonly loading: Signal<boolean>;
  readonly error: Signal<unknown | null>;
  readonly refreshing?: Signal<boolean>;
}
```

Conventions:

- Stores live in `*.store.ts` files. One store per file.
- Class name: `XxxStore`.
- Public API: `readonly` signal accessors + `setX(...)` mutator methods +
  `invalidate()` to force a re-fetch.
- All HTTP reads via `httpResource`; mutations via `HttpClient` wrapped in
  a store method (see § Mutations).
- IDB I/O always wrapped in `try/catch` (reads) or `.catch()` (writes)
  with a structured log on failure.

### The canonical pattern (single-entity, read-mostly)

```ts
@Injectable({ providedIn: 'root' })
export class DataStore implements Store<Data> {
  private idb = inject(IdbService);

  // Inputs — change these to trigger a re-fetch.
  id = signal<string>('default');

  // Network — signal-native, auto-cancels on input change.
  private network = httpResource<Data>(() => ({
    url: `/api/data/${this.id()}`,
  }));

  // Local — populated from IDB on input change.
  private local = signal<Data | null>(null);

  // Public read surface — network wins, local fallback.
  readonly data = computed(() => this.network.value() ?? this.local());
  readonly error = computed(() => this.network.error());

  // "We have nothing to show AND a fetch is in flight."
  readonly loading = computed(() => this.network.isLoading() && !this.local());

  // "We're refreshing on top of cached data." Different from loading.
  readonly refreshing = computed(() => this.network.isLoading() && !!this.local());

  constructor() {
    // Load from IDB on every input change.
    effect(async () => {
      const id = this.id();
      try {
        const cached = await this.idb.get<Data>(id);
        // Race guard: id may have changed while we awaited.
        if (cached && this.id() === id) this.local.set(cached);
      } catch (err) {
        console.warn('[DataStore] IDB read failed', err);
      }
    });

    // Write network responses through to IDB.
    effect(() => {
      const fresh = this.network.value();
      if (!fresh) return;
      this.idb.save(fresh).catch((err) => {
        console.warn('[DataStore] IDB write failed', err);
      });
    });
  }

  setId(id: string) {
    // Do NOT clear `local` here — let the IDB-load effect repopulate.
    // Clearing causes an empty flash before the new cache loads; the
    // race guard in the effect handles staleness.
    this.id.set(id);
  }

  /** Force a network re-fetch. Used by mutation invalidation. */
  invalidate() {
    this.network.reload();
  }
}
```

Notes baked into the snippet:

- `readonly` on every public signal — consumers read, only the store mutates.
- `loading` distinguishes from `refreshing` — both states matter for UX.
- IDB I/O is `try/catch`-ed in both directions; warnings, never silent.
- `setId` doesn't clear `local`; the race guard handles the transition.
- `invalidate()` is the canonical re-fetch entry point used by § Mutations.

### Devtools trade

We lose NgRx-style action-log devtools (time-travel debugging, store
inspection). Angular DevTools shows signals; for our read-mostly workload
that's enough. If a future debugging story needs more, add it ad-hoc —
don't reintroduce a store library for the devtools alone.

## Mutations (POST / PUT / PATCH / DELETE)

`httpResource` is read-only. Mutations call `HttpClient` directly through
a store method, then either reload the affected resource or set the new
value optimistically.

### Canonical mutation method

```ts
@Injectable({ providedIn: 'root' })
export class PhotoStore implements Store<Photo> {
  private http = inject(HttpClient);
  // ... fields as in the canonical pattern above ...

  /**
   * Update a photo's rating. Optimistic — applies locally first, rolls
   * back on failure. Re-throws so the caller can show an error.
   */
  async setRating(rating: number): Promise<void> {
    const prev = this.network.value();
    if (!prev) return;

    // Optimistic: apply locally before the network round-trip.
    this.network.set({ ...prev, rating });

    try {
      const updated = await firstValueFrom(
        this.http.patch<Photo>(`/api/photos/${prev.id}`, { rating }),
      );
      // Server is the source of truth — overwrite with the server response.
      this.network.set(updated);
    } catch (err) {
      this.network.set(prev); // rollback
      throw err;
    }
  }
}
```

### Rules

- **Optimistic by default for low-risk single-field changes** (rating,
  color label, keyword toggle). Roll back on failure.
- **Pessimistic for destructive or multi-entity changes** (delete, batch
  ops). Reload after success: `this.invalidate()`.
- **Always re-throw** so the caller can show a toast or react. Never
  swallow.
- **Invalidate dependent collections** when a mutation affects ids that
  appear in collection stores. The mutating store knows which collections
  to refresh.

### Invalidation across stores

```ts
async deletePhoto(id: string): Promise<void> {
  await firstValueFrom(this.http.delete(`/api/photos/${id}`));
  this.invalidate();                              // this entity's own resource
  inject(PhotoCollectionStore).invalidate();      // the photo list
  inject(AlbumStore).invalidate();                // any album that listed it
}
```

`invalidate()` is just `this.network.reload()` exposed publicly. The
mutating store decides what becomes stale.

## Collection stores

Single-entity-by-id is the easy half. Collections — paginated lists,
folder views, search results — need a different shape. Two shapes; pick
by sharing requirement.

| Shape                                                           | When                                                                                         |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **A. Entities + index** (`PhotoStore` + `PhotoCollectionStore`) | Entities recur in multiple collections (a photo in a folder, a tag filter, a search result). |
| **B. Single store with array** (`signal<T[]>`)                  | List members don't recur in other collections (the libraries list, a one-off settings list). |

Default to **B** until you genuinely need A. Premature shape-A is the
same trap as premature service-extraction.

### Shape A — entities + index

```ts
@Injectable({ providedIn: 'root' })
export class PhotoCollectionStore implements Store<Photo[]> {
  private photoStore = inject(PhotoStore);

  filter = signal<PhotoFilter>({ libraryId: null, tag: null, page: 0 });

  private index = httpResource<{ ids: string[]; total: number }>(() => ({
    url: '/api/photos',
    params: this.filter(),
  }));

  // Resolve ids → entities by joining via PhotoStore. Each entity is
  // cached by its own store, so the same photo appearing in N
  // collections costs one network call total.
  readonly data = computed(() => {
    const ids = this.index.value()?.ids ?? null;
    if (!ids) return null;
    return ids.map((id) => this.photoStore.peek(id)).filter((p): p is Photo => p !== null);
  });

  readonly loading = computed(() => this.index.isLoading() && !this.data());
  readonly error = computed(() => this.index.error());

  invalidate() {
    this.index.reload();
  }
}
```

`peek(id)` is a synchronous lookup on the entity store — implemented as
`signal<Record<string, Photo>>` plus a getter. Spell it out on the entity
store when implementing.

### Shape B — single store with array

For non-shared collections, skip the index/entity split:

```ts
@Injectable({ providedIn: 'root' })
export class LibraryListStore implements Store<Library[]> {
  private idb = inject(IdbService);

  private network = httpResource<Library[]>(() => ({ url: '/api/libraries' }));
  private local = signal<Library[] | null>(null);

  readonly data = computed(() => this.network.value() ?? this.local());
  readonly loading = computed(() => this.network.isLoading() && !this.local());
  readonly error = computed(() => this.network.error());

  constructor() {
    effect(async () => {
      try {
        const cached = await this.idb.getAll<Library>('libraries');
        if (cached.length) this.local.set(cached);
      } catch (err) {
        console.warn('[LibraryListStore] IDB read failed', err);
      }
    });

    effect(() => {
      const fresh = this.network.value();
      if (!fresh) return;
      this.idb.bulkSave('libraries', fresh).catch((err) => {
        console.warn('[LibraryListStore] IDB bulk save failed', err);
      });
    });
  }

  invalidate() {
    this.network.reload();
  }
}
```

### Pagination

For cursor or offset paged collections:

- `filter` signal includes the cursor.
- The store keeps the array of _accumulated_ loaded pages as a separate
  signal; `data` is `computed` from that.
- `loadMore()` advances the cursor signal; `httpResource` re-fires; an
  effect appends the new page to the accumulator.

Spec the exact pagination shape when the first paged screen lands; cursor
vs offset is a per-endpoint decision and should match the API.

## Multi-store coordination

"When the selected library changes, the photo collection should refetch."
That's not a new pattern — it falls out of the signal model.

The dependent store reads the upstream's signal directly in its
`httpResource` factory:

```ts
@Injectable({ providedIn: 'root' })
export class PhotoCollectionStore {
  private libraryStore = inject(LibraryStore);

  private index = httpResource<{ ids: string[] }>(() => ({
    url: `/api/libraries/${this.libraryStore.selectedId()}/photos`,
  }));
}
```

When `libraryStore.selectedId()` changes, `httpResource` re-fires. The
in-flight request to the old library auto-cancels. No subscriptions, no
`effect()` plumbing.

### Rules

- Cross-store dependencies live inside the **dependent store**, in its
  `httpResource` factory or a private `effect()`.
- Components never coordinate stores. A component reads from N stores via
  one `computed()` for its VM and treats them as independent.
- Circular dependencies (A reads from B, B reads from A) mean the data
  model is wrong — fix the model, don't paper over with effects.

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
      libraries: this.libraryStore.data() ?? [],
      photos: this.photoStore.data() ?? [],
      selectedLibraryId: this.selectedLibraryId(),
      isLoading: this.libraryStore.loading() || this.photoStore.loading(),
    }),
  );

  // No manual .load() — the stores' httpResource fetches on construction
  // and re-fires when their inputs change.

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
  coordination, mid-edit XMP. → `05-editor-state.md`.
- **URL state / router as source of truth** — deep-linkable selections,
  back-button behaviour. → `routing.md` (TBD).
- **Real-time streaming state** — WebSocket subscriptions, server-sent
  events, presence. → `streaming-state.md` (TBD).

## When in doubt

- Smaller files beat bigger files.
- Component signals beat services beat stores.
- Pure functions beat reactive plumbing.
- One render trigger (`vm()`) beats many.
- Promote on demand, never on speculation.
