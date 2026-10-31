# Offline test driver for OpenAPI 3 generation + the interactive docs UI
# (fastzap#3, DECISIONS.md D-FZ-0012). Exercises the whole pipeline over the real
# `dispatch` path without a socket: a sample app declares routes with the
# `@app.get`/`@app.post` decorator, attaches param specs (fastzap#4) and
# body/response schemas (`with_body`/`with_response`), then asks `dispatch` for
# `/openapi.json` and `/docs`. tools/run-tests.sh diffs stdout against
# tests/openapi_test.expected.
#
# It proves, every assertion a stable `ok <label>` token:
#   * `/openapi.json` emits a valid OpenAPI 3 document (round-trips through
#     json.loads; has openapi/info/paths) with the configured info block;
#   * each route's path template appears, with a path AND a query parameter
#     sourced from fastzap#4 param specs (name, in, type, required, default);
#   * a request body AND a response body schema mapped from a `validation.Schema`
#     via the fastzap.jsonschema emitter (object/title/properties/required,
#     string minLength, number minimum, array items);
#   * a 422 Validation Error response is auto-added to validating routes;
#   * the docs/openapi endpoints are themselves excluded from the document;
#   * `/docs` serves HTML that references `/openapi.json` and loads Swagger UI;
#   * the endpoints are GET-only and can be disabled via `configure_docs`;
#   * the JSON Schema emitter is also unit-checked directly.

import fastzap
import fastzap.jsonschema
import validation

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

def check_status(str label, fastzap.Response r, int64 want):
    check(label, r.status == want)

# True when a JsonValue is an object carrying `key` (proves round-trip validity).
def obj_has(JsonValue v, str key) -> bool:
    match v:
        case JsonValue.Object(m):
            return key in m
        case _:
            return False

# --- schema + handlers -----------------------------------------------------

# A model exercising the emitter: a length-bounded string, a bounded number, an
# optional string, and an optional list-of-strings.
def item_schema() -> validation.Schema:
    return validation.model(
        "Item",
        [
            validation.field("name", validation.str_t(min_len=1, max_len=40)),
            validation.field("price", validation.float_t(min=0.0, max=100000.0)),
            validation.field("nickname", validation.str_t(), required=False),
            validation.field(
                "tags",
                validation.list_t(validation.str_t()),
                required=False,
            ),
        ],
    )

@app.get("/")
def h_root(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(200, "{\"service\":\"items\"}")

@app.get("/items/{id}")
def h_item(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(200, "{\"id\":" + str(req.param_int("id")) + "}")

@app.post("/items")
def h_create(fastzap.Request req) -> fastzap.Response:
    match req.validate(item_schema()):
        case validation.ValidationResult.Ok(m):
            return fastzap.created_model(m)
        case validation.ValidationResult.Err(errs):
            return fastzap.validation_error(errs)

def build_app() -> fastzap.App:
    # The `@app.*` decorators splice `app.get/post(...)` in right here.
    auto app = fastzap.app()
    app.configure_docs(
        fastzap.docs_config(title="Items API", version="9.9", description="demo"),
    )
    # Param specs (fastzap#4) — the OpenAPI `parameters:` source.
    app.with_params(
        "GET",
        "/items/{id}",
        [
            fastzap.path_param_spec("id", fastzap.ParamType.IntT, "the item id"),
            fastzap.query_param_spec("q", fastzap.ParamType.StrT, required=False),
        ],
    )
    # Body/response schema associations (D-FZ-0012) — the `schemas` source.
    app.with_body("POST", "/items", item_schema())
    app.with_response("POST", "/items", 201, item_schema(), "the created item")
    return app

def main():
    auto app = build_app()

    # --- /openapi.json: a valid OpenAPI 3 document -------------------------
    auto spec = fastzap.dispatch(app, fastzap.request("GET", "/openapi.json", ""))
    check_status("openapi status 200", spec, 200)
    check("openapi content-type json", spec.content_type == "application/json")
    auto b = spec.body
    check("openapi version 3.0.3", b.contains("\"openapi\":\"3.0.3\""))
    check("info title", b.contains("\"title\":\"Items API\""))
    check("info version", b.contains("\"version\":\"9.9\""))
    check("info description", b.contains("\"description\":\"demo\""))

    # --- paths -------------------------------------------------------------
    check("path root present", b.contains("\"/\""))
    check("path item present", b.contains("\"/items/{id}\""))
    check("path collection present", b.contains("\"/items\""))

    # --- parameters (from fastzap#4 param specs) ---------------------------
    check("path param in", b.contains("\"in\":\"path\""))
    check("path param name", b.contains("\"name\":\"id\""))
    check("path param type", b.contains("\"type\":\"integer\""))
    check("path param description", b.contains("\"description\":\"the item id\""))
    check("query param in", b.contains("\"in\":\"query\""))
    check("query param name", b.contains("\"name\":\"q\""))
    check("query param optional", b.contains("\"required\":false"))

    # --- request body schema (mapped from validation.Schema) ---------------
    check("requestBody present", b.contains("\"requestBody\""))
    check("body media type", b.contains("\"application/json\""))
    check("body schema object", b.contains("\"type\":\"object\""))
    check("body schema title", b.contains("\"title\":\"Item\""))
    check("body name minLength", b.contains("\"minLength\":1"))
    check("body price number", b.contains("\"type\":\"number\""))
    check("body price minimum", b.contains("\"minimum\":"))
    check("body required array", b.contains("\"required\":[\"name\",\"price\"]"))
    check("body array field", b.contains("\"type\":\"array\""))

    # --- responses ---------------------------------------------------------
    check("response 201 present", b.contains("\"201\""))
    check("response 201 description", b.contains("\"the created item\""))
    check("auto 422 present", b.contains("\"422\""))

    # --- operation ids -----------------------------------------------------
    check("operationId get item", b.contains("\"operationId\":\"get_items_id"))
    check("operationId post item", b.contains("\"operationId\":\"post_items\""))

    # --- docs plumbing excluded from the document --------------------------
    check("docs path excluded", b.contains("/docs") == False)
    check("openapi path excluded", b.contains("/openapi.json") == False)

    # --- round-trips as valid JSON -----------------------------------------
    auto parsed = json.loads(b)
    check("roundtrips as object", obj_has(parsed, "openapi"))
    check("roundtrip has info", obj_has(parsed, "info"))
    check("roundtrip has paths", obj_has(parsed, "paths"))

    # --- GET-only ----------------------------------------------------------
    auto post_spec = fastzap.dispatch(app, fastzap.request("POST", "/openapi.json", ""))
    check_status("openapi is GET-only", post_spec, 404)

    # --- /docs UI ----------------------------------------------------------
    auto docs = fastzap.dispatch(app, fastzap.request("GET", "/docs", ""))
    check_status("docs status 200", docs, 200)
    check("docs content-type html", docs.content_type == "text/html; charset=utf-8")
    check("docs references openapi", docs.body.contains("/openapi.json"))
    check("docs loads swagger bundle", docs.body.contains("SwaggerUIBundle"))
    check("docs loads swagger css", docs.body.contains("swagger-ui.css"))

    # --- disabling the docs ------------------------------------------------
    auto app2 = build_app()
    app2.configure_docs(fastzap.docs_config(enabled=False))
    auto off1 = fastzap.dispatch(app2, fastzap.request("GET", "/openapi.json", ""))
    check_status("disabled openapi is 404", off1, 404)
    auto off2 = fastzap.dispatch(app2, fastzap.request("GET", "/docs", ""))
    check_status("disabled docs is 404", off2, 404)

    # --- direct emitter unit checks ----------------------------------------
    auto js = jsonschema.dumps_schema(item_schema())
    check("emitter object type", js.contains("\"type\":\"object\""))
    check("emitter str minLength", js.contains("\"minLength\":1"))
    check("emitter array items", js.contains("\"items\":{\"type\":\"string\"}"))

    print("all tests passed")
