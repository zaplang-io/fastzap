# validation — a pydantic-style runtime data-validation and typed-model library
# for Zap.
#
# The shape of a model is described declaratively as a `Schema` built from field
# specifications; validation runs a native engine over parsed JSON (the stdlib
# `JsonValue` DOM) and either returns a validated `Model` or the full list of
# `ValErr`s found — never just the first. See DESIGN.md for why v1 is schema-
# driven (Zap has no field-level reflection or code-generating decorator yet) and
# how an annotation-driven `@model` surface would layer on top later.
#
# Quick taste:
#   auto User = validation.model("User", [
#       validation.field("name", validation.str_t(min_len=1, max_len=50)),
#       validation.field("age",  validation.int_t(min=0, max=130)),
#       validation.field("email", validation.str_t(pattern="[^@ ]+@[^@ ]+\\.[a-z]{2,}")),
#       validation.field("nickname", validation.str_t(), required=False),
#   ])
#   match validation.validate(User, json.loads(input)):
#       case validation.ValidationResult.Ok(m):
#           print(m.get_str("name"))   # validated, typed access
#       case validation.ValidationResult.Err(errs):
#           for e in errs:
#               print(e.loc + ": " + e.msg)
#
# NOTE: Zap's `and`/`or` do not short-circuit today (both operands are always
# evaluated, zaplang-io/zap), so this module never guards an index/lookup with a
# boolean operator; such checks are written as nested `if`s.

import validation.pattern

# ---------------------------------------------------------------------------
# Core types
# ---------------------------------------------------------------------------

# The type (and per-type constraints) of a field. Numeric bounds and length /
# pattern constraints live on the type itself, so `field()` only ever carries
# the cross-cutting concerns (required / default). Recursive: ModelT nests a
# whole Schema, ListT nests the element's FieldType.
#
# Unset bounds use open sentinels (a min of INT_MIN / a max of INT_MAX always
# passes), so no Optional is needed — which also sidesteps the current inability
# to default an Optional parameter to None.
enum FieldType:
    IntT(int64 min, int64 max)
    FloatT(float64 min, float64 max)
    BoolT
    StrT(int64 min_len, int64 max_len, str pattern)
    ModelT(Schema schema)
    ListT(FieldType elem, int64 min_len, int64 max_len)

# One field of a model: its name, its type/constraints, whether it must be
# present, and an optional default used when it is absent.
struct Field:
    str name
    FieldType ftype
    bool required
    bool has_default
    JsonValue default

# A model schema: a named, ordered collection of fields, plus an extra-field
# policy ("ignore" | "forbid" | "allow", default "ignore" — matching pydantic's
# default of silently dropping unknown keys).
struct Schema:
    str name
    list[Field] fields
    str extra

# A single validation failure, with a dotted/bracketed location path
# ("address.zip", "tags[2]"), a short machine-readable `kind`, and a human
# message.
struct ValErr:
    str loc
    str kind
    str msg

# A validated model instance: the normalized data as a JSON object (dict), with
# typed accessors. A Model is only ever handed back on success, so its accessors
# assume the data matches the schema.
struct Model:
    str name
    dict[str, JsonValue] data

    def has(self, str key) -> bool:
        return key in self.data

    def get_int(self, str key) -> int64:
        if key in self.data:
            match self.data[key]:
                case JsonValue.Int(i):
                    return i
                case _:
                    return 0
        return 0

    def get_float(self, str key) -> float64:
        if key in self.data:
            match self.data[key]:
                case JsonValue.Float(f):
                    return f
                case JsonValue.Int(i):
                    return float(i)
                case _:
                    return 0.0
        return 0.0

    def get_bool(self, str key) -> bool:
        if key in self.data:
            match self.data[key]:
                case JsonValue.Bool(b):
                    return b
                case _:
                    return False
        return False

    def get_str(self, str key) -> str:
        if key in self.data:
            match self.data[key]:
                case JsonValue.Str(s):
                    return s
                case _:
                    return ""
        return ""

    # A nested model value, as a Model (its data is the nested object).
    def get_model(self, str key) -> Model:
        if key in self.data:
            match self.data[key]:
                case JsonValue.Object(m):
                    return Model(name=key, data=m)
                case _:
                    return _empty_model(key)
        return _empty_model(key)

    # The raw JSON items of a list field.
    def get_list(self, str key) -> list[JsonValue]:
        list[JsonValue] empty = []
        if key in self.data:
            match self.data[key]:
                case JsonValue.Array(items):
                    return items
                case _:
                    return empty
        return empty

    # A list-of-models field, as Models (each item's object wrapped).
    def get_models(self, str key) -> list[Model]:
        list[Model] out = []
        for item in self.get_list(key):
            match item:
                case JsonValue.Object(m):
                    out.append(Model(name=key, data=m))
                case _:
                    out.append(_empty_model(key))
        return out

    # The validated data as a JSON value (round-trips through json.dumps).
    def to_json(self) -> JsonValue:
        return JsonValue.Object(self.data)

    # The validated data as a compact JSON string.
    def dumps(self) -> str:
        return json.dumps(JsonValue.Object(self.data))

def _empty_model(str name) -> Model:
    dict[str, JsonValue] d = {}
    return Model(name=name, data=d)

# The outcome of validating input against a schema: either a validated Model or
# the complete list of failures.
enum ValidationResult:
    Ok(Model model)
    Err(list[ValErr] errors)

    def is_ok(self) -> bool:
        match self:
            case ValidationResult.Ok(m):
                return True
            case ValidationResult.Err(e):
                return False

# ---------------------------------------------------------------------------
# Builders (free functions, so default/keyword arguments work — zaplang-io/zap
# #298: methods still take positional-only args, free functions do not)
# ---------------------------------------------------------------------------

# An integer field, optionally bounded by [min, max] (inclusive). The defaults
# are open sentinels (int64 min/max), so an unset bound never rejects anything.
def int_t(int64 min = -9223372036854775807, int64 max = 9223372036854775807) -> FieldType:
    return FieldType.IntT(min, max)

# A floating-point field, optionally bounded by [min, max] (inclusive). A JSON
# integer is accepted and widened to float.
def float_t(float64 min = -1.0e308, float64 max = 1.0e308) -> FieldType:
    return FieldType.FloatT(min, max)

# A boolean field.
def bool_t() -> FieldType:
    return FieldType.BoolT

# A string field, optionally constrained by codepoint length and/or a pattern
# (see validation.pattern for the supported regex subset). min_len default 0 and
# max_len default -1 (unbounded); an empty pattern means "no pattern".
def str_t(int64 min_len = 0, int64 max_len = -1, str pattern = "") -> FieldType:
    return FieldType.StrT(min_len, max_len, pattern)

# A nested-model field, validated against `schema`.
def model_t(Schema schema) -> FieldType:
    return FieldType.ModelT(schema)

# A list field whose elements all have type `elem`, optionally length-bounded.
def list_t(FieldType elem, int64 min_len = 0, int64 max_len = -1) -> FieldType:
    return FieldType.ListT(elem, min_len, max_len)

# Declare one field. `required` defaults to True; pass required=False for an
# optional field. A default (used when the field is absent) is given with
# has_default=True, default=<JsonValue>.
def field(str name, FieldType ftype, bool required = True, bool has_default = False, JsonValue default = JsonValue.Null) -> Field:
    return Field(name=name, ftype=ftype, required=required, has_default=has_default, default=default)

# Declare a model schema from a list of fields. `extra` controls unknown input
# keys: "ignore" (drop them, the default), "forbid" (report each), "allow"
# (copy them through unvalidated).
def model(str name, list[Field] fields, str extra = "ignore") -> Schema:
    return Schema(name=name, fields=fields, extra=extra)

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

# In-place insertion sort of a string list (for deterministic extra-key order).
def _sort_str(list[str] xs):
    auto i = 1
    while i < len(xs):
        auto key = xs[i]
        auto j = i - 1
        auto go = True
        while go:
            if j < 0:
                go = False
            elif xs[j] <= key:
                go = False
            else:
                xs[j + 1] = xs[j]
                j = j - 1
        xs[j + 1] = key
        i = i + 1

def _join(str base, str name) -> str:
    if base == "":
        return name
    return base + "." + name

# A human-readable name for a JSON value's type, for "expected X, got Y".
def _type_name(JsonValue v) -> str:
    match v:
        case JsonValue.Null:
            return "null"
        case JsonValue.Bool(b):
            return "boolean"
        case JsonValue.Int(i):
            return "integer"
        case JsonValue.Float(f):
            return "number"
        case JsonValue.Str(s):
            return "string"
        case JsonValue.Array(items):
            return "array"
        case JsonValue.Object(fields):
            return "object"

def _err(list[ValErr] errs, str loc, str kind, str msg):
    errs.append(ValErr(loc=loc, kind=kind, msg=msg))

# Codepoint length of a string (len() is byte length in Zap v1).
def _cp_len(str s) -> int64:
    auto n = 0
    for c in s:
        n = n + 1
    return n

# Validate one value against a FieldType, appending any failures (there may be
# several, e.g. a bad list element plus a length violation). Returns the
# normalized JSON value (meaningful only when no error was recorded for it).
def _validate_ftype(FieldType t, JsonValue raw, str loc, list[ValErr] errs) -> JsonValue:
    match t:
        case FieldType.IntT(mn, mx):
            match raw:
                case JsonValue.Int(i):
                    if i < mn:
                        _err(errs, loc, "too_small", "value " + str(i) + " is less than minimum " + str(mn))
                    if i > mx:
                        _err(errs, loc, "too_large", "value " + str(i) + " is greater than maximum " + str(mx))
                    return JsonValue.Int(i)
                case _:
                    _err(errs, loc, "type", "expected integer, got " + _type_name(raw))
                    return raw
        case FieldType.FloatT(mn, mx):
            match raw:
                case JsonValue.Float(f):
                    return _check_float(f, mn, mx, loc, errs)
                case JsonValue.Int(i):
                    return _check_float(float(i), mn, mx, loc, errs)
                case _:
                    _err(errs, loc, "type", "expected number, got " + _type_name(raw))
                    return raw
        case FieldType.BoolT:
            match raw:
                case JsonValue.Bool(b):
                    return JsonValue.Bool(b)
                case _:
                    _err(errs, loc, "type", "expected boolean, got " + _type_name(raw))
                    return raw
        case FieldType.StrT(min_len, max_len, pat):
            match raw:
                case JsonValue.Str(s):
                    auto n = _cp_len(s)
                    if n < min_len:
                        _err(errs, loc, "too_short", "string length " + str(n) + " is less than minimum " + str(min_len))
                    if max_len >= 0:
                        if n > max_len:
                            _err(errs, loc, "too_long", "string length " + str(n) + " is greater than maximum " + str(max_len))
                    if pat != "":
                        if pattern.fullmatch(pat, s) == False:
                            _err(errs, loc, "pattern", "string does not match pattern " + pat)
                    return JsonValue.Str(s)
                case _:
                    _err(errs, loc, "type", "expected string, got " + _type_name(raw))
                    return raw
        case FieldType.ModelT(sub):
            return JsonValue.Object(_validate_object(sub, raw, loc, errs))
        case FieldType.ListT(elem, min_len, max_len):
            match raw:
                case JsonValue.Array(items):
                    auto n = len(items)
                    if n < min_len:
                        _err(errs, loc, "too_short", "list length " + str(n) + " is less than minimum " + str(min_len))
                    if max_len >= 0:
                        if n > max_len:
                            _err(errs, loc, "too_long", "list length " + str(n) + " is greater than maximum " + str(max_len))
                    list[JsonValue] out = []
                    auto idx = 0
                    for it in items:
                        out.append(_validate_ftype(elem, it, loc + "[" + str(idx) + "]", errs))
                        idx = idx + 1
                    return JsonValue.Array(out)
                case _:
                    _err(errs, loc, "type", "expected array, got " + _type_name(raw))
                    return raw

def _check_float(float64 f, float64 mn, float64 mx, str loc, list[ValErr] errs) -> JsonValue:
    if f < mn:
        _err(errs, loc, "too_small", "value " + str(f) + " is less than minimum " + str(mn))
    if f > mx:
        _err(errs, loc, "too_large", "value " + str(f) + " is greater than maximum " + str(mx))
    return JsonValue.Float(f)

# Validate a JSON object against a schema. Collects all field errors; returns the
# normalized object as a dict.
def _validate_object(Schema s, JsonValue raw, str base, list[ValErr] errs) -> dict[str, JsonValue]:
    dict[str, JsonValue] out = {}
    match raw:
        case JsonValue.Object(fields):
            # Track known names for extra-field handling.
            dict[str, bool] known = {}
            for f in s.fields:
                known[f.name] = True
                auto loc = _join(base, f.name)
                if f.name in fields:
                    out[f.name] = _validate_ftype(f.ftype, fields[f.name], loc, errs)
                else:
                    if f.required:
                        if f.has_default:
                            out[f.name] = f.default
                        else:
                            _err(errs, loc, "missing", "field required")
                    else:
                        if f.has_default:
                            out[f.name] = f.default
            # Extra-field policy. Input dict iteration order is unspecified, so
            # collect and sort extra keys first for deterministic error output.
            if s.extra != "ignore":
                list[str] extras = []
                for k in fields:
                    auto is_known = k in known
                    if is_known == False:
                        extras.append(k)
                _sort_str(extras)
                for k in extras:
                    if s.extra == "forbid":
                        _err(errs, _join(base, k), "extra_forbidden", "unexpected field")
                    else:
                        out[k] = fields[k]
            return out
        case _:
            _err(errs, base, "type", "expected object, got " + _type_name(raw))
            return out

# Validate `input` (a parsed JsonValue) against `schema`, collecting every error.
# On success returns Ok(Model); otherwise Err(list[ValErr]).
def validate(Schema schema, JsonValue input) -> ValidationResult:
    list[ValErr] errs = []
    auto data = _validate_object(schema, input, "", errs)
    if len(errs) == 0:
        return ValidationResult.Ok(Model(name=schema.name, data=data))
    return ValidationResult.Err(errs)

# Convenience: parse a JSON string and validate it in one step.
def validate_json(Schema schema, str text) -> ValidationResult:
    return validate(schema, json.loads(text))

# Render a list of errors as one line each ("loc: msg [kind]"), newline-joined —
# handy for printing or logging.
def errors_str(list[ValErr] errs) -> str:
    list[str] lines = []
    for e in errs:
        auto where = e.loc
        if where == "":
            where = "(root)"
        lines.append(where + ": " + e.msg + " [" + e.kind + "]")
    return "\n".join(lines)
