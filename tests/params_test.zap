# Offline test driver for strict typed-param coercion (fastzap#4, DECISIONS.md
# D-FZ-0011). Exercises the explicit param-spec surface: a route DECLARES its
# params with `App.with_params(...)`, and `dispatch` validates + coerces them off
# the Request BEFORE the handler runs — a missing-required or unparsable value
# short-circuits to a 422 with field-located `validation.ValErr`s (reusing the
# body-validation envelope), and on success the handler reads coerced values off
# `req.param_int/param_str/param_bool`. Runs over the real dispatch path without a
# socket; tools/run-tests.sh diffs stdout against tests/params_test.expected.
#
# It proves, every assertion a stable `ok <label>` token:
#   * specs compose with the `@app.get` decorator (`/search` is decorated, then
#     given specs) AND with programmatic registration (`/items/{id}`);
#   * a valid request runs the handler with coerced int/str/bool values, incl. an
#     applied default and case-insensitive bool spellings;
#   * a missing required param → 422 (loc "query.q", kind "missing");
#   * an unparsable typed value → 422 for int (path + query) and bool;
#   * multiple failures are collected into one 422, not just the first;
#   * the lenient fallback accessors (`query_int(name, fallback)`) are UNCHANGED
#     on a route that declares no specs.

import fastzap

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

def check_status(str label, fastzap.Response r, int64 want):
    check(label, r.status == want)

# --- handlers --------------------------------------------------------------

# Reads three strictly-coerced params. `active` is an optional bool (absent →
# False); `n` has a default of 10 applied when absent.
@app.get("/search")
def h_search(fastzap.Request req) -> fastzap.Response:
    auto a = "0"
    if req.param_bool("active"):
        a = "1"
    auto body = "q=" + req.param_str("q") + ";n=" + str(req.param_int("n")) + ";active=" + a
    return fastzap.text_response(200, body)

# Reads a strictly-coerced path int.
def h_item(fastzap.Request req) -> fastzap.Response:
    return fastzap.text_response(200, "id=" + str(req.param_int("id")))

# Declares NO specs: proves the lenient `query_int(name, fallback)` contract is
# untouched (garbage → the supplied default, no 422).
def h_legacy(fastzap.Request req) -> fastzap.Response:
    return fastzap.text_response(200, "n=" + str(req.query_int("n", 99)))

def main():
    auto app = fastzap.app()
    # `@app.get("/search")` splices `app.get("/search", h_search)` here first.
    app.get("/items/{id}", h_item)
    app.get("/legacy", h_legacy)

    # Attach param specs declaratively — composes with the decorated route and
    # the programmatic one alike (the routes already exist at this point).
    app.with_params(
        "GET",
        "/search",
        [
            fastzap.query_param_spec("q", fastzap.ParamType.StrT),
            fastzap.query_param_default("n", fastzap.ParamType.IntT, "10"),
            fastzap.query_param_spec("active", fastzap.ParamType.BoolT, required=False),
        ],
    )
    app.with_params(
        "GET",
        "/items/{id}",
        [fastzap.path_param_spec("id", fastzap.ParamType.IntT)],
    )

    # --- valid requests: handler runs with coerced values ------------------
    auto r_ok = fastzap.dispatch(
        app,
        fastzap.request("GET", "/search?q=hi&n=3&active=true", ""),
    )
    check_status("valid coerces status", r_ok, 200)
    check("valid coerces int+str+bool", r_ok.body == "q=hi;n=3;active=1")

    auto r_def = fastzap.dispatch(app, fastzap.request("GET", "/search?q=hi", ""))
    check("optional default applied", r_def.body == "q=hi;n=10;active=0")

    auto r_bf = fastzap.dispatch(
        app,
        fastzap.request("GET", "/search?q=hi&active=0", ""),
    )
    check("bool false spelling", r_bf.body == "q=hi;n=10;active=0")

    auto r_bu = fastzap.dispatch(
        app,
        fastzap.request("GET", "/search?q=hi&active=TRUE", ""),
    )
    check("bool case-insensitive true", r_bu.body == "q=hi;n=10;active=1")

    auto r_pid = fastzap.dispatch(app, fastzap.request("GET", "/items/42", ""))
    check_status("valid path int status", r_pid, 200)
    check("valid path int coerced", r_pid.body == "id=42")

    # --- missing required -> 422 with a field-located error ----------------
    auto r_miss = fastzap.dispatch(app, fastzap.request("GET", "/search?n=3", ""))
    check_status("missing required is 422", r_miss, 422)
    check("missing names the field", r_miss.body.contains("\"loc\":\"query.q\""))
    check("missing kind is 'missing'", r_miss.body.contains("\"kind\":\"missing\""))

    # --- unparsable typed value -> 422 -------------------------------------
    auto r_badq = fastzap.dispatch(
        app,
        fastzap.request("GET", "/search?q=hi&n=oops", ""),
    )
    check_status("unparsable query int is 422", r_badq, 422)
    check("query int error located", r_badq.body.contains("\"loc\":\"query.n\""))
    check("query int error kind", r_badq.body.contains("\"kind\":\"int_parsing\""))

    auto r_badp = fastzap.dispatch(app, fastzap.request("GET", "/items/abc", ""))
    check_status("unparsable path int is 422", r_badp, 422)
    check("path int error located", r_badp.body.contains("\"loc\":\"path.id\""))

    auto r_badb = fastzap.dispatch(
        app,
        fastzap.request("GET", "/search?q=hi&active=maybe", ""),
    )
    check_status("unparsable bool is 422", r_badb, 422)
    check("bool error kind", r_badb.body.contains("\"kind\":\"bool_parsing\""))

    # --- multiple failures collected into one 422 --------------------------
    auto r_multi = fastzap.dispatch(app, fastzap.request("GET", "/search?n=oops", ""))
    check_status("multi-error is 422", r_multi, 422)
    check("multi reports missing q", r_multi.body.contains("\"loc\":\"query.q\""))
    check("multi reports bad n", r_multi.body.contains("\"loc\":\"query.n\""))

    # --- lenient fallback accessors UNCHANGED (no-spec route) --------------
    auto r_lg = fastzap.dispatch(app, fastzap.request("GET", "/legacy?n=oops", ""))
    check_status("no-spec route still 200", r_lg, 200)
    check("query_int fallback unchanged on garbage", r_lg.body == "n=99")
    auto r_lg2 = fastzap.dispatch(app, fastzap.request("GET", "/legacy?n=5", ""))
    check("query_int parses when valid", r_lg2.body == "n=5")

    print("all tests passed")
