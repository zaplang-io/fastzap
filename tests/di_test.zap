# Offline test driver for the dependency-injection prototype (fastzap#7,
# DECISIONS.md D-FZ-0009; module src/fastzap/di.zap). Exercises the three
# semantics FastAPI `Depends` gives — composition, per-request lifetime, and
# shared single-resolution — over the real `@app.get` dispatch path, without a
# socket. Each check prints a stable `ok <label>`; tools/run-tests.sh diffs
# stdout against tests/di_test.expected.

import fastzap
import fastzap.di

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
    int64 id

struct Principal:
    str who
    str dsn

# One Cell per shared dependency, plus a build counter that proves the DB
# provider runs exactly once per request (shared resolution).
struct Ctx:
    di.Cell[Settings] settings
    di.Cell[DB] db
    di.Cell[Principal] user
    di.Cell[int64] db_builds

def fresh_ctx() -> Ctx:
    return Ctx(
        di.new_cell[Settings](),
        di.new_cell[DB](),
        di.new_cell[Principal](),
        di.new_cell[int64](),
    )

# Leaf dependency.
def get_settings(Ctx c) -> Settings:
    return di.resolve(c.settings, lambda: Settings("prod"))

# Composes on settings; bumps db_builds each time the provider body runs.
def build_db(Ctx c) -> DB:
    auto s = get_settings(c)
    auto prev = di.cell_or(c.db_builds, 0)
    di.cell_put(c.db_builds, prev + 1)
    return DB(s.env + "://db", prev + 1)

def get_db(Ctx c) -> DB:
    return di.resolve(c.db, lambda: build_db(c))

# Composes on db (two levels deep).
def get_user(Ctx c) -> Principal:
    return di.resolve(c.user, lambda: Principal("alice", get_db(c).dsn))

# --- a handler that opts into DI, registered with the @app.get sugar --------

@app.get("/me")
def me(fastzap.Request req) -> fastzap.Response:
    auto c = fresh_ctx()
    auto user = get_user(c)  # resolves user -> db -> settings
    auto db = get_db(c)  # SHARED: cache hit, build_db does NOT run again
    auto builds = di.cell_or(c.db_builds, 0)
    return fastzap.text_response(
        200,
        user.who + ";" + db.dsn + ";builds=" + str(builds),
    )

def main():
    auto app = fastzap.app()

    # Over the real dispatch path: the composed graph resolves and db builds once.
    auto r1 = fastzap.dispatch(app, fastzap.request("GET", "/me", ""))
    check("di composed graph resolves", r1.body == "alice;prod://db;builds=1")

    # Per-request lifetime: a second request gets a fresh scope — db builds again
    # (count resets to 1), it is not leaked from the first request.
    auto r2 = fastzap.dispatch(app, fastzap.request("GET", "/me", ""))
    check("di per-request fresh scope", r2.body == "alice;prod://db;builds=1")

    # Shared single-resolution, inspected directly: two get_db calls on one
    # context resolve the DB provider exactly once.
    auto c = fresh_ctx()
    auto a = get_db(c)
    auto b = get_db(c)
    check("di shared single build", di.cell_or(c.db_builds, 0) == 1)
    check("di same instance id", a.id == b.id)

    # The closure-free check/put form of a cell.
    di.Cell[int64] cnt = di.new_cell[int64]()
    check("di empty cell has nothing", not di.cell_has(cnt))
    check("di empty cell falls back", di.cell_or(cnt, 7) == 7)
    di.cell_put(cnt, 5)
    check("di cell has after put", di.cell_has(cnt))
    check("di cell value after put", di.cell_value(cnt) == 5)

    print("all tests passed")
