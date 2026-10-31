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

def read_item(fastzap.Request req) -> fastzap.Response:
    auto id = req.path_param_int("id", 0)
    return fastzap.json_response(200, "{\"id\":" + str(id) + "}")

def create_item(fastzap.Request req) -> fastzap.Response:
    match req.validate(item_schema()):
        case validation.ValidationResult.Ok(m):
            return fastzap.created_model(m)        # 201, model serialized to JSON
        case validation.ValidationResult.Err(errs):
            return fastzap.validation_error(errs)  # 422, every field error listed

def main():
    auto app = fastzap.app()
    app.get("/items/{id}", read_item)
    app.post("/items", create_item)
    fastzap.run(app, "0.0.0.0", 8000)
```

A complete, runnable version is in [`examples/quickstart.zap`](examples/quickstart.zap).

## Routing

Register a handler for a method + path template. Path parameters are written
`{name}` and captured into the request:

```zap
app.get("/", index)
app.get("/users/{uid}/posts/{pid}", read_post)
app.post("/items", create_item)
app.put("/items/{id}", replace_item)
app.delete("/items/{id}", delete_item)
app.patch("/items/{id}", patch_item)
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

Unknown paths return `404`; a known path reached with the wrong method returns
`405`.

> **Why `app.get("/x", handler)` and not the `@app.get("/x")` decorator?**
> FastAPI's decorator reads a handler's *parameter annotations* to inject typed
> path/query/body params. Zap's user-defined function decorators are deferred
> (zaplang-io/zap#26/#16 — only `@derive` and struct reflection exist today) and
> there is no function-parameter reflection, so neither the decorator form nor
> per-parameter injection can exist yet. fastzap keeps the rest of the FastAPI
> shape — one app object, method-per-verb registration, typed models, a value
> return — and this registration call is exactly what a future `@app.get` will
> lower to once decorator-codegen lands. See [DECISIONS.md](DECISIONS.md)
> (D-FZ-0001).

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

**In v1:** decorator-style method routing with path params, typed
request/response models via `validation`, the built-in coroutine HTTP server,
per-request structured-concurrency scopes, and the staged graceful shutdown, with
tests and a runnable example.

**Deferred follow-ups** (tracked against the #312 epic #432): OpenAPI/Swagger
generation, dependency injection, middleware/filters, the `@app.get` decorator
sugar (awaits decorator-codegen #16), HTTPS/TLS termination, and keep-alive /
streaming bodies. See [DECISIONS.md](DECISIONS.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
