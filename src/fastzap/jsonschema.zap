# fastzap.jsonschema — a JSON Schema emitter for `validation.Schema`.
#
# Maps a `validation` schema (and its field types/constraints) to a JSON Schema
# object (the `JsonValue` DOM), which fastzap#3 embeds in the generated OpenAPI 3
# document as request/response body schemas. The emitted dialect is the subset
# OpenAPI 3.0 uses (JSON Schema draft-04-ish — `type`, `properties`, `required`,
# `minimum`/`maximum`, `minLength`/`maxLength`, `pattern`, `items`,
# `minItems`/`maxItems`, `additionalProperties`).
#
# A self-contained leaf module: it imports ONLY `validation` (for the schema
# types) and manipulates the prelude `JsonValue` DOM, so it never imports back
# into `fastzap` and the import graph stays acyclic (Zap v1 rejects cycles,
# D-0081). It is deliberately framework-agnostic — nothing here knows about
# routes, requests or HTTP — so it can be lifted into the `validation` package
# itself later (see DECISIONS.md D-FZ-0012); fastzap vendors it for now.
#
# NOTE: Zap's `and`/`or` do not short-circuit today (both operands are always
# evaluated, zaplang-io/zap), so this module never guards an index/lookup with a
# boolean operator; such checks are written as nested `if`s.

import validation

# The open sentinels `validation`'s builders use for an unset numeric bound (see
# `int_t`/`float_t`): a bound equal to the sentinel means "unconstrained" and is
# omitted from the emitted schema rather than written out as a spurious limit.
def _int_min_sentinel() -> int64:
    return -9223372036854775807

def _int_max_sentinel() -> int64:
    return 9223372036854775807

def _float_min_sentinel() -> float64:
    return -1.0e308

def _float_max_sentinel() -> float64:
    return 1.0e308

# Map a `validation.FieldType` (with its per-type constraints) to a JSON Schema
# fragment. Numeric bounds, string length/pattern and list length constraints are
# emitted only when set (an open sentinel is omitted). A nested `ModelT` recurses
# into a full object schema; a `ListT` emits `items` for its element type.
def of_field_type(validation.FieldType t) -> JsonValue:
    match t:
        case validation.FieldType.IntT(mn, mx):
            dict[str, JsonValue] o = {}
            o["type"] = JsonValue.Str("integer")
            if mn != _int_min_sentinel():
                o["minimum"] = JsonValue.Int(mn)
            if mx != _int_max_sentinel():
                o["maximum"] = JsonValue.Int(mx)
            return JsonValue.Object(o)
        case validation.FieldType.FloatT(mn, mx):
            dict[str, JsonValue] o = {}
            o["type"] = JsonValue.Str("number")
            if mn != _float_min_sentinel():
                o["minimum"] = JsonValue.Float(mn)
            if mx != _float_max_sentinel():
                o["maximum"] = JsonValue.Float(mx)
            return JsonValue.Object(o)
        case validation.FieldType.BoolT:
            dict[str, JsonValue] o = {}
            o["type"] = JsonValue.Str("boolean")
            return JsonValue.Object(o)
        case validation.FieldType.StrT(min_len, max_len, pat):
            dict[str, JsonValue] o = {}
            o["type"] = JsonValue.Str("string")
            if min_len > 0:
                o["minLength"] = JsonValue.Int(min_len)
            if max_len >= 0:
                o["maxLength"] = JsonValue.Int(max_len)
            if pat != "":
                o["pattern"] = JsonValue.Str(pat)
            return JsonValue.Object(o)
        case validation.FieldType.ModelT(sub):
            return of_schema(sub)
        case validation.FieldType.ListT(elem, min_len, max_len):
            dict[str, JsonValue] o = {}
            o["type"] = JsonValue.Str("array")
            o["items"] = of_field_type(elem)
            if min_len > 0:
                o["minItems"] = JsonValue.Int(min_len)
            if max_len >= 0:
                o["maxItems"] = JsonValue.Int(max_len)
            return JsonValue.Object(o)

# Map a whole `validation.Schema` to a JSON Schema object: `type: object`, a
# `title` from the schema name, a `properties` map, and a `required` list. A field
# counts as required only when it must be present in the INPUT — i.e. it is
# `required` AND has no default (a required field with a default is supplied when
# absent, so it is not required of the caller), matching the engine's own rule in
# `validation._validate_object`. An `extra == "forbid"` schema emits
# `additionalProperties: false`.
def of_schema(validation.Schema s) -> JsonValue:
    dict[str, JsonValue] props = {}
    list[JsonValue] required = []
    for f in s.fields:
        props[f.name] = of_field_type(f.ftype)
        if f.required:
            if f.has_default == False:
                required.append(JsonValue.Str(f.name))
    dict[str, JsonValue] o = {}
    o["type"] = JsonValue.Str("object")
    o["title"] = JsonValue.Str(s.name)
    o["properties"] = JsonValue.Object(props)
    if len(required) > 0:
        o["required"] = JsonValue.Array(required)
    if s.extra == "forbid":
        o["additionalProperties"] = JsonValue.Bool(False)
    return JsonValue.Object(o)

# Serialize a schema straight to a JSON Schema string (convenience for callers
# that want the text rather than the DOM).
def dumps_schema(validation.Schema s) -> str:
    return json.dumps(of_schema(s))
