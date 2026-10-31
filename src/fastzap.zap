# fastzap — a coroutine-native web framework for Zap.
#
# ONE framework, not Python's sync/async split. Because Zap coroutines are
# transparent and cheap (no async/await, no function coloring), a handler is a
# plain function that does straight-line, blocking I/O and returns a value; the
# framework runs thousands of them concurrently on the scheduler, each inside its
# own structured-concurrency `scope:` (zaplang-io/zap#50). It is served by its
# own built-in coroutine HTTP server on the stdlib `http`/`net` stack (#104) over
# the netpoller (#80) — there is no uvicorn/starlette/ASGI layer.
#
# Typed request/response models come from the `validation` package (#311): a
# request body is validated against a `validation.Schema` into a typed `Model`,
# and a `Model` serializes straight back out as a JSON response. Zap structs play
# pydantic's role; there is no separate schema layer.
#
# Quick taste (full program in examples/quickstart.zap):
#
#   import fastzap
#   import validation
#
#   def item_schema() -> validation.Schema:
#       return validation.model("Item", [
#           validation.field("name", validation.str_t(min_len=1)),
#           validation.field("price", validation.float_t(min=0.0)),
#       ])
#
#   def create_item(fastzap.Request req) -> fastzap.Response:
#       match req.validate(item_schema()):
#           case validation.ValidationResult.Ok(m):
#               return fastzap.created_model(m)
#           case validation.ValidationResult.Err(errs):
#               return fastzap.validation_error(errs)
#
#   def read_item(fastzap.Request req) -> fastzap.Response:
#       auto id = req.path_param_int("id", 0)
#       return fastzap.json_response(200, "{\"id\":" + str(id) + "}")
#
#   def main():
#       auto app = fastzap.app()
#       app.get("/items/{id}", read_item)
#       app.post("/items", create_item)
#       fastzap.run(app, "0.0.0.0", 8000)
#
# ROUTING SURFACE — why method-call registration, not `@app.get`:
# FastAPI registers routes with a decorator that *reads the handler's parameter
# annotations* to inject typed path/query/body params. Zap's user-defined
# function decorators are deferred (zaplang-io/zap#26/#16: only `@derive` and
# struct reflection exist today) and there is no function-parameter reflection,
# so neither the `@app.get("/x")` form nor per-parameter injection can exist yet.
# fastzap therefore uses method-call registration — `app.get("/x", handler)` —
# with a single uniform handler signature `fn(Request) -> Response`, and the
# handler pulls typed values off the Request (`path_param_int`, `query_int`,
# `validate`). This is the exact shape a future `@app.get` would lower to once
# decorator-codegen lands; see DECISIONS.md (D-FZ-0001).
#
# NOTE: Zap's `and`/`or` do not short-circuit today (both operands are always
# evaluated, zaplang-io/zap), so this module never guards an index/lookup with a
# boolean operator; such checks are written as nested `if`s.

import fastzap.wire
import validation

# ---------------------------------------------------------------------------
# Request / Response
# ---------------------------------------------------------------------------

# An incoming request, decomposed for the handler. `path` is the decoded path
# with the query removed; `query` and `path_params` are decoded string maps;
# `headers` holds a standard subset keyed by lowercase name (full header
# enumeration awaits an `http` stdlib addition — see DECISIONS.md D-FZ-0004).
struct Request:
    str method
    str path
    str target
    str body
    dict[str, str] query
    dict[str, str] path_params
    dict[str, str] headers

    # The raw request body as a string (e.g. a JSON document).
    def text(self) -> str:
        return self.body

    # Validate the request body against a schema, yielding a typed model or the
    # full list of validation errors (the `validation` package does the work).
    def validate(self, validation.Schema schema) -> validation.ValidationResult:
        return validation.validate_json(schema, self.body)

    # A query parameter as a string ("" when absent).
    def query_str(self, str name) -> str:
        if name in self.query:
            return self.query[name]
        return ""

    # A query parameter as a string, or `fallback` when absent.
    def query_or(self, str name, str fallback) -> str:
        if name in self.query:
            return self.query[name]
        return fallback

    # A query parameter parsed as an int, or `fallback` when absent/unparsable.
    def query_int(self, str name, int64 fallback) -> int64:
        if name in self.query:
            return _to_int(self.query[name], fallback)
        return fallback

    # A captured path parameter as a string ("" when absent).
    def path_param(self, str name) -> str:
        if name in self.path_params:
            return self.path_params[name]
        return ""

    # A captured path parameter parsed as an int, or `fallback` on failure.
    def path_param_int(self, str name, int64 fallback) -> int64:
        if name in self.path_params:
            return _to_int(self.path_params[name], fallback)
        return fallback

    # A request header by (case-insensitive) name ("" when absent).
    def header(self, str name) -> str:
        auto key = name.lower()
        if key in self.headers:
            return self.headers[key]
        return ""

# A response: an HTTP status, a content type, and a body. Build one with the
# helpers below (`json_response`, `ok_model`, ...) rather than by hand.
struct Response:
    int64 status
    str content_type
    str body

# Build a hand-rolled request (useful for tests and manual dispatch): parses the
# target into its path + query. Headers are empty.
def request(str method, str target, str body) -> Request:
    dict[str, str] pp = {}
    dict[str, str] hdrs = {}
    auto path = wire.target_path(target)
    auto query = wire.parse_query(wire.target_query(target))
    return Request(method, path, target, body, query, pp, hdrs)

# Parse an int, or return `fallback` when `s` is not a well-formed integer.
# `int()` aborts (an uncatchable fault, not a catchable exception) on bad input,
# so the string is validated BEFORE calling it rather than catching a failure.
def _to_int(str s, int64 fallback) -> int64:
    if _is_int_str(s):
        return int(s)
    return fallback

# True when `s` is a non-empty optionally-signed run of ASCII digits.
def _is_int_str(str s) -> bool:
    if len(s) == 0:
        return False
    auto start = 0
    if s[0:1] == "-":
        if len(s) == 1:
            return False
        start = 1
    auto j = start
    while j < len(s):
        auto c = s[j:j + 1]
        if c < "0":
            return False
        if c > "9":
            return False
        j = j + 1
    return True

# --- response builders -----------------------------------------------------

def response(int64 status, str content_type, str body) -> Response:
    return Response(status, content_type, body)

# A JSON response from an already-serialized body string.
def json_response(int64 status, str body) -> Response:
    return Response(status, "application/json", body)

# A plain-text response.
def text_response(int64 status, str body) -> Response:
    return Response(status, "text/plain; charset=utf-8", body)

# 200 with a validated model serialized back to JSON.
def ok_model(validation.Model m) -> Response:
    return json_response(200, m.dumps())

# 201 with a validated model serialized back to JSON.
def created_model(validation.Model m) -> Response:
    return json_response(201, m.dumps())

# A JSON error envelope: `{"detail": "..."}` with the given status.
def json_error(int64 status, str detail) -> Response:
    dict[str, JsonValue] o = {}
    o["detail"] = JsonValue.Str(detail)
    return json_response(status, json.dumps(JsonValue.Object(o)))

# A 422 response rendering a list of validation errors as structured JSON
# (`{"detail": "validation failed", "errors": [{loc, kind, msg}, ...]}`).
def validation_error(list[validation.ValErr] errs) -> Response:
    list[JsonValue] items = []
    auto i = 0
    while i < len(errs):
        dict[str, JsonValue] o = {}
        o["loc"] = JsonValue.Str(errs[i].loc)
        o["kind"] = JsonValue.Str(errs[i].kind)
        o["msg"] = JsonValue.Str(errs[i].msg)
        items.append(JsonValue.Object(o))
        i = i + 1
    dict[str, JsonValue] top = {}
    top["detail"] = JsonValue.Str("validation failed")
    top["errors"] = JsonValue.Array(items)
    return json_response(422, json.dumps(JsonValue.Object(top)))

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

# A registered route: HTTP method, the path template, its precomputed segments
# (a param segment keeps its `{name}` form), and the handler.
struct Route:
    str method
    str path
    list[str] segs
    fn(Request) -> Response handler

# The result of resolving a request against the route table. `idx` is the
# matching route or -1; `path_exists` distinguishes 404 (no path match) from 405
# (path matched, method did not); `params` holds captured path parameters.
struct RouteMatch:
    int64 idx
    bool path_exists
    dict[str, str] params

def _match(App app, str method, list[str] segs) -> RouteMatch:
    dict[str, str] none = {}
    auto path_exists = False
    auto i = 0
    while i < len(app.routes):
        auto r = app.routes[i]
        if len(r.segs) == len(segs):
            dict[str, str] params = {}
            auto ok = True
            auto j = 0
            while j < len(segs):
                auto pat = r.segs[j]
                if _is_param(pat):
                    params[pat[1:len(pat) - 1]] = segs[j]
                else:
                    if pat != segs[j]:
                        ok = False
                j = j + 1
            if ok:
                path_exists = True
                if r.method == method:
                    return RouteMatch(i, True, params)
        i = i + 1
    return RouteMatch(-1, path_exists, none)

def _is_param(str seg) -> bool:
    if len(seg) >= 2:
        if seg.startswith("{"):
            if seg.endswith("}"):
                return True
    return False

# ---------------------------------------------------------------------------
# Lifecycle / shutdown configuration
# ---------------------------------------------------------------------------

# The staged graceful-shutdown stages (zaplang-io/zap#312, folded-in #107).
enum Stage:
    Running
    Draining
    Stopping
    Done

# Mutable, shared server state (a plain struct is a reference type, D-0023, so
# the acceptor, the signal watchers and the handlers all observe one instance).
# `ready` backs the readiness endpoint; `triggered` is the one-shot shutdown
# latch; `active` is the best-effort in-flight request count.
struct ServerState:
    bool ready
    bool triggered
    Stage stage
    int64 active

# Graceful-shutdown knobs. `propagation_ms` is how long to KEEP serving after
# SIGTERM so Kubernetes endpoint/LB removal propagates before the listener
# closes; `grace_ms` is the additional budget to drain in-flight requests before
# a clean backstop exit. Both must sit comfortably under the pod's
# `terminationGracePeriodSeconds` (default 30s). `readiness_path` is the health
# endpoint that flips to 503 the moment shutdown begins.
struct ShutdownConfig:
    int64 propagation_ms
    int64 grace_ms
    str readiness_path

def shutdown_config(
    int64 propagation_ms,
    int64 grace_ms,
    str readiness_path,
) -> ShutdownConfig:
    return ShutdownConfig(propagation_ms, grace_ms, readiness_path)

# Defaults: serve 2s into the propagation window, then up to 25s of drain — a
# total well under the 30s k8s default so the process exits before SIGKILL.
def default_shutdown() -> ShutdownConfig:
    return ShutdownConfig(2000, 25000, "/healthz")

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

struct App:
    list[Route] routes
    ServerState state
    ShutdownConfig shutdown

    # Register a handler for an arbitrary method + path template.
    def route(self, str method, str path, fn(Request) -> Response h):
        self.routes.append(Route(method, path, wire.path_segments(path), h))

    def get(self, str path, fn(Request) -> Response h):
        self.route("GET", path, h)

    def post(self, str path, fn(Request) -> Response h):
        self.route("POST", path, h)

    def put(self, str path, fn(Request) -> Response h):
        self.route("PUT", path, h)

    def delete(self, str path, fn(Request) -> Response h):
        self.route("DELETE", path, h)

    def patch(self, str path, fn(Request) -> Response h):
        self.route("PATCH", path, h)

    # Replace the graceful-shutdown configuration.
    def configure_shutdown(self, ShutdownConfig cfg):
        self.shutdown = cfg

# Construct a new application with default shutdown settings.
def app() -> App:
    list[Route] rs = []
    auto st = ServerState(True, False, Stage.Running, 0)
    return App(rs, st, default_shutdown())

# Resolve a request to a response: the readiness endpoint first, then the route
# table (404 vs 405 distinguished), then the handler. Never raises.
def dispatch(App app, Request req) -> Response:
    if req.path == app.shutdown.readiness_path:
        if app.state.ready:
            return json_response(200, "{\"status\":\"ready\"}")
        return json_response(503, "{\"status\":\"draining\"}")
    auto segs = wire.path_segments(req.path)
    auto m = _match(app, req.method, segs)
    if m.idx < 0:
        if m.path_exists:
            return json_error(405, "method not allowed")
        return json_error(404, "not found")
    req.path_params = m.params
    fn(Request) -> Response h = app.routes[m.idx].handler
    return h(req)

# ---------------------------------------------------------------------------
# Server (coroutine accept loop + staged graceful shutdown)
# ---------------------------------------------------------------------------

# Start serving and block until a staged graceful shutdown completes.
#
# The accept loop and both signal watchers live in one structured-concurrency
# `scope:`. Each accepted connection is handled by an OWNED spawned coroutine, so
# the scope's join barrier at the dedent is exactly the in-flight drain: control
# does not leave until every handler has finished. On SIGTERM (or SIGINT for
# local dev) a watcher runs the staged drain (see `_trigger_shutdown`); closing
# the listener makes `net.accept` raise, which breaks the accept loop and lets
# the scope proceed to its join.
def run(App app, str host, int64 port):
    auto listener = net.listen(host, port)
    app.state.ready = True
    app.state.stage = Stage.Running
    auto term = signal.notify(Signal.SIGTERM)
    auto intr = signal.notify(Signal.SIGINT)
    scope:
        spawn detached _watch(app, listener, term)
        spawn detached _watch(app, listener, intr)
        auto accepting = True
        while accepting:
            try:
                auto conn = net.accept(listener)
                spawn _handle(app, conn)
            except:
                # The listener was closed by the shutdown watcher: stop accepting
                # and fall through to the scope join (drain in-flight requests).
                accepting = False
            checkpoint()
    app.state.stage = Stage.Done

# A signal watcher: wait for one delivery, then run the staged shutdown. Spawned
# detached (two of them, one per signal) so an unfired watcher never blocks the
# scope join.
def _watch(App app, bytes listener, channel[Signal] ch):
    auto _sig = <-ch
    begin_shutdown(app, listener)

# Run the staged graceful-shutdown sequence against a listener. Normally invoked
# by the signal watcher inside `run`; exposed so an admin route (or a test) can
# trigger a drain programmatically. Idempotent (one-shot latch).
def begin_shutdown(App app, bytes listener):
    _trigger_shutdown(app, listener)

# The staged drain (zaplang-io/zap#312 acceptance criterion). One-shot: under the
# cooperative scheduler the latch check-and-set has no await between read and
# write, so the two watchers cannot both pass it.
def _trigger_shutdown(App app, bytes listener):
    if app.state.triggered:
        return
    app.state.triggered = True
    # Stage 1 — flip readiness unready so the orchestrator removes the pod from
    # its Service endpoints and load balancers stop routing NEW traffic.
    app.state.ready = False
    app.state.stage = Stage.Draining
    # Stage 2 — keep serving during the endpoint-propagation window: endpoint/LB
    # removal is eventually consistent, so closing the listener immediately would
    # connection-refuse requests still being routed to us mid-propagation.
    _sleep_ms(app.shutdown.propagation_ms)
    # Stage 3 — stop accepting: closing the listener unblocks `net.accept`, which
    # raises and breaks the accept loop.
    app.state.stage = Stage.Stopping
    try:
        net.close_listener(listener)
    except:
        auto _ig = 0
    # Stage 5 backstop — never be SIGKILLed mid-request: if in-flight work
    # outlasts the grace budget, exit cleanly just under it. In the normal case
    # the scope join (Stage 4, the drain) finishes first and `run` returns before
    # this fires; a program that returns from `run` terminates this detached
    # timer on exit.
    spawn detached _grace_timer(app)

def _grace_timer(App app):
    _sleep_ms(app.shutdown.grace_ms)
    if _is_done(app.state.stage):
        return
    sys.exit(0)

# Handle one connection: parse, dispatch, write, close. Catches EVERYTHING — a
# handler coroutine must never let an exception escape, or the request scope
# would cancel its siblings (one malformed request would take down in-flight
# peers). A parse failure becomes 400; any handler/dispatch failure becomes 500.
def _handle(App app, bytes conn):
    app.state.active = app.state.active + 1
    try:
        auto reqh = http.read_request(conn)
        auto req = _build_request(reqh)
        auto resp = dispatch(app, req)
        _write(conn, resp)
    except:
        _write_safe(
            conn,
            wire.build_response(
                500,
                "application/json",
                "{\"detail\":\"internal server error\"}",
            ),
        )
    _close(conn)
    app.state.active = app.state.active - 1

def _build_request(bytes reqh) -> Request:
    auto method = http.method(reqh)
    auto target = http.path(reqh)
    auto body = http.req_body(reqh)
    auto path = wire.target_path(target)
    auto query = wire.parse_query(wire.target_query(target))
    dict[str, str] pp = {}
    dict[str, str] hdrs = {}
    _collect_headers(hdrs, reqh)
    return Request(method, path, target, body, query, pp, hdrs)

# Snapshot a standard subset of request headers (lowercase keys). Full header
# enumeration needs the `http` stdlib to expose the raw header block; until then
# this covers the common cases (see DECISIONS.md D-FZ-0004).
def _collect_headers(dict[str, str] into, bytes reqh):
    list[str] names = [
        "host",
        "content-type",
        "content-length",
        "accept",
        "authorization",
        "user-agent",
        "x-request-id",
    ]
    auto i = 0
    while i < len(names):
        auto v = http.req_header(reqh, names[i])
        if len(v) > 0:
            into[names[i]] = v
        i = i + 1

def _write(bytes conn, Response r):
    auto _n = net.send(conn, wire.build_response(r.status, r.content_type, r.body))

def _write_safe(bytes conn, str bytes_out):
    try:
        auto _n = net.send(conn, bytes_out)
    except:
        auto _ig = 0

def _close(bytes conn):
    try:
        net.close_conn(conn)
    except:
        auto _ig = 0

def _sleep_ms(int64 ms):
    if ms > 0:
        time.sleep_ns(ms * 1000000)

def _is_done(Stage s) -> bool:
    match s:
        case Stage.Done:
            return True
        case _:
            return False

# The current lifecycle stage as a lowercase string (handy for tests/logs).
def stage_name(Stage s) -> str:
    match s:
        case Stage.Running:
            return "running"
        case Stage.Draining:
            return "draining"
        case Stage.Stopping:
            return "stopping"
        case Stage.Done:
            return "done"

def stage_of(App app) -> str:
    return stage_name(app.state.stage)
