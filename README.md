# fastzap

A **coroutine-native web framework for Zap** — one framework that replaces
`fastapi + starlette + uvicorn + flask`.

Because Zap coroutines are transparent and cheap (no `async`/`await`, no function
coloring), there is **no sync/async split**: a handler is a plain function that
does straight-line, blocking I/O and returns a value, and the framework runs
thousands of them concurrently on the scheduler — each inside its own
structured-concurrency `scope:` (zaplang-io/zap#50). It is served by its **own
built-in coroutine HTTP server** on the stdlib `http`/`net` stack (#104) over the
netpoller (#80); there is no uvicorn/ASGI/WSGI layer to bolt on.

Typed request/response models come from the
[`validation`](https://github.com/zaplang-io/validation) package (#311) — Zap
structs validated against a schema, playing pydantic's role, with no separate
schema layer. And it ships the **staged, zero-dropped-request graceful shutdown**
Kubernetes needs, as a first-class feature.

It is a non-core, official-tier Zap package (D-0056), installed by the Zap
package manager and dogfooding Zap. Implements
[zaplang-io/zap#312](https://github.com/zaplang-io/zap/issues/312).

## Quick start

```zap
import fastzap
import validation

def item_schema() -> validation.Schema:
    return validation.model("Item", [
        validation.field("name", validation.str_t(min_len=1, max_len=80)),
        validation.field("price", validation.float_t(min=0.0)),
    ])

@app.get("/items/{id}")
def read_item(fastzap.Request req) -> fastzap.Response:
    auto id = req.path_param_int("id", 0)
    return fastzap.json_response(200, "{\"id\":" + str(id) + "}")

@app.post("/items")
def create_item(fastzap.Request req) -> fastzap.Response:
    match req.validate(item_schema()):
        case validation.ValidationResult.Ok(m):
            return fastzap.created_model(m)        # 201, model serialized to JSON
        case validation.ValidationResult.Err(errs):
            return fastzap.validation_error(errs)  # 422, every field error listed

def main():
    auto app = fastzap.app()   # the `@app.*` routes above register right here
    fastzap.run(app, "0.0.0.0", 8000)
```

A complete, runnable version is in [`examples/quickstart.zap`](examples/quickstart.zap).

## Routing

Declare a handler for a method + path template with the `@app.<verb>` decorator.
Path parameters are written `{name}` and captured into the request:

```zap
@app.get("/")
def index(fastzap.Request req) -> fastzap.Response: ...

@app.get("/users/{uid}/posts/{pid}")
def read_post(fastzap.Request req) -> fastzap.Response: ...

@app.post("/items")
def create_item(fastzap.Request req) -> fastzap.Response: ...

@app.put("/items/{id}")
def replace_item(fastzap.Request req) -> fastzap.Response: ...
# ...and @app.delete / @app.patch likewise.
```

Each `@app.<verb>("/path")` is sugar for the method-call registration
`app.<verb>("/path", handler)`, spliced in right after `auto app = fastzap.app()`
in source order (zaplang-io/zap#457, D-0087). The method-call form stays
available for programmatic registration (loops, computed paths):

```zap
auto app = fastzap.app()
app.get("/", index)              # equivalent to @app.get("/") on `index`
app.post("/items", create_item)
```

Every handler has the same signature, `fn(Request) -> Response`, and pulls typed
values off the request:

| On `Request`                     | Returns                                   |
| -------------------------------- | ----------------------------------------- |
| `req.path_param("uid")`          | captured path segment (str)               |
| `req.path_param_int("id", 0)`    | path segment parsed as int, else fallback |
| `req.query_str("q")`             | query parameter (str, `""` if absent)     |
| `req.query_int("limit", 10)`     | query parameter as int, else fallback     |
| `req.header("content-type")`     | request header, case-insensitive          |
| `req.text()`                     | raw request body                          |
| `req.validate(schema)`           | `validation.ValidationResult`             |
| `req.param_int("id")`            | strictly-coerced declared param (int)     |
| `req.param_str("q")`             | strictly-coerced declared param (str)     |
| `req.param_bool("active")`       | strictly-coerced declared param (bool)    |

Unknown paths return `404`; a known path reached with the wrong method returns
`405`.

## Strict typed params (422)

The `query_int(name, fallback)` / `path_param_int(name, fallback)` accessors above
are **lenient** — unparsable input returns the fallback, never an error. For
FastAPI's strict behavior, **declare** a route's params and let fastzap validate
and coerce them *before* the handler runs: a missing required param or an
unparsable typed value is rejected with a `422` carrying field-located errors
(the same `{"detail", "errors":[{loc, kind, msg}]}` envelope as body validation),
and the handler reads the coerced value off `req.param_int/param_str/param_bool`.

```zap
@app.get("/items/{id}")
def read_item(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(200, "{\"id\":" + str(req.param_int("id")) + "}")

def main():
    auto app = fastzap.app()           # @app.get splices app.get("/items/{id}", …) here
    app.with_params("GET", "/items/{id}", [
        fastzap.path_param_spec("id", fastzap.ParamType.IntT),
        fastzap.query_param_default("limit", fastzap.ParamType.IntT, "10"),
        fastzap.query_param_spec("q", fastzap.ParamType.StrT, required=False),
    ])
    fastzap.run(app, "0.0.0.0", 8000)
```

`GET /items/abc` now returns `422`
(`{"loc":"path.id","kind":"int_parsing","msg":"value is not a valid integer"}`)
instead of silently reading `0`. Build specs with `path_param_spec`,
`query_param_spec` (required by default; pass `required=False` to allow absence),
or `query_param_default` (optional with an applied default); the type is
`fastzap.ParamType.IntT | StrT | BoolT`. `with_params` attaches them
post-registration, so it composes with both the decorator and programmatic
`app.<verb>(...)` routes. The lenient accessors are **unchanged** — strict is a
per-route opt-in alongside them. Each `Route` carries its specs as structured
data, which is also what OpenAPI parameter generation will walk (see DECISIONS.md
D-FZ-0011).

> **`Depends(...)` injection is supported; typed path/query/body injection is
> not (yet).** A handler can declare dependencies as parameters with a
> `Depends(provider)` default — the compiler injects them (see
> [Dependency injection](#dependency-injection) below). What it does _not_ do is
> read a handler's *scalar* parameter annotations to inject typed path/query/body
> values into the signature (`id: int`, `q: str = ...`): those stay
> framework-side, pulled off the `Request` itself — leniently with
> `path_param_int`/`query_int`, or strictly (with a `422`) via declared param
> specs (see [Strict typed params](#strict-typed-params-422) above). A future
> `@query`/`@path` source annotation that would inject coerced scalars into the
> signature through the same adapter is a separate, still-unbuilt capability. See
> [DECISIONS.md](DECISIONS.md) (D-FZ-0007, D-FZ-0010, D-FZ-0011).

## Typed models

Models are declared with the `validation` package and used directly in handlers;
there is no fastzap-specific schema layer. `req.validate(schema)` parses and
validates the request body, returning either a typed `Model` or the **full** list
of field errors (never just the first):

- `fastzap.ok_model(m)` / `fastzap.created_model(m)` — 200/201 with the model
  serialized back to JSON.
- `fastzap.validation_error(errs)` — 422 with
  `{"detail": "validation failed", "errors": [{loc, kind, msg}, ...]}`.
- `fastzap.json_response(status, body)` / `fastzap.text_response(status, body)` /
  `fastzap.json_error(status, detail)` — build a response directly.

## Interactive API docs (OpenAPI)

Like FastAPI, fastzap serves a generated **OpenAPI 3** document and an
interactive docs UI out of the box — no extra wiring:

- **`GET /openapi.json`** — the OpenAPI 3.0.3 document, generated from the live
  route table: each route's path template, its declared **param specs** (the
  OpenAPI `parameters:`, see *Strict typed params* above) and its associated
  request/response **body schemas** (mapped from a `validation.Schema` to JSON
  Schema).
- **`GET /docs`** — a [Swagger UI](https://swagger.io/tools/swagger-ui/) page
  (loaded from a CDN) pointed at `/openapi.json`.

Parameters come from the `with_params` specs automatically. Body schemas are
associated with a route explicitly — a handler validates its body with
`req.validate(schema)` *inside* its body, which the framework cannot observe, so
you declare the association the same way you declare param specs:

```zap
def main():
    auto app = fastzap.app()
    app.with_params("GET", "/items/{id}", [
        fastzap.path_param_spec("id", fastzap.ParamType.IntT),
    ])
    # Request + response body schemas for the OpenAPI document. The spec builders
    # are free functions (defaults live there; a method takes positional-only
    # args in Zap v1, so `with_body`/`with_response` take a pre-built spec).
    app.with_body("POST", "/items", fastzap.request_body_spec(item_schema()))
    app.with_response(
        "POST", "/items",
        fastzap.response_spec(201, item_schema(), "the created item"),
    )

    # Customize the info block / paths, or turn the docs off entirely.
    app.configure_docs(fastzap.docs_config(title="Items API", version="1.0.0"))
    fastzap.run(app, "0.0.0.0", 8000)
```

The `validation` → JSON Schema emitter lives in `fastzap.jsonschema` as a
self-contained, framework-agnostic module (so it can be upstreamed into the
`validation` package later). Docs are on by default; `docs_config(enabled=False)`
disables both endpoints. See [DECISIONS.md](DECISIONS.md) (D-FZ-0012).

## Dependency injection

fastzap supports the idiomatic FastAPI `Depends(...)` form: a handler declares a
dependency as a parameter with a `Depends(provider)` default, and the compiler
injects it. `provider` is a plain top-level function whose own dependencies are
themselves `Depends(...)` parameters; they resolve **deps-first** and **once per
request** (FastAPI's default `use_cache=True`), shared across every parameter and
sub-dependency that needs them.

```zap
import fastzap

struct Settings:
    str env

struct DB:
    str dsn

def get_settings() -> Settings:              # a leaf provider
    return Settings("prod")

def get_db(Settings s = Depends(get_settings)) -> DB:   # nested dependency
    return DB(s.env + "://db")

@app.get("/me")
def me(fastzap.Request req, DB db = Depends(get_db)) -> fastzap.Response:
    return fastzap.text_response(200, db.dsn)  # `db` is injected, resolved once
```

`Depends` is a compiler-recognized marker (not a library value), so it is written
bare — no import. At the `@app.get` decoration site the compiler synthesizes a
per-handler adapter that resolves the providers (deps-first, deduplicated to one
resolution each per request) and calls the handler with the injected values; the
adapter's type is the uniform `fn(Request) -> Response` seam, so the engine, route
table, and dispatch are unchanged (zaplang-io/zap#466, D-0092).

**Scope boundary (v1).** The compiler injects `Depends` and passes the `Request`
through positionally only. Path/query/body stay framework-side: handlers and
providers read typed values off `req` (`path_param_int`, `query_int`, `validate`).
A provider parameter that is **not** itself `Depends(...)` is request-derived and
rejected at compile time (`ZAP5048`). A future `@query`/`@path` source annotation
is a separate capability. See [DECISIONS.md](DECISIONS.md) (D-FZ-0010).

## Middleware

Cross-cutting concerns — logging, request-id, CORS, auth, timing, error mapping —
layer on with an **ordered middleware chain** wrapping `dispatch`, without
touching handlers. A middleware has the **onion** shape `fn(Request, next) ->
Response`, where `next` is the rest of the chain (`fn(Request) -> Response`): call
`next(req)` to continue and inspect/modify its Response, or return a Response
*without* calling `next` to short-circuit.

```zap
import fastzap

def main():
    auto app = fastzap.app()

    # Registered OUTERMOST-FIRST: the error-mapper wraps everything; CORS sits
    # closest to the handler. Handlers stay plain `fn(Request) -> Response`.
    app.use(fastzap.error_mapper())   # any thrown error -> JSON 500
    app.use(fastzap.request_id())     # reuse/generate X-Request-Id, echo it back
    app.use(fastzap.access_log())     # one "METHOD path -> status" line per request
    app.use(fastzap.cors_default())   # Access-Control-Allow-* (+ 204 preflight)

    fastzap.run(app, "0.0.0.0", 8000)
```

Write your own with the same shape — this one adds an `X-App` header on the way
out, or 401s a request with no credentials on the way in:

```zap
def require_auth(
    fastzap.Request req,
    fn(fastzap.Request) -> fastzap.Response nxt,
) -> fastzap.Response:
    if req.header("Authorization") == "":
        return fastzap.json_error(401, "unauthorized")   # short-circuit
    fn(fastzap.Request) -> fastzap.Response n = nxt
    auto resp = n(req)                                    # pass through
    return fastzap.with_header(resp, "X-App", "fastzap")  # after-handling

# app.use(fastzap.middleware("auth", require_auth))
```

`app.use` registers outermost-first; an empty chain leaves `dispatch` unchanged.
`next` is a first-class function value / closure (zaplang-io/zap#163, #465); a
configurable built-in (`cors(origin)`, `request_id_header(name)`) captures its
config in its constructor. See [DECISIONS.md](DECISIONS.md) (D-FZ-0013).

## Keep-alive & streaming responses

fastzap speaks **HTTP/1.1 keep-alive**: a connection is reused for successive
requests and closed on `Connection: close`, when a per-connection request cap is
reached, or when the graceful drain begins. It's on by default; tune it (or turn
it off for one request per connection) with `configure_server`:

```zap
# reuse a connection for up to 1000 requests (default 100); keep_alive=False
# restores one-request-per-connection.
app.configure_server(fastzap.server_config(max_keepalive_requests=1000))
```

A response body can be **streamed** incrementally with `Transfer-Encoding:
chunked` instead of being buffered whole — for large or open-ended bodies. It's a
Response *shape*, so the handler stays `fn(Request) -> Response`: return a
`streaming_response` (or `streaming_text`) carrying a producer that writes chunks
into a `StreamWriter`.

```zap
# The producer is handed a StreamWriter; each w.write(chunk) is sent as one
# chunk. An empty write is skipped (a zero-length chunk ends the body).
def _events(fastzap.StreamWriter w) -> int64:
    auto i = 0
    while i < 5:
        w.write("event " + str(i) + "\n")
        i = i + 1
    return 5

@app.get("/events")
def stream_events(fastzap.Request req) -> fastzap.Response:
    return fastzap.streaming_text(200, _events)   # chunked text/plain
```

To stream per-request data, close over it in a `lambda w: ...` producer. A
chunked response omits `Content-Length` (the two are mutually exclusive) and ends
with the terminating `0\r\n\r\n` chunk. HTTP pipelining is not supported, and a
per-connection idle/read timeout awaits a stdlib socket read deadline — see
[DECISIONS.md](DECISIONS.md) (D-FZ-0014).

## Graceful shutdown (zero dropped requests)

On **SIGTERM** (and SIGINT for local dev) fastzap runs a **staged drain**, not a
naive instant listener close, so no in-flight or in-propagation request is
dropped under Kubernetes:

1. **Flip readiness to unready** — the readiness endpoint (`/healthz` by default)
   starts returning `503`, so k8s removes the pod from the Service endpoints and
   load balancers stop routing **new** traffic.
2. **Keep serving during the endpoint-propagation window** — endpoint/LB removal
   is eventually consistent, so for a configurable window the server keeps
   accepting and serving (otherwise requests still being routed mid-propagation
   get connection-refused).
3. **Stop accepting** — the listener closes once the window elapses.
4. **Drain in-flight requests** — every request runs in a coroutine owned by the
   server's `scope:`, whose join barrier *is* the drain: shutdown does not
   complete until the last handler returns.
5. **Exit before the deadline** — a grace-budget backstop guarantees a clean exit
   before `terminationGracePeriodSeconds`, so the process is never SIGKILLed
   mid-request.

Configure the budgets (both should sit under `terminationGracePeriodSeconds`,
default 30s):

```zap
# keep serving 3s into the propagation window, then up to 20s of drain
app.configure_shutdown(fastzap.shutdown_config(3000, 20000, "/healthz"))
```

### Deploying for zero-downtime

- **Be PID 1.** SIGTERM is delivered to PID 1, a shell wrapper won't forward it,
  and the kernel *ignores* an unhandled SIGTERM sent to PID 1 (the process then
  survives until SIGKILL). Use an exec-form entrypoint or an init like `tini`.
  See [examples/Dockerfile](examples/Dockerfile).
- **Budget under the grace period.** Keep `propagation_ms + grace_ms` comfortably
  below `terminationGracePeriodSeconds`. A `preStop` sleep is an equivalent
  alternative to the propagation window if you prefer a hook.
- **Wire the readiness probe** to the configured `readiness_path` so Kubernetes
  acts on the flip in step 1.
- If a server fails to drain in time, the `gc`/`runtime` diagnostics from #77
  (`zap inspect <pid>`, SIGQUIT goroutine dump) show where handlers are stuck.

```yaml
# Kubernetes (sketch)
spec:
  terminationGracePeriodSeconds: 30
  containers:
    - name: api
      readinessProbe:
        httpGet: { path: /healthz, port: 8000 }
```

## Build & test

The suite compiles and runs through the prebuilt Zap toolchain image, so no local
LLVM is required:

```bash
docker run --rm -v "$PWD":/w -w /w ghcr.io/zaplang-io/zap:latest sh -c '
  zap fmt --check src tests examples
  sh tools/run-tests.sh
  sh tools/build-examples.sh
'
```

`tools/run-tests.sh` assembles a flat build root (the fastzap modules + the
vendored `validation` dependency + a driver) and diffs each driver's output
against its `.expected` golden. See [DESIGN.md](DESIGN.md) for the testing model
and what is CI-verified.

## v1 scope

**In v1:** `@app.get` decorator routing with path params (D-FZ-0007), typed
request/response models via `validation`, the built-in coroutine HTTP server,
per-request structured-concurrency scopes, and the staged graceful shutdown, with
tests and a runnable example.

**Also in v1:** FastAPI-style `Depends(...)` dependency injection (D-FZ-0010) —
handler parameters with a `Depends(provider)` default, resolved deps-first and
once per request by a compiler-synthesized adapter (zaplang-io/zap#466, D-0092) —
and strict typed-param coercion with a `422` via explicit param specs (D-FZ-0011).

**Also in v1:** HTTP/1.1 keep-alive and `Transfer-Encoding: chunked` streaming
responses (D-FZ-0014) — a per-connection keep-alive request loop and a
`streaming_response` body shape, with the uniform handler contract unchanged.

**Deferred follow-ups** (tracked against the #312 epic #432): typed per-parameter
path/query/body *injection into the signature* (a `@query`/`@path` source
annotation, distinct from `Depends` and from the framework-side spec surface that
shipped), HTTPS/TLS termination, HTTP pipelining, and a per-connection idle/read
timeout (awaiting a stdlib `net.recv` read deadline). OpenAPI/Swagger generation
(D-FZ-0012), the middleware/filter chain (D-FZ-0013), and keep-alive + streaming
(D-FZ-0014) have since shipped. See [DECISIONS.md](DECISIONS.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
