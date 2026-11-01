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

> **Superseded in part by [D-FZ-0010](#d-fz-0010--dependency-injection-the-real-depends-form).**
> The language gap this recorded — [zaplang-io/zap#466](https://github.com/zaplang-io/zap/issues/466)
> (a reflection-driven handler adapter, D-0092) — **shipped**, so FastAPI-style
> `Depends(...)` injection is now offered (D-FZ-0010). The other half — injecting
> typed *path/query/body* scalars from parameter annotations (`id: int`, `q: str =
> ...`) — still holds and is deferred to a future `@query`/`@path` source
> annotation. The reasoning below is kept as the historical record of the v1
> constraint and of the soundness hole ([zaplang-io/zap#465](https://github.com/zaplang-io/zap/issues/465)) found alongside it.

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

> **Superseded by [D-FZ-0010](#d-fz-0010--dependency-injection-the-real-depends-form).**
> The `src/fastzap/di.zap` prototype (`Cell[T]`/`resolve` memo + a hand-built
> per-request context) was a deliberate stopgap for the window before the
> language could drive injection. [zaplang-io/zap#466](https://github.com/zaplang-io/zap/issues/466)
> (D-0092) shipped that capability, so per our LANGUAGE-FIRST rule the workaround
> is **retired**: `di.zap` is removed and handlers now use the real
> `T x = Depends(provider)` form. The reasoning below is kept as the historical
> record of the prototype and why it was explicit rather than faked.

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

## D-FZ-0010 — Dependency injection: the real `Depends(...)` form

**Supersedes [D-FZ-0009](#d-fz-0009--dependency-injection-an-explicit-type-safe-prototype)**
(the `di.zap` prototype) and resolves the deferred half of
[D-FZ-0008](#d-fz-0008--dependency-injection-stays-deferred).

**Decision.** Adopt the idiomatic FastAPI form. A handler declares a dependency
as a parameter with a `Depends(provider)` default:

```zap
def get_settings() -> Settings:
    return Settings("prod")

def get_db(Settings s = Depends(get_settings)) -> DB:   # nested dependency
    return DB(s.env + "://db")

@app.get("/me")
def me(fastzap.Request req, DB db = Depends(get_db)) -> fastzap.Response:
    return fastzap.text_response(200, db.dsn)
```

`provider` is a plain top-level `def` whose own dependencies are themselves
`Depends(...)` parameters. The `src/fastzap/di.zap` prototype (`Cell[T]`/`resolve`
memo + the hand-built per-request context struct) is **removed**, along with the
manual per-request context plumbing.

**Why now.** [zaplang-io/zap#466](https://github.com/zaplang-io/zap/issues/466)
(D-0092) shipped the compiler capability D-FZ-0008 was blocked on: at the
`@app.get` decoration site the desugar synthesizes, before sema, a per-handler
adapter

```zap
def me$adapter(Request req) -> Response:
    Settings get_settings$dep = get_settings()      # deps-first, once each
    DB get_db$dep = get_db(get_settings$dep)
    return me(req, get_db$dep)
```

whose type **is** the uniform `fn(Request) -> Response` seam, and registers *that*.
The engine, route table, and `dispatch` are unchanged (D-FZ-0001/0007); handlers
with no `Depends` register directly, zero overhead. Per the permanent
LANGUAGE-FIRST rule, a workaround-shaped library migrates to the idiomatic form
once the language fix lands — this is that migration.

**Per-request caching is free.** The adapter body is the per-request scope: each
distinct provider resolves into one local and is reused across every parameter and
sub-dependency that needs it (FastAPI's default `use_cache=True`), with no cache
structure and full static typing. `tests/di_test.zap`'s handler takes `get_db`
twice (directly and via `get_user`) and the provider's "build db" token prints
exactly once per request, proving the single resolution.

**Scope boundary (v1).** The compiler binds `Depends(provider)` injection plus
positional pass-through of the handler's non-`Depends` parameters (the `Request`)
**only**. Path/query/body extraction stays framework-side — handlers and providers
read typed values off `req` (`path_param_int`, `query_int`, `validate`). A provider
parameter that is not itself `Depends(...)` is request-derived and rejected at
compile time (`ZAP5048`). A future per-param source annotation (`@query`/`@path`)
is a distinct capability (the still-open half of D-FZ-0008), not this decision.

**Marker, not a value.** `Depends` is a compiler-recognized marker (callee name
`Depends`, one positional provider name), consumed by the desugar and never a
runtime value — so it is written bare, with no import. A library `Depends` value
cannot work (the provider would be unrecoverable at the seam); see D-0092.

## D-FZ-0011 — Strict typed-param coercion + explicit param specs

**Decision.** Add a **strict** typed-param path alongside the lenient accessors. A
route declares its parameters as structured **specs** — `(name, location, type,
required, default, description)` — and `dispatch` validates and coerces them off
the `Request` **before** the handler runs. A missing required param or an
unparsable typed value collects a field-located error and short-circuits to a
**422**; on success the handler reads coerced values off the Request. This is the
follow-up [D-FZ-0001](#d-fz-0001--method-call-routing-not-the-appget-decorator)
and the deferred list recorded, now buildable because explicit declaration
sidesteps the missing per-parameter source annotation (the open half of
[D-FZ-0008](#d-fz-0008--dependency-injection-stays-deferred)).

**Surface.** A spec is built with `path_param_spec(name, type, description="")`
(path params are required by construction), `query_param_spec(name, type,
required=True, description="")`, or `query_param_default(name, type, default,
description="")` (optional with an applied default). `type` is
`ParamType.IntT | StrT | BoolT`. Specs attach to an already-registered route with
`app.with_params(method, path, specs)`:

```zap
@app.get("/items/{id}")
def read_item(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(200, "{\"id\":" + str(req.param_int("id")) + "}")

def main():
    auto app = fastzap.app()                       # @app.get splices app.get(...) here
    app.with_params("GET", "/items/{id}", [
        fastzap.path_param_spec("id", fastzap.ParamType.IntT),
    ])
    app.with_params("GET", "/search", [
        fastzap.query_param_spec("q", fastzap.ParamType.StrT),
        fastzap.query_param_default("n", fastzap.ParamType.IntT, "10"),
    ])
    fastzap.run(app, "0.0.0.0", 8000)
```

**Why a post-registration `with_params`, not a new registration verb.** The
`@app.get` desugar (D-FZ-0007) emits *only* `app.get("/path", handler)` — specs
cannot ride on the decorator. A declarative *attach* keyed by method + path
decouples specs from registration, so one surface serves both decorated and
programmatic routes, and the decorator stays untouched. The desugar splices the
`app.get(...)` calls in immediately after `auto app = fastzap.app()`, so the route
already exists when `with_params` runs later in `main`.

**Error shape — reuse `validation.ValErr`.** Each failure is a
`validation.ValErr(loc, kind, msg)` with a dotted location (`"query.n"`,
`"path.id"` — the package's `"address.zip"` convention), a machine `kind`
(`"missing"`, `"int_parsing"`, `"bool_parsing"`), and a human `msg`. The 422 is
rendered by the **existing** `validation_error(errs)` envelope, identical to body
validation, and **all** failures are collected (not just the first), matching
FastAPI's 422 list.

**Coercion + the uncatchable-fault constraint.** `IntT` reuses the v1 `_is_int_str`
pre-check before calling `int()` — `int()` on a non-numeric string is an
*uncatchable* toolchain fault (zaplang-io/zap ~#456), so the string is validated
first, never caught. `BoolT` accepts `true`/`false`/`1`/`0` case-insensitively;
`StrT` always succeeds. Coerced values land in a `dict[str, JsonValue]` bag on the
`Request`, read via `param_int` / `param_str` / `param_bool` (present-and-typed
accessors, like `validation.Model`'s getters).

**Lenient accessors unchanged.** `query_int(name, fallback)` /
`path_param_int(name, fallback)` keep their default-on-unparsable contract — strict
is a *variant alongside*, opt-in per route, not a replacement.

**Scope (D-0092 boundary).** This is framework-side coercion off the Request; it
does **not** go through the compiler's `Depends(...)` injection adapter
(zaplang-io/zap#466). A per-parameter `@query`/`@path` source annotation that would
inject coerced scalars into handler parameters is a separate, still-unbuilt
capability (the open half of D-FZ-0008) — this spec surface is the bridge toward
it and, meanwhile, the structured input OpenAPI parameter docs read from.

**Feeds OpenAPI (fastzap#3).** `Route.params` is an ordered `list[ParamSpec]`
carrying exactly the OpenAPI Parameter Object fields (`name`, `in` = path/query,
`required`, `schema` type, `default`, `description`). fastzap#3 generates a path
item's `parameters:` by walking `route.params` — no second declaration, and the
`description` slot is already present for doc text.

## D-FZ-0012 — OpenAPI 3 generation + interactive docs

**Decision.** Serve a generated **OpenAPI 3.0.3** document at **`GET
/openapi.json`** and an interactive **Swagger UI** page at **`GET /docs`**, both
on by default (FastAPI parity). The document is built on demand from the live
`App`: path templates (already in OpenAPI `{param}` form), each route's declared
param specs ([D-FZ-0011](#d-fz-0011--strict-typed-param-coercion--explicit-param-specs)
— the `parameters:` source), and its associated request/response **body
schemas** mapped to JSON Schema. This is the headline FastAPI feature the #312
epic deferred.

**Served by `dispatch`, not a handler.** A route handler is `fn(Request) ->
Response` and has no handle on the `App`, so it cannot walk the route table to
emit the document. The two endpoints are therefore served by `dispatch` directly
off the live `App` — exactly as the readiness endpoint already is — gated on
`DocsConfig.enabled` and GET-only (other methods fall through to the normal
404/405 path). `configure_docs(docs_config(...))` sets the `info` block
(title/version/description), relocates either path, or disables both.

**Body-schema association — explicit `with_body` / `with_response`.** Param specs
supply `parameters:`; a route's request/response **body** schemas are the other
half. A handler validates a body by calling `req.validate(schema)` *inside* its
body — a runtime call the framework cannot observe statically — so the
body↔route association is **declared explicitly**, keyed by method + path, the
same shape as `with_params`:

```zap
app.with_body("POST", "/items", request_body_spec(item_schema()))      # requestBody
app.with_response("POST", "/items", response_spec(201, item_schema()))  # responses[201]
```

The spec builders `request_body_spec(schema, required=.., description=..)` and
`response_spec(status, schema, description=..)` are **free functions** (where
default/keyword args work — zaplang-io/zap#298); the `with_body`/`with_response`
methods take a pre-built spec, because a method takes positional-only args in Zap
v1, exactly as `with_params` takes pre-built `ParamSpec`s.

This keeps the surface honest: it documents what the handler actually does and
relies on **no** reflection capability that does not exist. The specs ride on the
`Route` (lists of 0-or-1 / 0-or-more, mirroring how `validation` sidesteps
Optional) and are read **only** by the generator — they never affect dispatch.
Rejected: inferring the body schema from the handler (needs value reflection the
language does not have — the open half of
[D-FZ-0008](#d-fz-0008--dependency-injection-stays-deferred)); a new registration
verb carrying schemas (the `@app.*` decorator desugars to `app.get(path,
handler)` only, so, as with param specs, schemas cannot ride the decorator — a
post-registration attach composes with both decorated and programmatic routes).

**JSON Schema emitter — a separable leaf module.** The `validation.Schema` →
JSON Schema mapping lives in `src/fastzap/jsonschema.zap`, importing **only**
`validation` (so the import graph stays acyclic — the OpenAPI walk, which needs
the `App`/`Route` types, stays in `fastzap.zap`). It is deliberately
framework-agnostic (nothing about routes/HTTP), so it can be lifted into the
`validation` package itself later; fastzap owns it for now. It maps each
`FieldType` to the OpenAPI-3.0 JSON Schema subset (`type`, `properties`,
`required`, `minimum`/`maximum`, `minLength`/`maxLength`, `pattern`, `items`,
`minItems`/`maxItems`, `additionalProperties`), omitting a constraint whose bound
is `validation`'s open sentinel, and treating a required-with-default field as
not required of the caller (matching the engine's own rule).

**Document shape.** `openapi`/`info`/`paths`; each operation carries an
`operationId`, `parameters` (from specs), a `requestBody` (from a body spec), and
`responses`. A validating route (params or a request body) gains a `422
Validation Error` response automatically unless one is declared; a route with no
declared responses still gets a default `200` (OpenAPI requires a non-empty
responses map). The readiness/docs/openapi endpoints are excluded from the
document. Key order in the emitted JSON is unspecified (`dict` iteration order),
so nothing — tests included — relies on it.

**Relationship to fastzap#2 (middleware).** Independent. Middleware
([D-FZ](#deferred-to-follow-up-issues-against-the-312-epic-432) deferred list)
could later wrap or serve the docs routes, but #3 is not blocked on it — the
docs are served inline by `dispatch` today.

**`/docs` asset handling.** The page is a ~500-byte HTML shell that loads Swagger
UI (CSS + bundle) from jsDelivr at a pinned version; no bundle is vendored. Redoc
would be a drop-in alternative; Swagger UI chosen for FastAPI familiarity.

## D-FZ-0013 — Middleware / filter chain (the onion model)

**Decision.** fastzap ships an ordered **middleware chain** wrapping `dispatch`.
A middleware has the single **onion** shape

```zap
fn(Request, fn(Request) -> Response) -> Response      # fn(Request, next) -> Response
```

where `next` is the rest of the chain as a `fn(Request) -> Response`. It is
registered with `app.use(mw)`, **outermost-first**. The uniform handler contract
(`fn(Request) -> Response`, [D-FZ-0001](#d-fz-0001--method-call-routing-not-the-appget-decorator))
is **unchanged** — middleware wraps `dispatch`, handlers are oblivious to it. Four
built-ins ship: `error_mapper()`, `request_id()`, `access_log()`, `cors()`.

**Why the onion (one `next`), not a before/after pair.** The single `next` seam
expresses all three behaviours with no extra machinery:
- **pass-through + after-handling** — call `next(req)`, inspect/rebuild its
  Response, return it;
- **short-circuit** — return a Response *without* calling `next` (auth 401, a
  cache hit, a CORS preflight);
- **before-handling** — run work before calling `next`.

A before/after pair would need its own short-circuit signal and a way to thread
mutated state between the two halves; the onion gets both for free, and composes
by simple wrapping. It is also the shape FastAPI/Starlette and Express converge
on. The cost — `next` is a first-class fn value — is exactly what the language now
supports soundly: closures (zaplang-io/zap#163 / D-0067) and sound fn-value
coercion (zaplang-io/zap#465 / D-0091).

**How the chain is built.** `dispatch(app, req)` folds the registered middlewares
around the terminal route dispatch (`_dispatch_core`, the former `dispatch` body):
`_run_chain(app, i, req)` invokes middleware `i` with a `next` **closure** that
runs the chain from `i + 1`, falling through to `_dispatch_core` when the chain is
exhausted. Reading each middleware's handle out of the `list` element into a
`fn(...)`-typed local re-attaches its signature before the call (a fn read from a
list element otherwise loses its sig — the same idiom D-0067 fn-value code uses).
An **empty chain makes `dispatch` identical to `_dispatch_core`**, so a
middleware-free app is byte-for-byte unchanged and every pre-existing test stays
green.

**Order — outermost-first.** The first `app.use` is the outermost layer: it sees
the Request first and the Response last. So register the error-mapper first (it
must wrap everything to catch it), then request-id, then logging, then CORS
closest to the handler. Rejected innermost-first (Rack/`wsgi`-style) because
"the first thing you add runs first" reads more naturally and matches Express.

**The error-mapper and the server backstop.** fastzap already produced a 500
internally in the connection coroutine `_handle` (a `try/except` that must never
let an exception escape — an escaped exception would cancel the request `scope:`
and take down in-flight peers). That 500 is now **also** available as the
outermost `error_mapper()` middleware: a handler/middleware exception unwinds
through `next(req)` to its `try/except` and becomes the same JSON 500 envelope,
but as a composable, after-handling-aware layer that other middleware's
response-phase still runs around. The `_handle` backstop is **kept** — it is the
coroutine safety boundary and also covers request *parse* failures (400) and the
case where no error-mapper is registered. Defense in depth, not duplication: with
`error_mapper()` registered, a handler error is mapped before it reaches the
backstop; without it, the backstop still protects the coroutine.

**Response headers — a new `Response.headers` field.** CORS and request-id must
set response headers, but v1's `Response` was `(status, content_type, body)` only.
`Response` gains a `dict[str, str] headers` (empty for every plain builder, so the
wire output is unchanged unless a middleware adds one). `with_header(resp, name,
value)` sets one **functionally** — it returns a *new* Response with a copied map
(`dict.copy()`), because middleware treats the Response `next` produced as
immutable. `wire.build_response_with(..., headers)` emits them after
Content-Type/Content-Length and before `Connection: close`; `wire.build_response`
is that with no extras, so its signature and the existing wire test are unchanged.

**Configuration without method default args.** A configurable middleware
(`request_id_header(name)`, `cors(origin)`) captures its configuration in the
constructor via a `lambda` — a method cannot take a defaulted argument
(zaplang-io/zap#481 miscompiles method default args), so config never rides on a
method. Fixed middleware (`error_mapper`, `access_log`, `request_id`) use a
top-level `def` as the handle. Both are plain `fn(...)` values stored in a
`Middleware { name, handle }` record.

**Scope (v1).** Middleware sees the whole `dispatch` (including the readiness and
`/docs`/`/openapi.json` endpoints served inline by `_dispatch_core`). `access_log`
logs `METHOD path -> status` (latency via `time.monotonic_ns()` around `next` is a
noted extension, left out of the default so offline-test stdout stays stable);
generated request-ids are `req-<nanos>` (a UUID/hex rendering is cosmetic). Auth,
strict-param and the `/docs` serving can all later layer on this seam without
touching handlers. `tests/middleware_test.zap` exercises ordering, short-circuit,
request-id propagate+generate, CORS (+preflight), the error-mapper, and a combined
stack, all through the real `dispatch` chain without a socket.

## D-FZ-0014 — HTTP/1.1 keep-alive + chunked / streaming response bodies

**Decision.** fastzap serves each connection with an **HTTP/1.1 keep-alive request
loop** and can emit a response body **incrementally** with `Transfer-Encoding:
chunked`. v1's "read one request → respond → close" becomes a per-connection loop
(`_serve_connection`): read a request, run it through the middleware chain +
router, write the response, **loop** for the next request on the same connection.
Streaming is a new Response **shape** (`streaming_response(...)`), not a new
handler signature — the uniform `fn(Request) -> Response` contract
([D-FZ-0001](#d-fz-0001--method-call-routing-not-the-appget-decorator)) is
unchanged. Closes fastzap#6.

**Keep-alive negotiation.** HTTP/1.1 defaults to keep-alive, so the connection is
reused unless the request carries `Connection: close`, keep-alive is disabled
(`configure_server(server_config(keep_alive=False))`), the per-connection request
cap `max_keepalive_requests` is reached, a graceful drain has begun, or the
connection ends. The decision is a **pure** function `connection_keep_alive(conn_
header, shutting_down)` (unit-tested without a socket); the response's
`Connection` header reflects it (`wire.build_response_keepalive`). The stdlib
`http.read_request` does **not** expose the request's HTTP version (only
method/path/headers/body), so the server cannot distinguish 1.0 from 1.1 and keys
off the `Connection` header, defaulting to keep-alive — an HTTP/1.0 client that
does not want reuse closes its own side, ending the read loop. Exposing the
request version is a **filed stdlib follow-up** (zaplang-io/zap#486).

**Framing + no pipelining.** `http.read_request` reads exactly the Content-Length
body and leaves the socket at the next request, so **sequential** requests parse
correctly in the loop. It buffers each request in a per-call buffer and discards
anything past one request's Content-Length, so **HTTP pipelining is not
supported** — a correctness boundary, documented, not a silent corruption (the
overwhelmingly common client pattern is request→response→request). Buffered
responses keep a byte-accurate `Content-Length`; a chunked response omits it (the
two are mutually exclusive).

**Streaming surface — a producer closure the server pumps.** `Response` gains
`bool streaming` + `fn(StreamWriter) -> int64 produce`. `streaming_response(status,
content_type, produce)` (and `streaming_text`) build one; a buffered builder sets
`streaming = False, produce = _no_body`. The server writes the chunked head
(`build_chunked_head` — `Transfer-Encoding: chunked`, no Content-Length), then
calls `produce(w)` where `w.write(chunk)` frames one chunk
(`chunk_encode`: `<hex-len>\r\n<bytes>\r\n`, an **empty chunk dropped** — a
zero-length chunk is the terminator), then writes `chunk_final()` (`0\r\n\r\n`).
`StreamWriter`'s byte sink is an `fn(str) -> int64` closure, which is why the
incremental producer is **testable with no socket**: the server's sink
(`_conn_writer`) sends each framed chunk on the connection, while a test's sink
collects the raw chunks into a list, through the exact same `w.write` path.
`dechunk` is the inverse of the encoder, so a test asserts the exact body a client
reassembles. A producer that **fails mid-stream** is contained in `_write_stream`
(the status line is already on the wire and cannot be changed to a 500): the body
is terminated cleanly and the connection closed. Rejected a generator/`yield`
producer (zaplang-io/zap#67) — generator-as-struct-field / generator methods are
new and partly WIP (zap#429/#451); the fn-value closure uses only the sound
first-class-fn / coercion capabilities (zap#163/#465) the middleware chain already
relies on. Rejected a `Body` enum variant on `Response` — it would churn every
`Response` construction site and `with_header`; a `streaming` discriminator +
`produce` field is additive and carries through `with_header` unchanged.

**Per-request scope preserved.** Each request in the keep-alive loop runs inside
its own `scope:` (#50) in `_answer`, so a handler's spawned tasks are joined before
the next request and never leak across requests on a kept-alive connection.

**Drain composes with keep-alive.** A **busy** connection checks the shutdown
latch between requests and closes after its current request (prompt). A connection
**idle**-parked on the next read is reclaimed by the existing grace-timer backstop
within the grace budget; in-flight requests drain either way, so the
zero-dropped-requests criterion
([D-FZ-0003](#d-fz-0003--staged-graceful-shutdown-not-cancel)) still holds. A
**prompt** idle-connection close (and a general per-connection idle/read timeout)
wants a stdlib socket **read deadline**, which `net.recv` does not expose today —
the netpoller already takes a `deadline_ns` but `net`/`http` hard-code `0` (park
forever), and `scope(timeout=…)` is reserved-but-deferred in the grammar. Under
the M:N scheduler (zap#47) a shared open-connection registry would be
unsynchronized shared mutable state against fastzap's own convention
([D-FZ-0006](#d-fz-0006--plain-serverstate-flags-not-atomics)), so fastzap does
**not** add one; the read deadline is the right fix and is a **filed stdlib
follow-up** (zaplang-io/zap#485). Documented, not worked around.

**Configuration without method default args.** The knobs live on a free-function
constructor `server_config(keep_alive=True, max_keepalive_requests=100)` and are
installed with `app.configure_server(cfg)` — defaults never ride on a method
(zaplang-io/zap#481 miscompiles method default args), exactly as `ShutdownConfig` /
`DocsConfig` do. `wire.build_response` / `build_response_with` keep `Connection:
close`, so the pre-existing wire golden and the error backstops are unchanged.

## Deferred to follow-up issues (against the #312 epic #432)

Not blocking a coherent v1; noted so they are not forgotten:

- **OpenAPI/Swagger generation** — **shipped**; `/openapi.json` + `/docs`
  generated from the route table, param specs and associated body schemas, see
  [D-FZ-0012](#d-fz-0012--openapi-3-generation--interactive-docs).
- **Dependency injection** — the FastAPI `Depends(...)` form **ships**
  ([D-FZ-0010](#d-fz-0010--dependency-injection-the-real-depends-form)), now that
  zaplang-io/zap#466 (D-0092) landed; it supersedes the `di.zap` prototype
  (D-FZ-0009). Only typed *path/query/body* per-parameter injection (a
  `@query`/`@path` source annotation) remains deferred — the still-open half of
  [D-FZ-0008](#d-fz-0008--dependency-injection-stays-deferred).
- **Middleware / filters** — **shipped**; an onion chain (`fn(Request, next) ->
  Response`) wrapping `dispatch`, registered outermost-first with `app.use`, with
  `error_mapper`/`request_id`/`access_log`/`cors` built-ins, see
  [D-FZ-0013](#d-fz-0013--middleware--filter-chain-the-onion-model).
- **`@app.get` decorator sugar** — **shipped**; see
  [D-FZ-0007](#d-fz-0007--app-get-decorator-routing-sugar).
- **HTTPS/TLS termination** — the stdlib `http`/`net` is plaintext in v1; TLS
  (#147) is a follow-up.
- **Keep-alive / streaming bodies** — **shipped**; an HTTP/1.1 keep-alive request
  loop per connection and `Transfer-Encoding: chunked` streaming responses
  (`streaming_response`), see
  [D-FZ-0014](#d-fz-0014--http11-keep-alive--chunked--streaming-response-bodies).
  A per-connection idle/read timeout and HTTP pipelining remain follow-ups (the
  former wants a stdlib `net.recv` read deadline, filed as zaplang-io/zap#485).
- **Strict typed-param coercion (422 on unparsable)** — **shipped** via an
  explicit param-spec surface; see
  [D-FZ-0011](#d-fz-0011--strict-typed-param-coercion--explicit-param-specs). The
  lenient `query_int(name, fallback)` / `path_param_int(name, fallback)` default-on-
  unparsable contract is kept alongside it. The remaining piece — a per-parameter
  `@query`/`@path` source annotation that injects coerced scalars into *handler
  parameters* through the #466 adapter — stays deferred (the open half of
  D-FZ-0008).
