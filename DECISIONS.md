# fastzap — decisions

Key design decisions for fastzap v1 (zaplang-io/zap#312). Narrow, numbered, and
cross-referenced from the source. Language-level decisions live in the zap repo's
`DECISIONS.md` (D-00xx); these are fastzap-local (D-FZ-00xx).

## D-FZ-0001 — Method-call routing, not the `@app.get` decorator

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

## Deferred to follow-up issues (against the #312 epic #432)

Not blocking a coherent v1; noted so they are not forgotten:

- **OpenAPI/Swagger generation** — needs schema introspection over the
  `validation` schemas + a route-table walk.
- **Dependency injection** — gated on the same reflection gap as D-FZ-0001.
- **Middleware / filters** — a before/after chain around `dispatch`.
- **`@app.get` decorator sugar** — gated on decorator-codegen (#16).
- **HTTPS/TLS termination** — the stdlib `http`/`net` is plaintext in v1; TLS
  (#147) is a follow-up.
- **Keep-alive / streaming bodies** — v1 is one request per connection
  (`Connection: close`).
