# Offline test driver for the middleware / filter chain (fastzap#2, DECISIONS.md
# D-FZ-0013). Exercises the onion chain around `dispatch` WITHOUT a socket, by
# registering middleware with `app.use(...)` and calling `fastzap.dispatch` on
# hand-built requests, so it is fully deterministic and needs no network.
#
# Proven here (every one through the real `dispatch` chain):
#   * ordering + after-handling — two middlewares tag the Response on the way out;
#     the inner one tags first (reverse order), proving the onion;
#   * short-circuit — an auth guard returns 401 WITHOUT calling the handler;
#     pass-through — with credentials, the handler runs;
#   * request-id — an incoming id is propagated (to the handler AND echoed on the
#     Response); with none, a non-empty id is generated and reaches both;
#   * CORS — allow-origin/methods headers are present; an OPTIONS preflight is
#     short-circuited with 204;
#   * error-mapper — a handler that raises is mapped to a JSON 500; a normal
#     handler passes straight through;
#   * access log — the logger emits one `METHOD path -> status` line (captured in
#     the golden) and returns the response unchanged;
#   * composition — error-mapper + request-id + CORS layer on one app at once.
#
# Each check prints a stable `ok <label>` token (never a raw value); the sole
# non-`ok` stdout line is the access-log line, which the golden pins.
# tools/run-tests.sh diffs stdout against tests/middleware_test.expected.

import fastzap

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

# --- handlers --------------------------------------------------------------

def h_body(fastzap.Request req) -> fastzap.Response:
    return fastzap.text_response(200, "H")

def h_secret(fastzap.Request req) -> fastzap.Response:
    return fastzap.text_response(200, "secret")

def h_echo_rid(fastzap.Request req) -> fastzap.Response:
    return fastzap.text_response(200, req.header("X-Request-Id"))

def h_boom(fastzap.Request req) -> fastzap.Response:
    raise "handler failed"

def h_ok(fastzap.Request req) -> fastzap.Response:
    return fastzap.text_response(200, "ok")

# --- test middleware (two body-tagging layers, to prove onion order) --------

def _tag_a(
    fastzap.Request req,
    fn(fastzap.Request) -> fastzap.Response nxt,
) -> fastzap.Response:
    fn(fastzap.Request) -> fastzap.Response n = nxt
    auto resp = n(req)
    return fastzap.text_response(resp.status, resp.body + ";A")

def _tag_b(
    fastzap.Request req,
    fn(fastzap.Request) -> fastzap.Response nxt,
) -> fastzap.Response:
    fn(fastzap.Request) -> fastzap.Response n = nxt
    auto resp = n(req)
    return fastzap.text_response(resp.status, resp.body + ";B")

# An auth guard: short-circuit with 401 unless an Authorization header is present.
def _guard(
    fastzap.Request req,
    fn(fastzap.Request) -> fastzap.Response nxt,
) -> fastzap.Response:
    if req.header("Authorization") == "":
        return fastzap.json_error(401, "unauthorized")
    fn(fastzap.Request) -> fastzap.Response n = nxt
    return n(req)

def main():
    # --- ordering + after-handling (onion) ---------------------------------
    auto app1 = fastzap.app()
    app1.use(fastzap.middleware("A", _tag_a))
    app1.use(fastzap.middleware("B", _tag_b))
    app1.get("/", h_body)
    auto r1 = fastzap.dispatch(app1, fastzap.request("GET", "/", ""))
    check("chain status 200", r1.status == 200)
    # A is outermost (registered first); the handler returns "H", B (inner) tags
    # first on the way out, then A: "H;B;A".
    check("onion after-order H;B;A", r1.body == "H;B;A")

    # --- short-circuit vs pass-through -------------------------------------
    auto app2 = fastzap.app()
    app2.use(fastzap.middleware("guard", _guard))
    app2.get("/secret", h_secret)
    auto r_block = fastzap.dispatch(app2, fastzap.request("GET", "/secret", ""))
    check("short-circuit status 401", r_block.status == 401)
    check("short-circuit skipped handler", r_block.body.contains("unauthorized"))
    auto req_ok = fastzap.request("GET", "/secret", "")
    req_ok.headers["authorization"] = "Bearer t"
    auto r_pass = fastzap.dispatch(app2, req_ok)
    check("pass-through status 200", r_pass.status == 200)
    check("pass-through ran handler", r_pass.body == "secret")

    # --- request-id: propagate + generate ----------------------------------
    auto app3 = fastzap.app()
    app3.use(fastzap.request_id())
    app3.get("/rid", h_echo_rid)
    auto req_rid = fastzap.request("GET", "/rid", "")
    req_rid.headers["x-request-id"] = "abc123"
    auto r_rid = fastzap.dispatch(app3, req_rid)
    check(
        "request-id echoed on response",
        fastzap.response_header(r_rid, "X-Request-Id") == "abc123",
    )
    check("request-id reaches handler", r_rid.body == "abc123")
    auto r_gen = fastzap.dispatch(app3, fastzap.request("GET", "/rid", ""))
    check(
        "request-id generated on response",
        len(fastzap.response_header(r_gen, "X-Request-Id")) > 0,
    )
    check("request-id generated reaches handler", len(r_gen.body) > 0)

    # --- CORS: headers + preflight short-circuit ---------------------------
    auto app4 = fastzap.app()
    app4.use(fastzap.cors_default())
    app4.get("/c", h_ok)
    auto r_c = fastzap.dispatch(app4, fastzap.request("GET", "/c", ""))
    check(
        "cors allow-origin present",
        fastzap.response_header(r_c, "Access-Control-Allow-Origin") == "*",
    )
    check(
        "cors allow-methods present",
        fastzap.response_header(r_c, "Access-Control-Allow-Methods").contains("GET"),
    )
    auto r_pre = fastzap.dispatch(app4, fastzap.request("OPTIONS", "/c", ""))
    check("cors preflight 204", r_pre.status == 204)
    check(
        "cors preflight origin",
        fastzap.response_header(r_pre, "Access-Control-Allow-Origin") == "*",
    )

    # --- error-mapper: thrown -> JSON 500; normal passes through -----------
    auto app5 = fastzap.app()
    app5.use(fastzap.error_mapper())
    app5.get("/boom", h_boom)
    app5.get("/fine", h_ok)
    auto r_err = fastzap.dispatch(app5, fastzap.request("GET", "/boom", ""))
    check("error mapped to 500", r_err.status == 500)
    check(
        "error body is json detail",
        r_err.body == "{\"detail\":\"internal server error\"}",
    )
    auto r_fine = fastzap.dispatch(app5, fastzap.request("GET", "/fine", ""))
    check("error-mapper passes normal through", r_fine.status == 200)

    # --- access log (prints one line, captured by the golden) --------------
    auto app6 = fastzap.app()
    app6.use(fastzap.access_log())
    app6.get("/log", h_ok)
    auto r_log = fastzap.dispatch(app6, fastzap.request("GET", "/log", ""))
    check("access log transparent", r_log.status == 200)

    # --- composition: error-mapper + request-id + CORS on one app ----------
    auto app7 = fastzap.app()
    app7.use(fastzap.error_mapper())
    app7.use(fastzap.request_id())
    app7.use(fastzap.cors_default())
    app7.get("/all", h_ok)
    auto r_all = fastzap.dispatch(app7, fastzap.request("GET", "/all", ""))
    check("stack status 200", r_all.status == 200)
    check(
        "stack has request-id",
        len(fastzap.response_header(r_all, "X-Request-Id")) > 0,
    )
    check(
        "stack has cors origin",
        fastzap.response_header(r_all, "Access-Control-Allow-Origin") == "*",
    )

    print("all tests passed")
