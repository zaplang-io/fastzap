# quickstart — a typed items API served by fastzap, with graceful shutdown.
#
# Build + run:
#   (assembled next to the library by tools/build-examples.sh)
#   zap run quickstart.zap
#   curl localhost:8000/                       # service banner
#   curl localhost:8000/items/42               # a strict typed path parameter
#   curl localhost:8000/items/abc              # 422 (not a valid integer)
#   curl 'localhost:8000/items?limit=5'        # a lenient query parameter
#   curl localhost:8000/db                     # a Depends(...) injected dependency
#   curl -XPOST localhost:8000/items -d '{"name":"Book","price":9.5}'   # 201
#   curl -XPOST localhost:8000/items -d '{"name":"","price":-1}'        # 422
#   curl localhost:8000/openapi.json           # the generated OpenAPI 3 document
#   open  localhost:8000/docs                  # interactive Swagger UI
#   curl localhost:8000/healthz                # readiness (200, 503 while draining)
#
# Send SIGTERM (or Ctrl-C) and the server performs the staged drain: readiness
# flips to 503, it keeps serving for the propagation window, stops accepting,
# drains in-flight requests, and exits — before Kubernetes' SIGKILL deadline.
# See the Deployment section of the README for PID-1 + terminationGracePeriod.

import fastzap
import validation

# The request/response model, validated by the `validation` package.
def item_schema() -> validation.Schema:
    return validation.model(
        "Item",
        [
            validation.field("name", validation.str_t(min_len=1, max_len=80)),
            validation.field("price", validation.float_t(min=0.0, max=1000000.0)),
        ],
    )

# Routes are declared with the `@app.get` / `@app.post` decorator sugar
# (fastzap#8, DECISIONS.md D-FZ-0007): each decorator desugars to the method-call
# registration `app.<method>(path, handler)` the engine runs, spliced in right
# after `auto app = fastzap.app()` below. The handler stays a plain function
# `fn(Request) -> Response`; typed values are pulled off the Request inside it.
@app.get("/")
def index(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(200, "{\"service\":\"items\",\"status\":\"ok\"}")

# Lenient: an absent/garbage `limit` falls back to 10 (never a 422).
@app.get("/items")
def list_items(fastzap.Request req) -> fastzap.Response:
    auto limit = req.query_int("limit", 10)
    return fastzap.json_response(200, "{\"limit\":" + str(limit) + "}")

# Strict: `id` is declared an int param (see `with_params` in `main`), so a
# non-integer path segment is rejected with a 422 BEFORE this runs — here the
# coerced value is read straight off the Request with `param_int`.
@app.get("/items/{id}")
def read_item(fastzap.Request req) -> fastzap.Response:
    auto id = req.param_int("id")
    dict[str, JsonValue] o = {}
    o["id"] = JsonValue.Int(id)
    o["name"] = JsonValue.Str("item-" + str(id))
    return fastzap.json_response(200, json.dumps(JsonValue.Object(o)))

# FastAPI-style dependency injection (fastzap#7, DECISIONS.md D-FZ-0010): `db` is
# declared as a handler parameter with a `Depends(get_db)` default, and the
# compiler injects it. `get_db`'s own `Settings` dependency is itself a
# `Depends(...)` parameter, resolved first (deps-first) and once per request.
# `Depends` is a bare compiler marker — no import. See the README "Dependency
# injection" section.
struct Settings:
    str env

struct DB:
    str dsn

def get_settings() -> Settings:
    return Settings("prod")

def get_db(Settings s = Depends(get_settings)) -> DB:
    return DB(s.env + "://db")

@app.get("/db")
def show_db(fastzap.Request req, DB db = Depends(get_db)) -> fastzap.Response:
    return fastzap.json_response(200, "{\"dsn\":\"" + db.dsn + "\"}")

# A typed POST handler: validate the body into a model, or return 422 with the
# full list of field errors (this is pydantic's role, played by `validation`).
@app.post("/items")
def create_item(fastzap.Request req) -> fastzap.Response:
    match req.validate(item_schema()):
        case validation.ValidationResult.Ok(m):
            return fastzap.created_model(m)
        case validation.ValidationResult.Err(errs):
            return fastzap.validation_error(errs)

def main():
    # The `@app.get`/`@app.post` registrations above are spliced in here, right
    # after this binding, in source order — equivalent to calling
    # `app.get("/", index)`, `app.get("/items", list_items)`, etc. by hand.
    auto app = fastzap.app()

    # Strict typed-param coercion (fastzap#4, D-FZ-0011): declare `/items/{id}`'s
    # `id` as an int param. `dispatch` coerces it off the Request before the
    # handler and returns a field-located 422 on a non-integer segment. Specs are
    # attached post-registration, so they compose with the `@app.get` decorator;
    # they are also the structured source for OpenAPI parameter docs (fastzap#3).
    app.with_params(
        "GET",
        "/items/{id}",
        [fastzap.path_param_spec("id", fastzap.ParamType.IntT)],
    )

    # OpenAPI 3 docs (fastzap#3, D-FZ-0012): fastzap serves a generated document
    # at /openapi.json and a Swagger UI at /docs (on by default). Params come from
    # the specs above; associate the POST body + response schemas explicitly so
    # they appear in the document (a handler validates its body internally, which
    # the framework cannot observe). `configure_docs` sets the info block.
    app.with_body("POST", "/items", item_schema())
    app.with_response("POST", "/items", 201, item_schema(), "the created item")
    app.configure_docs(fastzap.docs_config(title="items", version="0.1.0"))

    # Tune the staged drain for a fast-rolling deployment: keep serving 3s into
    # the endpoint-propagation window, then up to 20s of in-flight drain — a 23s
    # total, comfortably under the k8s default terminationGracePeriodSeconds (30s)
    # so the process is never SIGKILLed mid-request.
    app.configure_shutdown(fastzap.shutdown_config(3000, 20000, "/healthz"))

    print("fastzap listening on 0.0.0.0:8000 (SIGTERM for a graceful drain)")
    fastzap.run(app, "0.0.0.0", 8000)
