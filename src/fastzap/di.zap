# fastzap.di — a prototype dependency-injection toolkit (fastzap#7).
#
# NOT the FastAPI signature. FastAPI reads a handler's declared parameters and
# *injects* resolved values into them (`def h(db: DB = Depends(get_db))`). That
# needs a reflection-driven adapter that binds a handler's params per request,
# which the language cannot express yet — parameter reflection (zaplang-io/zap#458,
# D-0089) is descriptive-only and name-keyed, while the dispatch seam holds opaque
# `fn(Request) -> Response` values. Tracked as zaplang-io/zap#466; see DECISIONS.md
# D-FZ-0008. Until it lands, this module delivers the *semantics* FastAPI `Depends`
# gives — **composable**, **per-request**, **shared (resolved once)** dependencies
# — as an explicit, fully type-safe, opt-in toolkit the handler drives itself. See
# DECISIONS.md D-FZ-0009.
#
# The model. A dependency is a plain provider function. The app bundles one `Cell`
# per shared dependency into a concrete per-request context `struct` and builds a
# fresh one at the top of each handler (exactly one handler runs per request, so a
# per-handler context *is* per-request). Providers memoize into their cell, so a
# dependency needed by several providers resolves once per request; a provider
# composes simply by calling another provider on the same context.
#
#   struct Ctx:                       # the app's dependency graph, one Cell each
#       di.Cell[Settings] settings
#       di.Cell[DB] db
#
#   def fresh_ctx() -> Ctx:
#       return Ctx(di.new_cell[Settings](), di.new_cell[DB]())
#
#   def get_settings(Ctx c) -> Settings:
#       return di.resolve(c.settings, lambda: Settings("prod"))
#
#   def get_db(Ctx c) -> DB:          # composes: db depends on settings
#       return di.resolve(c.db, lambda: DB(get_settings(c).env + "://db"))
#
#   @app.get("/me")
#   def me(fastzap.Request req) -> fastzap.Response:
#       auto c = fresh_ctx()          # per-request scope
#       return fastzap.text_response(200, get_db(c).dsn)
#
# A `Cell[T]` is a reference `struct` (D-0023), so `resolve`/`cell_put` mutate the
# caller's cell in place — the memo is shared across every provider that reads the
# same context value within the request. This module is a LEAF: it uses only
# generics (zaplang-io/zap#154) and `Optional`, and never imports a fastzap type,
# so a handler `import`s it directly (`import fastzap.di`).

# A per-request memo slot holding a single dependency value, empty until resolved.
struct Cell[T]:
    Optional[T] value

# An empty cell. The element type cannot be inferred (no argument carries it), so
# call it with an explicit type argument: `di.new_cell[DB]()`.
def new_cell[T]() -> Cell[T]:
    Optional[T] empty = None
    return Cell(empty)

# True once the cell has been resolved/filled this request.
def cell_has[T](Cell[T] c) -> bool:
    return not c.value.is_none()

# Store a value in the cell, overwriting any previous one.
def cell_put[T](Cell[T] c, T v):
    c.value = Optional.Some(v)

# The resolved value; aborts if the cell is empty, so pair it with `cell_has`
# (or prefer `resolve` / `cell_or`, which never abort).
def cell_value[T](Cell[T] c) -> T:
    return c.value.unwrap()

# The resolved value, or `fallback` when the cell is still empty.
def cell_or[T](Cell[T] c, T fallback) -> T:
    return c.value.unwrap_or(fallback)

# Resolve-once: if the cell is empty, run `provider` and memoize its result;
# otherwise return the memoized value without running it again. This is the
# headline primitive — the `Depends(...)` analogue. `provider` is a thunk, so a
# dependency that itself has dependencies composes by calling their providers
# inside the thunk (`lambda: Principal(get_db(c).dsn)`), and each resolves once.
def resolve[T](Cell[T] c, fn() -> T provider) -> T:
    if c.value.is_none():
        c.value = Optional.Some(provider())
    return c.value.unwrap()
