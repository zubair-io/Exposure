# 03 — API architecture

**Status:** Active.
**Applies to:** All API code under `src/api/` (Bun + Elysia + MongoDB).
**Scope:** HTTP route shape, schema authoring, DB access, error envelope,
versioning, and the codegen pipeline that turns route schemas into Angular
and Swift clients. **Background workers, auth flows, large uploads, and
real-time streams are out of scope** of this spec — see the TBD list at the
end.

This spec is the API-side parallel to `01-frontend-architecture.md` and
`02-apple-architecture.md`. The rule is the same shape — one source of
truth, mechanically enforced — applied to HTTP DTOs.

## The rule

**TypeBox is the source of truth for every HTTP DTO.**

The schema you write at the route definition is the same schema:

1. **Elysia** uses it for runtime request/response validation.
2. **Elysia** uses it for compile-time type inference of the handler.
3. **`@elysiajs/swagger`** emits it as the operation in `/openapi.json`.
4. **`openapi-typescript`** consumes that OpenAPI to generate the Angular
   client at `src/web/projects/maple-common/src/generated/api.ts`.
5. **`openapi-generator-cli`** (Swift5 generator) consumes the same
   OpenAPI to generate Swift `Codable` types and a URLSession-based
   client at `src/apple/Sources/ExposureCore/Generated/APIClient.swift`.

You write the schema once. Five consumers — handler types, runtime
validator, OpenAPI document, web client, Swift client — derive from it.
CI re-runs the codegen and fails on `git diff --exit-code`. There is no
ambient "we'll keep them in sync" agreement; the build breaks if you try.

## Why this rule

We've already lived the alternative.

- Mongo stored `snake_case`; clients expected `camelCase`; **30+ route
  files did the transform by hand**, inconsistently.
- DTOs were hand-mirrored across DB schema, API route, web service, and
  Swift `Codable`. A field added in one place silently lagged in the
  other three until a 500 in production surfaced it.
- The de-facto contract for `/search` was a **1,400-line
  `search-route.test.ts`** that exercised the route end-to-end —
  changing the route meant reverse-engineering its own test.
- `assets.ts` was **891 lines** doing metadata, XMP, trash, and
  enrichment in one file.
- A generic worker-supervisor framework grew to **565 lines before
  there were five stages to supervise**.

Each one of those is a load-bearing failure mode. The rules below name
the specific fix for each.

## Route organisation

Domain folders, **not** a flat per-resource file.

```
src/api/src/routes/
├── assets/
│   ├── metadata.ts        # GET /assets, GET /assets/:id, PATCH /assets/:id
│   ├── xmp.ts             # GET /assets/:id/xmp, PUT /assets/:id/xmp
│   ├── trash.ts           # POST /assets/:id/trash, DELETE /assets/:id/trash
│   └── enrichment.ts      # GET /assets/:id/enrichment
├── libraries/
│   ├── crud.ts
│   └── members.ts
└── health.ts
```

One file = one action group inside one domain. The forbidden shape is
`assets.ts` with 891 lines doing four jobs at once. If a file in
`routes/<domain>/` grows past the 400-line soft limit, split by action,
not by clever abstraction.

Each domain folder exports an Elysia plugin that mounts its files:

```ts
// src/api/src/routes/assets/index.ts
import { Elysia } from 'elysia';
import { metadataRoutes } from './metadata';
import { xmpRoutes } from './xmp';
import { trashRoutes } from './trash';
import { enrichmentRoutes } from './enrichment';

export const assetsRoutes = new Elysia({ prefix: '/assets' })
  .use(metadataRoutes)
  .use(xmpRoutes)
  .use(trashRoutes)
  .use(enrichmentRoutes);
```

## Repository pattern

**All DB access goes through a `*.repo.ts` per collection.** Routes
never construct a Mongo query, never reach into a driver, never call
`collection.findOne`. They call a method on a repository.

The repository is the single place where:

- The collection schema (`snake_case` Mongo documents) is known.
- The DTO shape (`camelCase` API representation) is known.
- The translation between the two happens.

That kills the "30+ files doing snake_case transforms by hand" failure.
There is **exactly one** place per collection where the mapping lives.

```
src/api/src/repos/
├── asset.repo.ts          # collection: assets
├── library.repo.ts        # collection: libraries
└── session.repo.ts        # collection: sessions
```

A repository exposes typed methods returning DTO types (the same
TypeBox-derived types the routes use). Mongo `_id` becomes `id`;
snake_case becomes camelCase; nulls become `undefined`; the route sees
clean DTOs.

The Mongo driver itself is a deferred decision — `mongodb` (official)
vs. `mongoose` vs. a thin wrapper — and is not locked here. The contract
is the **shape** of the repository, not the driver underneath.

## Error envelope

Every non-2xx response uses one shape. It is itself a TypeBox schema, so
clients on both sides get a typed error type instead of guessing.

```ts
export const ApiError = Type.Object({
  error: Type.String(), // human-readable summary
  code: Type.String(), // stable machine-readable code (e.g. "asset.not_found")
  requestId: Type.String(), // correlates with server logs
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});
```

Rules:

- **Errors never bubble raw.** A global Elysia `onError` handler maps any
  thrown error to the envelope. Stack traces are logged server-side and
  scrubbed from the response.
- **`code` is stable** — used by clients for branching. Don't change a
  code string casually; treat it like an enum.
- **`requestId`** is generated by request-ID middleware on every request
  and echoed in both the `X-Request-Id` response header and the body.
- **`details`** is optional, free-form, and not load-bearing for clients
  — it carries field-level validation errors, retry hints, etc.

The web and Swift clients each get a generated `ApiError` type from the
codegen, and a single error-handling helper that knows the envelope —
never two error-decoding paths.

## Auth

**Decision pending.** The slot exists in this spec; the choice does not.

Sessions vs. JWT vs. WebAuthn / passkeys all remain on the table. The
prior project was mid-migration to passkeys when this repo was started
(see `docs/upgrade-notes/2026-04-passkey-auth.md` in the predecessor
codebase), and that direction is the most likely landing, but it is not
locked here.

What this spec does pin:

- Auth is an **Elysia plugin**, not scattered guards. One `.use(auth)`
  per protected sub-tree, no per-route boilerplate.
- The plugin exposes an `auth` derive that handlers read as a typed
  value, never a raw header parse.
- Unauthenticated requests return the error envelope with
  `code: "auth.unauthenticated"` or `code: "auth.forbidden"` — same
  envelope as every other error.

Detail lives in a future `auth.md`.

## Versioning

URL-prefix versioning. The first version is **`/v1/...`**. There is no
header-based version negotiation, no `Accept: application/vnd.exposure.v2+json`
dance, no defaulting-to-latest. The version is in the URL or it is not
versioned.

Policy:

- **Don't ship `/v1/` until there's a real `/v2/` in sight.** Until
  then, routes are unprefixed (effectively v0). The day a breaking
  change is needed, the existing routes become `/v1/...` and the new
  ones land at `/v2/...`.
- When v2 ships, v1 stays mounted for the deprecation window declared
  in its release notes. Old clients keep working.
- v1 and v2 share repositories; they differ only in the schema and
  handler at the edge. Don't fork business logic per version.

## File size

Repeat the rule from `CONTRIBUTING.md`: **400 soft, 600 hard**.

For API code specifically:

- A route file is **one domain action group**. Past 400 lines, split by
  action; past 600 lines, the build breaks (no allowlist exception for a
  god-route).
- A repository file is **one collection**. Same limits. If a single
  collection's repo crosses 600 lines, that's a signal the collection is
  doing too much — split the collection, not the file.
- An Elysia plugin (auth, logging, request-ID) is **one concern**. Same
  limits.

## Defaults

Non-negotiable for new code:

- **TypeBox schemas at every route definition.** Schemas are written
  next to the route in a `*.schema.ts` sibling, not inferred from the
  handler's return shape. Inference loses optional-field nuance, loses
  documentation, loses the OpenAPI emit. Write the schema.
- **Repository pattern for all DB access.** Routes import repos, never
  the Mongo driver.
- **Error envelope on all non-2xx.** Never raw `throw` to the client;
  the global `onError` handler maps to the envelope.
- **Request-ID middleware** on every request. The ID is in the
  `X-Request-Id` header (echoed if present, generated if absent), in
  the error envelope, and in every log line.
- **One logger.** A pino-compatible interface (`logger.info({...})`),
  injected once at app construction. No ad-hoc `console.log` in
  handlers; no per-module logger instances diverging on format.
- **`/health` excluded from OpenAPI** via `detail: { hide: true }`. It's
  for load balancers, not API consumers.
- **`/openapi.json` mounted** in dev; behind a `--with-openapi` flag in
  production builds. The JSON file is also committed at
  `contracts/openapi.json` (regenerated by `tools/emit-openapi.sh`); the
  live endpoint is convenience, the committed file is the contract.
- **`bun:ffi` for native code.** The raw-core dylib is loaded once at
  process start via `bun:ffi`. Symbol resolution at startup, not
  per-request. The FFI wrapper itself lives in
  `src/api/src/native/raw-core.ts` and is the only place that touches
  `bun:ffi` — handlers call a typed wrapper, not `dlopen`.
- **Async worker pattern is a `runStage(name, work)` helper.** That is
  it. Five lines: log start, run the work, log finish-or-throw, attach
  the stage name to the request-ID-scoped log context. **No generic
  supervisor framework until there are five stages that demand it.**
  The prior 565-line framework is the cautionary tale.

## Anti-patterns

Reject in review:

- **Inline Mongo queries in routes.** `collection.findOne(...)` in a
  handler is a code-smell; use the repo.
- **Manual `snake_case` ↔ `camelCase` in routes.** That's the repo's
  job, in exactly one place per collection. If you find yourself
  writing `{ id: doc._id.toString(), createdAt: doc.created_at }` in a
  handler, stop and move it to the repo.
- **Hand-rolled DTO interfaces** that duplicate a TypeBox schema. The
  TypeBox `Static<typeof Schema>` is the type. There is no
  `interface Asset` next to `const AssetSchema`.
- **Returning bare `{}` or untyped JSON on success.** Every success
  response has a TypeBox schema; even a no-op endpoint returns
  `Type.Object({ ok: Type.Literal(true) })`.
- **Raw exception bubble-up to the client.** Throwing without going
  through the envelope leaks stack traces and breaks client error
  handling. The global `onError` handler maps; don't bypass it.
- **One file per route prefix doing everything.** `assets.ts` with
  metadata + XMP + trash + enrichment is the failure mode. Split by
  action group.
- **Inventing a worker supervisor framework before there are 5+
  stages.** `runStage(name, work)` until the count forces a real
  framework.
- **Sync I/O on hot paths.** No `readFileSync`, no `JSON.parse` of a
  multi-megabyte payload inline. Stream or defer.
- **Auth checked ad-hoc per handler.** Use the auth plugin's derive;
  don't re-parse the cookie / header in five places.
- **Versioning by header or content-type.** URL prefix only.

## Code template (one canonical example)

A typical resource route — schema, route, repo, response — for the
`assets` domain. The shape is the contract; specific library calls
vary.

```ts
// src/api/src/routes/assets/metadata.schema.ts
import { Type, type Static } from '@sinclair/typebox';
import { ApiError } from '../../errors';

export const Asset = Type.Object({
  id: Type.String(),
  libraryId: Type.String(),
  filename: Type.String(),
  takenAt: Type.Optional(Type.String({ format: 'date-time' })),
  width: Type.Integer(),
  height: Type.Integer(),
  createdAt: Type.String({ format: 'date-time' }),
  updatedAt: Type.String({ format: 'date-time' }),
});
export type Asset = Static<typeof Asset>;

export const AssetListQuery = Type.Object({
  libraryId: Type.Optional(Type.String()),
  limit: Type.Integer({ minimum: 1, maximum: 500, default: 50 }),
  cursor: Type.Optional(Type.String()),
});

export const AssetListResponse = Type.Object({
  items: Type.Array(Asset),
  nextCursor: Type.Optional(Type.String()),
});

export const AssetIdParams = Type.Object({ id: Type.String() });

export const AssetErrors = {
  404: ApiError,
  400: ApiError,
};
```

```ts
// src/api/src/routes/assets/metadata.ts
import { Elysia } from 'elysia';
import { assetRepo } from '../../repos/asset.repo';
import { notFound } from '../../errors';
import {
  Asset,
  AssetIdParams,
  AssetListQuery,
  AssetListResponse,
  AssetErrors,
} from './metadata.schema';

export const metadataRoutes = new Elysia()
  .get(
    '/',
    async ({ query }) => {
      const { items, nextCursor } = await assetRepo.list({
        libraryId: query.libraryId,
        limit: query.limit,
        cursor: query.cursor,
      });
      return { items, nextCursor };
    },
    {
      query: AssetListQuery,
      response: { 200: AssetListResponse, ...AssetErrors },
      detail: { summary: 'List assets', tags: ['assets'] },
    },
  )
  .get(
    '/:id',
    async ({ params }) => {
      const asset = await assetRepo.findById(params.id);
      if (!asset) throw notFound('asset.not_found', `No asset with id ${params.id}`);
      return asset;
    },
    {
      params: AssetIdParams,
      response: { 200: Asset, ...AssetErrors },
      detail: { summary: 'Get one asset', tags: ['assets'] },
    },
  );
```

```ts
// src/api/src/repos/asset.repo.ts
import type { Db } from 'mongodb'; // driver TBD; this is the shape
import type { Asset } from '../routes/assets/metadata.schema';

interface AssetDoc {
  _id: string;
  library_id: string;
  filename: string;
  taken_at?: Date;
  width: number;
  height: number;
  created_at: Date;
  updated_at: Date;
}

function toDto(doc: AssetDoc): Asset {
  return {
    id: doc._id,
    libraryId: doc.library_id,
    filename: doc.filename,
    takenAt: doc.taken_at?.toISOString(),
    width: doc.width,
    height: doc.height,
    createdAt: doc.created_at.toISOString(),
    updatedAt: doc.updated_at.toISOString(),
  };
}

export class AssetRepo {
  constructor(private db: Db) {}

  async findById(id: string): Promise<Asset | null> {
    const doc = await this.db.collection<AssetDoc>('assets').findOne({ _id: id });
    return doc ? toDto(doc) : null;
  }

  async list(args: {
    libraryId?: string;
    limit: number;
    cursor?: string;
  }): Promise<{ items: Asset[]; nextCursor?: string }> {
    // …cursor/limit logic, then:
    const docs: AssetDoc[] = []; // db.collection(...).find(...).toArray()
    return { items: docs.map(toDto), nextCursor: undefined };
  }
}

export const assetRepo =
  /* constructed once at app startup with the shared Db */ null as unknown as AssetRepo;
```

```ts
// src/api/src/errors.ts (sketch)
import { Type, type Static } from '@sinclair/typebox';

export const ApiError = Type.Object({
  error: Type.String(),
  code: Type.String(),
  requestId: Type.String(),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});
export type ApiError = Static<typeof ApiError>;

export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: Record<string, unknown>,
  ) {
    super(message);
  }
}

export const notFound = (code: string, message: string) => new HttpError(404, code, message);
export const badRequest = (code: string, message: string, details?: Record<string, unknown>) =>
  new HttpError(400, code, message, details);
```

The `onError` handler (in `src/api/src/app.ts`) maps `HttpError` to the
envelope, reads `requestId` from the request context, logs the original
error with the stack, and returns the scrubbed envelope to the client.

## OpenAPI emit and drift check

The operational meat — this is what makes "one source of truth"
mechanical rather than aspirational.

**At runtime:** `@elysiajs/swagger` is mounted on the app and emits
`/openapi.json` from the route schemas.

**At build time:** two scripts under `tools/`.

```bash
# tools/emit-openapi.sh
# Boots the app on a random port, GETs /openapi.json, writes to
# contracts/openapi.json. Exits non-zero on any HTTP error.

# tools/regen-clients.sh
# Runs:
#   openapi-typescript contracts/openapi.json \
#     -o src/web/projects/maple-common/src/generated/api.ts
#   openapi-generator-cli generate -i contracts/openapi.json \
#     -g swift5 -o src/apple/Sources/ExposureCore/Generated/
# Then runs prettier on the TS output and swift-format on the Swift output
# so the committed files round-trip through formatters cleanly.
```

**Committed outputs.** `contracts/openapi.json` and both generated
client trees are committed. The repo builds without ever running
codegen. Reviewers can read the diff in a PR and see exactly what
HTTP surface changed.

**DO-NOT-EDIT banner.** Every generated file starts with:

```
// DO NOT EDIT — generated by tools/regen-clients.sh from contracts/openapi.json.
// Source of truth: src/api/src/routes/**/*.schema.ts
```

**CI gate** (`cross.yml`, gated on changes under `src/api/`,
`src/web/projects/maple-common/src/generated/`, or
`src/apple/Sources/ExposureCore/Generated/`):

```bash
tools/emit-openapi.sh
tools/regen-clients.sh
git diff --exit-code contracts/ src/web/.../generated/ src/apple/.../Generated/
```

Any drift fails the build. The fix is never to edit the generated file;
the fix is to either re-run codegen locally and commit, or to update
the schema that drove the drift.

**Forward reference.** A separate spec (`04-codegen.md`, TBD) covers the
Rust → Swift/TS codegen for **value types** (camera matrices, pipeline
constants, sidecar enums). That is a different concern — it operates on
Rust source, not OpenAPI, and emits constants/structs, not HTTP
clients. Don't conflate the two pipelines; they share a directory
(`tools/`) and a CI step (`git diff --exit-code`) but nothing else.

## What this spec deliberately does not cover

Each gets its own spec when first implemented. Do not extrapolate this
spec to cover them.

- **Background workers / enrichment stages** — metadata extraction,
  thumbnail derivation, face/object detection, embedding indexing,
  retry/backoff, idempotency, dead-letter handling. → `workers.md` (TBD).
- **Auth flows** — sessions / JWT / WebAuthn, registration,
  password-reset (if applicable), session revocation, CSRF posture,
  device trust. → `auth.md` (TBD).
- **File upload and streaming of large RAWs** — multipart layout,
  resumable uploads, content-addressed storage, streaming responses for
  large derivatives. → `uploads.md` (TBD).
- **Real-time WebSocket / SSE** — live update push, server-driven UI
  invalidation, presence. → `streaming-state.md` (TBD).
- **Multi-tenant and sharing** — org scoping, library sharing, ACL
  shape, audit trails. → TBD.
- **Rate limiting, quotas, and abuse controls.** → TBD.
- **Observability beyond request-ID and one logger** — metrics
  exporters, tracing, sampling. → TBD.

## When in doubt

- Smaller files beat bigger files.
- Schemas beat hand-rolled interfaces.
- Repositories beat inline queries.
- A typed envelope beats a thrown `Error`.
- Codegen-from-schema beats hand-synced clients.
- A 5-line `runStage` helper beats a 565-line supervisor framework.
- Promote on demand, never on speculation.
