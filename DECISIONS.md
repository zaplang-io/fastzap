# fastzap — decisions

Key design decisions for fastzap v1 (zaplang-io/zap#312). Narrow, numbered, and
cross-referenced from the source. Language-level decisions live in the zap repo's
`DECISIONS.md` (D-00xx); these are fastzap-local (D-FZ-00xx).

## D-FZ-0001 — Method-call routing, not the `@app.get` decorator

> **Superseded by [D-FZ-0007](#d-fz-0007--app-get-decorator-routing-sugar).** The
> `@app.get("/path")` decorator surface IS now offered — the language support it
> was blocked on (zaplang-io/zap#457 / D-0087) shipped. The method-call form below
> remains the registration seam the decorator lowers to (and is still available
> for programmatic registration); only the **recommended surface** changed. The
> reasoning below is kept as the historical record of the v1 constraint. The
> second half — no per-parameter injection — still holds and is now tracked
> precisely in [D-FZ-0008](#d-fz-0008--dependency-injection-stays-deferred).

**Decision.** Routes are registered with method calls — `app.get("/items/{id}",
handler)`, `app.post(...)`, etc. — with a single uniform handler signature
`fn(Request) -> Response`. The literal FastAPI `@app.get("/items/{id}")` decorator
is **not** offered in v1.

**Why.** FastAPI's decorator does two things Zap cannot express yet:
1. It attaches behavior to a function definition. Zap's user-defined function
   decorators are deferred — sema only accepts `@derive` and declared
   annotation/decorator *reflection* (zaplang-io/zap#26/#16); a decorator that
   registers/wraps a function lowers to "deferred", and `@app.get(...)` (an
   attribute, not a bare name) does not even parse as a decorator.
2. It reads the handler's *parameter annotations* to inject typed path/query/body
   arguments. Zap has no function-parameter reflection, and handlers are
   statically typed with fixed signatures, so a heterogeneous table of
   differently-typed handlers cannot be dispatched generically.

**Consequence + forward path.** Typed values are pulled off the `Request`
(`path_param_int`, `query_int`, `validate`) inside a uniform handler. This is
precisely the shape a future `@app.get` would lower to once decorator-codegen
(#16) and parameter reflection land — the registration call and the engine stay
the same, only the surface sugar is added. This mirrors how the `validation`
package could not offer `@model` and went schema-driven for the same reasons.

## D-FZ-0002 — Write response bytes directly, not via `http.respond`

**Decision.** Responses are serialized by `fastzap.wire.build_response` and
written with `net.send`, not with the stdlib `http.respond`.

**Why.** `http.respond(conn, status, body)` hard-codes `Content-Type: text/plain`
and `Connection: close` and exposes no way to set the content type or any header.
A web framework must send `application/json` (and, later, arbitrary headers).
Writing the response line ourselves is a few lines in a leaf module and removes
the limitation. Request *parsing* still reuses `http.read_request` (robust
Content-Length handling).

## D-FZ-0003 — Explicit staged shutdown, not bare `scope(cancel_on=…)`

**Decision.** Graceful shutdown is sequenced explicitly on `signal.notify`
channels (readiness flip → propagation window → stop accepting → drain → backstop
exit), not by wrapping the accept loop in `scope(cancel_on=[SIGTERM], grace=…)`.

**Why.** `cancel_on` cancels the whole scope tree at the first checkpoint after
the signal, which would cancel in-flight requests *immediately*. #312 requires the
opposite: flip readiness but **keep serving** through the endpoint-propagation
window, and only then stop accepting and drain. That staging cannot be expressed
by `cancel_on` alone. The in-flight **drain** still uses a structured-concurrency
`scope:` join (handlers are owned spawns), and #77's `grace` deadline is mirrored
by a backstop `sys.exit(0)` timer so the process still exits before
`terminationGracePeriodSeconds`.

## D-FZ-0004 — Request headers: standard subset in v1

**Decision.** `Request.header(name)` returns a case-insensitive lookup over a
standard subset of headers (host, content-type, content-length, accept,
authorization, user-agent, x-request-id); arbitrary/custom headers are not
enumerated in v1.

**Why.** The stdlib `http` surface exposes headers only by-name via
`http.req_header(handle, name)` — there is no way to enumerate the raw header
block. Rather than carry the opaque request handle on every `Request` (which
would make `Request` non-constructible in tests), the server snapshots the common
set up front into a plain dict. Full header access is a follow-up gated on an
`http` stdlib addition that exposes the header block.

## D-FZ-0005 — Vendor the `validation` dependency

**Decision.** `validation` (#311) is vendored under `vendor/validation/` and
declared as a path dependency; tests/examples assemble a flat build root with the
vendored source beside fastzap's.

**Why.** fastzap genuinely depends on `validation` for typed models, but the
offline CI toolchain image has no package registry or git access, so a
registry/git dependency cannot resolve there. A vendored path dependency is
self-contained and resolves offline, and matches how the AWS SDK repo consumes
its in-repo `aws-core` package. Replace with a registry/git source once the Zap
registry is populated. `vendor/README.md` documents the refresh procedure.

## D-FZ-0006 — Shared server flags are plain (non-atomic) in v1

**Decision.** The shared `ServerState` (`ready`, `triggered`, `active`) is a plain
reference `struct` with plain-bool/int fields, not atomics (#176).

**Why.** Under the current cooperative scheduler the shutdown flags are flipped at
scheduling boundaries and the one-shot latch's check-and-set has no await between
read and write, so for a cap-1, signal-driven, one-shot drain plain flags are
correct. Promoting `ready`/`active` to atomic types is a clean follow-up if the
scheduler ever becomes preemptive within these windows.

## D-FZ-0007 — `@app.get` decorator routing sugar

**Decision.** Routes are declared FastAPI-style with the `@app.get("/path")` /
`@app.post(...)` / `@app.put` / `@app.delete` / `@app.patch` decorator on a
handler `def`. This **supersedes [D-FZ-0001](#d-fz-0001--method-call-routing-not-the-appget-decorator)**'s
"not offered in v1". The engine, the `Route` table and `dispatch` are
**unchanged** — this is pure surface sugar.

**How it lowers (zaplang-io/zap#457, D-0087).** A *dotted* decorator name is a
registering callable target: `@app.get("/path")` on `def h(Request) -> Response`
desugars — whole-program, **before sema** — to the method-call registration the
engine already runs, `app.get("/path", h)`, spliced in **immediately after the
receiver's binding** (`auto app = fastzap.app()`) in declared-`def` **source
order**. `h` is passed as a first-class `fn(Request) -> Response` value (D-0067).
Because the desugar runs before sema, the resulting call is fully type-checked:
an unknown receiver, a missing method, or a wrong handler shape is a precise
error at the call. Confirmed on `zap ir` + `zap expand` against the real fastzap
modules: the 5 decorators in `tests/decorator_test.zap` splice into `main` as
`App__get/App__post/App__delete(...)` in order.

**Constraints this inherits (D-0087 "capability A").**
- The handler is the single uniform signature `fn(Request) -> Response`; typed
  values are pulled off the `Request` inside it (`path_param_int`, `query_int`,
  `validate`). Per-parameter typed injection is **not** part of this — see
  D-FZ-0008.
- The receiver must be a local named as the decorator's prefix (`app`) and the
  decorated handlers are module-level `def`s — the arrangement D-0087/D-0090
  require (the registration lives in `def main()`; top-level executable
  statements are an error). The method-call form stays available for
  programmatic/dynamic registration (loops, computed paths) where a static
  decorator cannot be written.

**Surface.** `examples/quickstart.zap` and the module header now use the
decorator form; `tests/decorator_test.zap` proves decorated routes dispatch
identically to the explicit registration exercised by `tests/fastzap_test.zap`
(same engine, same golden-style `ok <label>` assertions).

## D-FZ-0008 — Dependency injection stays deferred

**Decision.** FastAPI-style `Depends(...)` dependency injection and typed
per-parameter binding (`id: int`, `q: str = ...`) are **not** offered; handlers
remain `fn(Request) -> Response` and read typed values off the `Request`. This
replaces D-FZ-0001's vague "gated on the same reflection gap" with a precise
blocker. It is **not** `@app.get` sugar (that shipped, D-FZ-0007) and **not** the
stale `#16` the issues cited.

**Why — reflection is necessary but not sufficient.** zaplang-io/zap#458 / D-0089
shipped parameter reflection as the intended substrate, but it only *describes* a
signature; it cannot *drive* injection:
1. The `@app.get` seam passes an opaque `fn` **value**; reflection is keyed by the
   function **name** and D-0089 states fn values are not reflectable by value, so
   there is no name to query at registration/dispatch.
2. `reflect_param_annotations` returns annotation **names** only — a
   `Depends(get_db)` provider argument is unrecoverable.
3. Dispatch is the uniform `h(request)`; there is no way to invoke a differently
   shaped handler with reflectively-resolved arguments.

Realizing it needs the "reflection-driven adapter" D-0089 itself defers
(compiler-generated per-handler glue that binds each declared param per request,
with `Depends` composition + per-request caching). Filed as a language gap:
**zaplang-io/zap#466**. A related soundness hole found while building D-FZ-0007 —
an incompatible function value is accepted as a `fn(...)` with no diagnostic — is
**zaplang-io/zap#465**. fastzap#7 is blocked on #466 (not #16); it lands when the
adapter capability exists.

## D-FZ-0009 — Dependency injection: an explicit, type-safe prototype

**Decision.** Ship a dependency-injection toolkit (`src/fastzap/di.zap`) that
delivers the *semantics* of FastAPI `Depends` — **composable**, **per-request**,
**shared (resolved once)** dependencies — as an explicit, opt-in, fully type-safe
API the handler drives itself. This is a **prototype**, deliberately **not** the
FastAPI signature; it coexists with D-FZ-0008 (which records why the real
param-injection form is blocked on zaplang-io/zap#466) rather than superseding it.

**Why not the FastAPI form.** FastAPI *injects* resolved values into a handler's
declared parameters (`def h(db: DB = Depends(get_db))`). That needs a
reflection-driven adapter binding params per request, which the language cannot
express (D-FZ-0008 / zap#466). Rather than fake it — the defaulted-param form
compiles but silently drops the default and mismatches arity (zap#465) — the
prototype keeps injection **explicit and visible** in the handler body.

**The model.**
- `Cell[T]` — a per-request memo slot (a reference `struct` wrapping
  `Optional[T]`); `new_cell`, `cell_has`, `cell_put`, `cell_value`, `cell_or`, and
  the headline `resolve(cell, provider)` ("resolve once"). Built on generics
  (zap#154) + `Optional`; a LEAF module (imports no fastzap type).
- A dependency is a plain **provider function**. The app bundles one `Cell` per
  shared dependency into a concrete per-request context `struct` and builds a
  fresh one at the top of each handler. **Per-request** = per-handler, because
  exactly one handler runs per request. **Composition** = a provider calls
  another provider on the same context (inside the `resolve` thunk, so each still
  resolves once). **Shared** = the `Cell` memoizes, so a dependency needed by
  several providers runs once per request.
- **Engine unchanged.** Handlers stay `fn(Request) -> Response` and opt in inside
  the body, so DI composes with the `@app.get` sugar (D-FZ-0007) untouched.

**Boundary / forward path.** This is not auto-wiring: the handler explicitly
constructs its context and calls providers; there is no reflection and no
per-parameter binding. When zap#466 lands, the `Depends`-in-the-signature form can
be layered **over these same providers** — the provider functions and `Cell` memo
are exactly the resolution substrate an adapter would call. `tests/di_test.zap`
exercises composition (settings ← db ← principal), per-request freshness, and
single-resolution over the real `@app.get` dispatch path.

## Deferred to follow-up issues (against the #312 epic #432)

Not blocking a coherent v1; noted so they are not forgotten:

- **OpenAPI/Swagger generation** — needs schema introspection over the
  `validation` schemas + a route-table walk.
- **Dependency injection** — an explicit, type-safe **prototype** ships
  ([D-FZ-0009](#d-fz-0009--dependency-injection-an-explicit-type-safe-prototype));
  the FastAPI param-injection *signature* stays blocked on zaplang-io/zap#466
  ([D-FZ-0008](#d-fz-0008--dependency-injection-stays-deferred)).
- **Middleware / filters** — a before/after chain around `dispatch`.
- **`@app.get` decorator sugar** — **shipped**; see
  [D-FZ-0007](#d-fz-0007--app-get-decorator-routing-sugar).
- **HTTPS/TLS termination** — the stdlib `http`/`net` is plaintext in v1; TLS
  (#147) is a follow-up.
- **Keep-alive / streaming bodies** — v1 is one request per connection
  (`Connection: close`).
- **Strict typed-param coercion (422 on unparsable)** — v1's `req.query_int(name,
  fallback)` / `path_param_int(name, fallback)` return the caller-supplied default
  on unparsable input (the method's contract — there is no auto param injection,
  D-FZ-0001). A strict variant that rejects an unparsable typed path/query param
  with a 422 (FastAPI's behavior) is a follow-up, landing naturally alongside the
  parameter-injection path once decorator-codegen/reflection exist. (Note: `int()`
  on a non-numeric string is an *uncatchable* fault in the toolchain today, so the
  coercion pre-validates the string rather than catching a failure; tracked as a
  zap-language issue, not a fastzap one.)
