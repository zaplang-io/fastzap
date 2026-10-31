# Offline test driver for fastzap: routing (literals, path params, 404 vs 405),
# query parsing (defaults, `+` and %XX decoding), the readiness endpoint, the
# response builders, the validation-package bridge, and the HTTP/1.1 wire
# serialization. It exercises the request pipeline WITHOUT opening a socket by
# calling `fastzap.dispatch` directly on hand-built requests, so it is fully
# deterministic and needs no network.
#
# Each check prints a stable `ok <label>` token (never a raw value, so float/JSON
# formatting never destabilizes the golden); tools/run-tests.sh diffs stdout
# against tests/fastzap_test.expected. A failed assertion prints `FAIL <label>`
# instead, so the diff localizes the break. The live socket server and the
# staged-drain signal path are covered by tests/shutdown_test.zap and the
# examples; see DESIGN.md "Testing".

import fastzap
import fastzap.wire
import validation

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

def check_status(str label, fastzap.Response r, int64 want):
    check(label, r.status == want)

# --- schema + handlers -----------------------------------------------------

def item_schema() -> validation.Schema:
    return validation.model(
        "Item",
        [
            validation.field("name", validation.str_t(min_len=1, max_len=40)),
            validation.field("price", validation.float_t(min=0.0, max=100000.0)),
        ],
    )

def h_root(fastzap.Request req) -> fastzap.Response:
    return fastzap.json_response(200, "{\"root\":true}")

def h_item(fastzap.Request req) -> fastzap.Response:
    auto id = req.path_param_int("id", -1)
    return fastzap.text_response(200, "id=" + str(id))

def h_user_post(fastzap.Request req) -> fastzap.Response:
    auto u = req.path_param("uid")
    auto p = req.path_param("pid")
    return fastzap.text_response(200, "u=" + u + ";p=" + p)

def h_search(fastzap.Request req) -> fastzap.Response:
    auto q = req.query_str("q")
    auto n = req.query_int("n", 0)
    return fastzap.text_response(200, "q=" + q + ";n=" + str(n))

def h_create(fastzap.Request req) -> fastzap.Response:
    match req.validate(item_schema()):
        case validation.ValidationResult.Ok(m):
            return fastzap.created_model(m)
        case validation.ValidationResult.Err(errs):
            return fastzap.validation_error(errs)

def build_app() -> fastzap.App:
    auto app = fastzap.app()
    app.get("/", h_root)
    app.get("/items/{id}", h_item)
    app.get("/users/{uid}/posts/{pid}", h_user_post)
    app.get("/search", h_search)
    app.post("/items", h_create)
    return app

def main():
    auto app = build_app()

    # --- routing -----------------------------------------------------------
    auto r_root = fastzap.dispatch(app, fastzap.request("GET", "/", ""))
    check_status("route root status", r_root, 200)
    check("route root body", r_root.body == "{\"root\":true}")

    auto r_item = fastzap.dispatch(app, fastzap.request("GET", "/items/42", ""))
    check_status("path param status", r_item, 200)
    check("path param captured", r_item.body == "id=42")
    check("path param content-type", r_item.content_type == "text/plain; charset=utf-8")

    auto r_trail = fastzap.dispatch(app, fastzap.request("GET", "/items/7/", ""))
    check("trailing slash normalized", r_trail.body == "id=7")

    auto r_multi = fastzap.dispatch(
        app,
        fastzap.request("GET", "/users/ada/posts/9", ""),
    )
    check("two path params", r_multi.body == "u=ada;p=9")

    auto r_404 = fastzap.dispatch(app, fastzap.request("GET", "/nope", ""))
    check_status("unknown path is 404", r_404, 404)

    auto r_405 = fastzap.dispatch(app, fastzap.request("DELETE", "/items/42", ""))
    check_status("wrong method is 405", r_405, 405)

    # --- query parsing -----------------------------------------------------
    auto r_q = fastzap.dispatch(
        app,
        fastzap.request("GET", "/search?q=hi+there&n=3", ""),
    )
    check("query plus-decoded + int", r_q.body == "q=hi there;n=3")

    auto r_pct = fastzap.dispatch(app, fastzap.request("GET", "/search?q=a%20b%21", ""))
    check("query percent-decoded", r_pct.body == "q=a b!;n=0")

    auto r_def = fastzap.dispatch(app, fastzap.request("GET", "/search", ""))
    check("query defaults", r_def.body == "q=;n=0")

    auto r_badn = fastzap.dispatch(app, fastzap.request("GET", "/search?n=oops", ""))
    check("query_int fallback on garbage", r_badn.body == "q=;n=0")

    # --- readiness ---------------------------------------------------------
    auto r_health = fastzap.dispatch(app, fastzap.request("GET", "/healthz", ""))
    check_status("readiness ready is 200", r_health, 200)
    app.state.ready = False
    auto r_health2 = fastzap.dispatch(app, fastzap.request("GET", "/healthz", ""))
    check_status("readiness draining is 503", r_health2, 503)
    app.state.ready = True

    # --- validation bridge -------------------------------------------------
    auto good = "{\"name\":\"Book\",\"price\":9.5}"
    auto r_ok = fastzap.dispatch(app, fastzap.request("POST", "/items", good))
    check_status("valid body is 201", r_ok, 201)
    check("created content-type json", r_ok.content_type == "application/json")
    check("created echoes name", r_ok.body.contains("Book"))

    auto bad = "{\"name\":\"\",\"price\":-1.0}"
    auto r_bad = fastzap.dispatch(app, fastzap.request("POST", "/items", bad))
    check_status("invalid body is 422", r_bad, 422)
    check("422 names the failure", r_bad.body.contains("validation failed"))
    check("422 reports a field", r_bad.body.contains("name"))

    # --- error envelope ----------------------------------------------------
    auto e = fastzap.json_error(404, "missing")
    check("json_error status", e.status == 404)
    check("json_error body", e.body == "{\"detail\":\"missing\"}")

    # --- wire serialization ------------------------------------------------
    auto w = wire.build_response(200, "application/json", "{\"ok\":true}")
    check("wire status line", w.startswith("HTTP/1.1 200 OK\r\n"))
    check("wire content-type", w.contains("Content-Type: application/json\r\n"))
    check("wire content-length", w.contains("Content-Length: 11\r\n"))
    check("wire connection close", w.contains("Connection: close\r\n"))
    check("wire body after blank line", w.endswith("\r\n\r\n{\"ok\":true}"))

    print("all tests passed")
