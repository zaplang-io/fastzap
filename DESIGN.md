# fastzap — design

fastzap is the official coroutine-native web framework for Zap
([zaplang-io/zap#312](https://github.com/zaplang-io/zap/issues/312)), replacing
`fastapi + starlette + uvicorn + flask` with one package. This document records
the architecture and the reasoning; the user-facing surface is in the
[README](README.md), and the ratified decisions are in [DECISIONS.md](DECISIONS.md).

## Module layout

Dogfoods Zap-to-Zap module imports (D-0081, zaplang-io/zap#283):

```
src/fastzap.zap        public API: Request/Response, App + routing registration
                       (the `@app.get` decorator desugars to it, D-FZ-0007),
                       the route matcher, the coroutine server + staged shutdown,
                       the response builders, and the validation bridge.
src/fastzap/wire.zap   a self-contained HTTP/1.1 wire + URL helper: request-target
                       and query parsing, path segmentation, and response-byte
                       serialization. A LEAF module — it touches only str/int/
                       list/dict, never a fastzap type, so it never imports back
                       into fastzap and the import graph stays acyclic (Zap v1
                       rejects cycles).
vendor/validation/     a vendored copy of the `validation` package (see below).
```

The public types all live in `fastzap.zap` because Zap has no re-export (D-0081):
keeping `App`/`Request`/`Response` in one module is what lets a consumer write
`fastzap.Request` rather than `fastzap.types.Request`. The one split-out module is
the stringly wire codec, which is pure and leaf.

## The single-framework / no-coloring model

Zap coroutines are transparent and cheap, so there is no sync/async split and no
function coloring. A handler is a plain `fn(Request) -> Response` that does
straight-line, blocking I/O; the server spawns one coroutine per connection, so
blocking in a handler blocks only that coroutine, and the netpoller (#80) keeps
the rest running. This is the flask ergonomic (plain blocking handlers) with the
fastapi contract (typed models, a value return) and no uvicorn.

## Request lifecycle

For each accepted connection, in its own coroutine (`_handle`):

1. `http.read_request(conn)` parses the request line, headers and
   Content-Length body off the socket (stdlib #104).
2. `_build_request` decomposes the target into a decoded `path` + `query` dict
   (via `wire`), snapshots a standard header subset, and builds a `Request`.
3. `dispatch` resolves the request: the readiness endpoint first, then the route
   table. Matching splits the path into segments and compares against each
   route's precomputed segments; a `{name}` segment captures into `path_params`.
   A path that matches no route is `404`; a path that matches but with the wrong
   method is `405`.
4. If the matched route declares param specs (`app.with_params(...)`, D-FZ-0011),
   `dispatch` validates and coerces them off the `Request` first; a missing
   required or unparsable typed value short-circuits to a `422` before the handler
   runs. The matched handler then runs — reading coerced values off `req.param_*`
   and doing typed-model work (`req.validate(schema)`) via the `validation`
   package inside the handler.
5. The `Response` is serialized and written with `net.send`. A buffered response
   goes out whole with a byte-accurate `Content-Length`; a **streaming** response
   (fastzap#6) is written as a `Transfer-Encoding: chunked` head + pumped chunks +
   terminator. The `Connection` header reflects the negotiated keep-alive
   decision, and the connection loops for the next request unless it is closing.

`http.respond` is intentionally **not** used: it hard-codes `text/plain` and
Connection: close with no control over the content type or headers. fastzap
writes its own response bytes via `net.send` so a JSON API sends
`application/json`, custom/middleware headers ride along, and keep-alive +
chunked framing are under fastzap's control.

### Keep-alive + streaming (fastzap#6, D-FZ-0014)

Steps 1–5 run in a **per-connection loop** (`_serve_connection`): read a request,
dispatch, write, then loop for the next request on the same connection (HTTP/1.1
keep-alive). The loop ends when the request/response negotiated close
(`Connection: close`, or keep-alive disabled via `configure_server`), the
connection ended (client closed / incomplete request — `http.read_request` raises
a catchable fault), the per-connection request cap (`max_keepalive_requests`) is
reached, or a graceful drain has begun (checked between requests). Framing is by
`Content-Length` (`http.read_request` reads exactly the body, leaving the socket
at the next request), so sequential requests parse correctly; HTTP **pipelining**
is not supported (bytes past one request's Content-Length in the same read are
discarded — documented, not a silent corruption). Each request still runs in its
**own `scope:`** (#50) inside the loop, so a handler's spawned work never leaks
into the next request.

A **streaming** response is a Response SHAPE, not a new handler signature — the
uniform `fn(Request) -> Response` contract (D-FZ-0001) is unchanged.
`streaming_response(status, content_type, produce)` carries a `produce` closure
(`fn(StreamWriter) -> int64`); the server writes the chunked head, then calls
`produce(w)` where `w.write(chunk)` frames each chunk (`<hex>\r\n<bytes>\r\n`, an
empty chunk dropped), then writes the terminating `0\r\n\r\n`. `StreamWriter`'s
byte sink is an `fn(str) -> int64` closure — the server's sends on the socket, a
test's collects into a list, so the incremental producer is unit-testable with no
socket. A producer that fails mid-stream is contained (the head is already on the
wire): the body is terminated cleanly and the connection closed, never a bogus
500 over a partial body.

### Error isolation

`_handle` wraps the whole pipeline in `try/except`. This is load-bearing for
structured concurrency: an uncaught exception in a child coroutine cancels its
siblings, so a single malformed request (a parse fault from `http.read_request`,
which raises a *catchable* `zap_panic`) or a throwing handler must never escape —
it becomes a `500` (or `400`), and in-flight peers are untouched.

## Concurrency + staged graceful shutdown

The accept loop and the two signal watchers live in one `scope:` inside `run`:

```
scope:
    spawn detached _watch(app, listener, SIGTERM-channel)
    spawn detached _watch(app, listener, SIGINT-channel)
    while accepting:
        conn = net.accept(listener)   # raises when the listener is closed
        spawn _handle(app, conn)      # OWNED → joined at the dedent
```

- **Per-request scope / drain for free.** Each `_handle` is an *owned* spawn, so
  the scope's join barrier at the dedent is exactly the in-flight drain: control
  does not pass the dedent until every connection's keep-alive loop has returned.
  With keep-alive (fastzap#6), a **busy** connection checks the shutdown latch
  between requests and closes after its current request; a connection **idle**
  parked on the next read is reclaimed by the grace-timer backstop (below) within
  the grace budget — in-flight requests are drained either way, so none is
  dropped. A prompt idle-connection close on shutdown wants a stdlib socket read
  deadline, which `net.recv` does not expose today (the netpoller supports
  `deadline_ns` but it is unplumbed, and `scope(timeout=…)` is reserved-but-
  deferred); filed as zaplang-io/zap#485. See D-FZ-0014.
- **Watchers are detached.** Each waits on one `signal.notify` channel. They are
  detached so the watcher for a signal that never fires does not block the join.
- **The staged drain** (`_trigger_shutdown`, one-shot via a latch that is safe
  under the cooperative scheduler — no await between the check and the set):
  1. `ready = False` — the readiness endpoint flips to 503.
  2. sleep the **propagation window** — keep accepting/serving so eventually-
     consistent endpoint/LB removal propagates before the listener closes.
  3. `net.close_listener` — this makes the parked `net.accept` raise, which
     breaks the accept loop; no new connections are accepted.
  4. the scope join drains in-flight handlers.
  5. a detached **grace timer** `sys.exit(0)`s if the drain outlasts the grace
     budget — a clean exit just under `terminationGracePeriodSeconds` so the
     process is never SIGKILLed mid-request. In the normal case the join finishes
     first and `run` returns before the timer fires.

Why not `scope(cancel_on=[SIGTERM], grace=…)` directly? `cancel_on` cancels the
whole scope tree at the first checkpoint after the signal — it would tear down
in-flight requests *immediately*, which is the opposite of a staged drain (the
spec requires keeping service during the propagation window). So shutdown is
sequenced explicitly on `signal.notify` channels instead; `grace` from #77 is
mirrored by the backstop timer. See DECISIONS.md D-FZ-0003.

Readiness/`ServerState` is a plain `struct` (a reference type, D-0023) shared
across the coroutines; the flags it carries (`ready`, `triggered`) are flipped at
cooperative scheduling boundaries. Promoting them to the atomic types (#176) is a
documented follow-up (D-FZ-0006); for a cap-1, signal-driven, one-shot drain the
plain flags are correct under the current scheduler.

## The `validation` dependency (vendored)

fastzap depends on the `validation` package (#311) for typed models. The CI
toolchain image has no package registry or git access, so `validation` is
**vendored** under `vendor/validation/` and declared as a path dependency
(`validation = { path = "vendor/validation" }`). The test/example scripts
assemble a flat build root that places the fastzap modules and the vendored
validation modules next to the entry file, which is how Zap resolves sibling
packages for a single-file `zap run`/`zap build` (D-0081). This should become a
registry/git dependency once the Zap registry is populated (D-FZ-0005).

## Testing

The server's socket I/O and the signal path need full codegen, which runs in CI
against the prebuilt LLVM-18 toolchain image (local Docker/LLVM was unavailable
while authoring — every `.zap` here was checked with a front-end-only `zap`
(`zap fmt --check`, `zap ir`), and codegen is the CI gate).

- `tests/fastzap_test.zap` — the request pipeline **without a socket**: it calls
  `dispatch` directly on hand-built requests to cover routing (literals, path
  params, trailing-slash, 404 vs 405), query parsing (defaults, `+`/%XX
  decoding), the readiness endpoint, the response builders, the validation bridge
  (201 and 422), and the wire serialization. Fully deterministic.
- `tests/decorator_test.zap` — the `@app.get` routing sugar (D-FZ-0007): the
  handlers are registered **only** by `@app.get`/`@app.post`/`@app.delete`
  decorators (no explicit `app.<verb>(...)` call in the file), and the driver
  asserts the route table was populated and dispatches identically to the engine
  that `fastzap_test.zap` drives by hand — proving the decorator is pure sugar
  over the same registration.
- `tests/di_test.zap` — FastAPI-style `Depends(...)` injection (D-FZ-0010): a
  composed provider graph (settings ← db ← principal) injected into a handler via
  `Depends(...)` parameters over the real `@app.get` dispatch path, asserting
  injection + nesting, deps-first resolution order, and per-request
  single-resolution (providers print a token, so "build db" appears once per
  request even though the handler takes `get_db` twice).
- `tests/params_test.zap` — strict typed-param coercion (D-FZ-0011): a route
  declares param specs with `app.with_params(...)` (composing with both the
  `@app.get` decorator and programmatic registration), and the driver asserts a
  valid request coerces int/str/bool (incl. an applied default), a missing
  required param and an unparsable int/bool each produce a field-located 422,
  multiple failures collect into one 422, and the lenient `query_int(name,
  fallback)` accessor is unchanged on a route that declares no specs.
- `tests/keepalive_test.zap` — HTTP/1.1 keep-alive + chunked/streaming
  (fastzap#6, D-FZ-0014), all **without a socket**: the keep-alive decision
  (`connection_keep_alive`, a pure fn) for default/explicit keep-alive, honoring
  `Connection: close`, and shutdown forcing close; the buffered wire framing
  (correct Content-Length + the negotiated Connection token, no Transfer-Encoding)
  and the chunked framing (hex sizes incl. multi-digit, a chunk's exact bytes, the
  `0\r\n\r\n` terminator, a chunked head with Transfer-Encoding and no
  Content-Length); `dechunk` as the inverse of `chunk_encode`, so an encode→decode
  round-trip returns the original body a client reassembles; and the streaming
  Response shape through `dispatch` (a handler returns `streaming_response`; its
  producer, pumped through a *collecting* `StreamWriter`, yields the expected
  chunks — an empty chunk dropped — which reassemble into the full body).
- `tests/shutdown_test.zap` — the staged drain over the **real signal path**:
  `signal.notify(SIGTERM)` + `__raise_signal(15)` + `__signal_drain()` deliver
  the signal deterministically (exactly as the compiler's own signal goldens do),
  and the watcher is an *owned* spawn so the scope join settles the state before
  the assertions. Asserts the readiness flip, the one-shot latch, and the stage
  transition.
- Both drivers assert conditions and print a stable `ok <label>` token per check
  (never a raw value), so the goldens are independent of float/JSON formatting
  and a break is localized to one line.
- `examples/quickstart.zap` is compile-smoked (`zap build`) in CI and is the
  end-to-end demonstration of the live accept/serve/drain loop.
