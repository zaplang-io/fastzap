# quickstart — a typed items API served by fastzap, with graceful shutdown.
#
# Build + run:
#   (assembled next to the library by tools/build-examples.sh)
#   zap run quickstart.zap
#   curl localhost:8000/                       # service banner
#   curl localhost:8000/items/42               # a path parameter
#   curl 'localhost:8000/items?limit=5'        # a query parameter
#   curl -XPOST localhost:8000/items -d '{"name":"Book","price":9.5}'   # 201
#   curl -XPOST localhost:8000/items -d '{"name":"","price":-1}'        # 422
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

@app.get("/items")
def list_items(fastzap.Request req) -> fastzap.Response:
    auto limit = req.query_int("limit", 10)
    return fastzap.json_response(200, "{\"limit\":" + str(limit) + "}")

@app.get("/items/{id}")
def read_item(fastzap.Request req) -> fastzap.Response:
    auto id = req.path_param_int("id", 0)
    dict[str, JsonValue] o = {}
    o["id"] = JsonValue.Int(id)
    o["name"] = JsonValue.Str("item-" + str(id))
    return fastzap.json_response(200, json.dumps(JsonValue.Object(o)))

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

    # Tune the staged drain for a fast-rolling deployment: keep serving 3s into
    # the endpoint-propagation window, then up to 20s of in-flight drain — a 23s
    # total, comfortably under the k8s default terminationGracePeriodSeconds (30s)
    # so the process is never SIGKILLed mid-request.
    app.configure_shutdown(fastzap.shutdown_config(3000, 20000, "/healthz"))

    print("fastzap listening on 0.0.0.0:8000 (SIGTERM for a graceful drain)")
    fastzap.run(app, "0.0.0.0", 8000)
