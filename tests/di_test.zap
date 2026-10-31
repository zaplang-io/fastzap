# Offline test driver for dependency injection (fastzap#7, DECISIONS.md
# D-FZ-0010). Exercises the idiomatic FastAPI `Depends(...)` form now shipped by
# the compiler (zaplang-io/zap#466, D-0092): a handler declares a dependency as a
# parameter `T x = Depends(provider)`, and the `@app.get` desugar synthesizes a
# per-handler adapter that resolves providers (deps-first, once per request) and
# injects them — all over the real `@app.get` dispatch path, without a socket.
#
# Three properties are proven, every one observable in stdout (providers print a
# token when their body actually runs; tools/run-tests.sh diffs stdout against
# tests/di_test.expected):
#   * injection + nesting — `me` gets a resolved `Principal`/`DB`; `get_db`'s own
#     `Settings` dependency is itself a `Depends(...)` parameter, resolved first;
#   * deps-first order — "load settings" prints before "build db" each request;
#   * per-request single-resolution — `me` takes `get_db` twice (directly and via
#     `get_user`), yet "build db" prints exactly once per request (FastAPI's
#     default `use_cache=True`), and a second request resolves afresh (per-request
#     lifetime), so the tokens repeat rather than leaking a cached value.

import fastzap

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

# --- an app dependency graph: settings <- db <- principal -------------------

struct Settings:
    str env

struct DB:
    str dsn

struct Principal:
    str who
    str dsn

# Leaf provider: no dependencies of its own.
def get_settings() -> Settings:
    print("load settings")
    return Settings("prod")

# Nested: `get_db` depends on `get_settings`, declared as a `Depends(...)`
# parameter. The adapter resolves `get_settings` first and passes it in. The
# "build db" print proves the body runs — exactly once per request.
def get_db(Settings s = Depends(get_settings)) -> DB:
    print("build db")
    return DB(s.env + "://db")

# Two levels deep: `get_user` depends on `get_db` (which depends on settings).
def get_user(DB db = Depends(get_db)) -> Principal:
    return Principal("alice", db.dsn)

# --- a handler that opts into DI, registered with the @app.get sugar --------
#
# `me` needs `get_db` twice: directly (`db`) and transitively through `user`.
# Per-request caching resolves `get_db` (and its `get_settings`) once and shares
# the result, so `user.dsn == db.dsn` and the provider bodies run a single time.
@app.get("/me")
def me(
    fastzap.Request req,
    Principal user = Depends(get_user),
    DB db = Depends(get_db),
) -> fastzap.Response:
    return fastzap.text_response(200, user.who + ";" + user.dsn + ";" + db.dsn)

def main():
    auto app = fastzap.app()

    # Injection + nesting + single-resolution: the composed graph resolves over
    # the real dispatch path; both `get_db` uses see one shared DB (builds once).
    auto r1 = fastzap.dispatch(app, fastzap.request("GET", "/me", ""))
    check("di injected graph resolves shared", r1.body == "alice;prod://db;prod://db")

    # Per-request lifetime: a second request gets a fresh scope — the providers
    # run again (the tokens repeat), nothing is leaked from the first request.
    auto r2 = fastzap.dispatch(app, fastzap.request("GET", "/me", ""))
    check("di per-request fresh scope", r2.body == "alice;prod://db;prod://db")

    print("all tests passed")
