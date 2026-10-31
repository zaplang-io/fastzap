# Offline test driver for the `@app.get` decorator routing sugar (fastzap#8,
# DECISIONS.md D-FZ-0007; language support zaplang-io/zap#457 / D-0087).
#
# `@app.get("/path")` on a `def h(Request) -> Response` is pure surface sugar: it
# desugars (before sema, whole-program) to the method-call registration the
# engine already runs — `app.get("/path", h)` — spliced in immediately after the
# receiver's binding (`auto app = fastzap.app()`), in decorated-def source order.
# The engine, the route table and `dispatch` are UNCHANGED (see tests/
# fastzap_test.zap, which exercises the same engine via explicit registration).
#
# This driver proves the decorator form registers and dispatches identically:
# the decorated handlers below are plain module-level `def`s; `main` only binds
# the app and dispatches — every `app.<method>(...)` call is injected by the
# decorator desugar, not written by hand. Each check prints a stable `ok <label>`
# token (never a raw value); tools/run-tests.sh diffs stdout against
# tests/decorator_test.expected.

import fastzap
import validation

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

def check_status(str label, fastzap.Response r, int64 want):
    check(label, r.status == want)

def item_schema() -> validation.Schema:
    return validation.model(
        "Item",
        [
            validation.field("name", validation.str_t(min_len=1, max_len=40)),
            validation.field("price", validation.float_t(min=0.0, max=100000.0)),
        ],
    )

# --- handlers, registered purely by `@app.<method>` decorators --------------

@app.get("/")
def h_root(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(200, "{\"root\":true}")

@app.get("/items/{id}")
def h_item(fastzap.Request req) -> fastzap.Response:
    auto id = req.path_param_int("id", -1)
    return fastzap.text_response(200, "id=" + str(id))

@app.get("/search")
def h_search(fastzap.Request req) -> fastzap.Response:
    auto q = req.query_str("q")
    auto n = req.query_int("n", 0)
    return fastzap.text_response(200, "q=" + q + ";n=" + str(n))

@app.post("/items")
def h_create(fastzap.Request req) -> fastzap.Response:
    match req.validate(item_schema()):
        case validation.ValidationResult.Ok(m):
            return fastzap.created_model(m)
        case validation.ValidationResult.Err(errs):
            return fastzap.validation_error(errs)

@app.delete("/items/{id}")
def h_delete(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(204, "")

def main():
    # The `@app.get`/`@app.post`/`@app.delete` registrations above are spliced in
    # here, right after this binding, in source order — no explicit `app.get(...)`
    # is written anywhere in this file.
    auto app = fastzap.app()

    # The decorators populated the route table (5 routes registered above).
    check("decorator registered all routes", len(app.routes) == 5)

    # --- decorated GET dispatch -------------------------------------------
    auto r_root = fastzap.dispatch(app, fastzap.request("GET", "/", ""))
    check_status("decorated root status", r_root, 200)
    check("decorated root body", r_root.body == "{\"root\":true}")

    auto r_item = fastzap.dispatch(app, fastzap.request("GET", "/items/42", ""))
    check_status("decorated path param status", r_item, 200)
    check("decorated path param captured", r_item.body == "id=42")

    auto r_q = fastzap.dispatch(
        app,
        fastzap.request("GET", "/search?q=hi+there&n=3", ""),
    )
    check("decorated query parsed", r_q.body == "q=hi there;n=3")

    # --- decorated POST + validation bridge -------------------------------
    auto good = "{\"name\":\"Book\",\"price\":9.5}"
    auto r_ok = fastzap.dispatch(app, fastzap.request("POST", "/items", good))
    check_status("decorated post valid is 201", r_ok, 201)
    check("decorated post echoes name", r_ok.body.contains("Book"))

    auto bad = "{\"name\":\"\",\"price\":-1.0}"
    auto r_bad = fastzap.dispatch(app, fastzap.request("POST", "/items", bad))
    check_status("decorated post invalid is 422", r_bad, 422)

    # --- same engine: 404 / 405 distinction still holds -------------------
    auto r_404 = fastzap.dispatch(app, fastzap.request("GET", "/nope", ""))
    check_status("decorated unknown path is 404", r_404, 404)

    auto r_405 = fastzap.dispatch(app, fastzap.request("PUT", "/items/42", ""))
    check_status("decorated wrong method is 405", r_405, 405)

    # DELETE is registered (distinct method, same path template as GET /items/{id}).
    auto r_del = fastzap.dispatch(app, fastzap.request("DELETE", "/items/9", ""))
    check_status("decorated delete status", r_del, 204)

    print("all tests passed")
