# validation.pattern — a small, self-contained regular-expression matcher.
#
# Zap has no `regex` stdlib module (yet), so `validation` ships its own matcher
# for the string `pattern=` constraint. It is deliberately a *subset* of PCRE —
# enough to express the kinds of field patterns real schemas use (digits-only,
# zip codes, slugs, a pragmatic e-mail shape) without pulling in a full engine.
#
# This module is a LEAF: it imports nothing from the rest of `validation`, so it
# can be tested and reasoned about on its own. The public entry point is
# `fullmatch(pattern, s)`, which returns True iff the WHOLE string `s` is
# described by `pattern` (like Python's `re.fullmatch`). Full-string matching is
# the right default for validating a field value.
#
# Supported syntax (anything else is treated as a literal character):
#   .            any single character
#   literal      an ordinary character matches itself
#   [abc]        character class: any one of the listed characters
#   [a-z0-9]     ranges inside a class
#   [^...]       a negated class (any character NOT listed)
#   \d \w \s     digit / word (A-Za-z0-9_) / whitespace shorthands
#   \. \\ \[ ... a backslash escapes the next character to its literal self
#   X*           zero or more of the preceding atom (greedy)
#   X+           one or more
#   X?           zero or one
#   X{m}         exactly m
#   X{m,}        m or more
#   X{m,n}       between m and n (inclusive)
#   ^ ... $      optional leading `^` / trailing `$` anchors (matching is always
#                full-string, so they are accepted and ignored)
#
# NOT supported in v1 (documented limits): groups `( )`, alternation `|`,
# back-references, lookaround, and non-greedy quantifiers. These were left out
# to keep the matcher small and obviously-correct; they are natural follow-ups.
#
# NOTE: Zap's `and`/`or` do not short-circuit today (zaplang-io/zap: both
# operands are always evaluated). So this module never guards an index with a
# boolean operator — bounds checks are written as nested `if`s instead.

# One compiled unit of a pattern: a single-character matcher plus a quantifier.
# kind: 0 = literal codepoint, 1 = any (`.`), 2 = character class.
struct Atom:
    int64 kind
    int64 lit           # codepoint, for kind 0
    bool negate         # for kind 2: the class is negated
    list[int64] ranges  # for kind 2: flattened [lo, hi, lo, hi, ...] codepoint ranges
    int64 qmin          # quantifier lower bound
    int64 qmax          # quantifier upper bound, -1 = unbounded

# Codepoints of a string, as a list of int64 — so the matcher can index and
# backtrack over positions. len() on a str is byte length in Zap v1, so we count
# and collect codepoints explicitly to stay Unicode-correct.
def _codepoints(str s) -> list[int64]:
    list[int64] out = []
    for c in s:
        out.append(ord(c))
    return out

def _is_digit(int64 c) -> bool:
    return c >= 48 and c <= 57

# Append the codepoint ranges implied by an escape letter (\d \w \s); any other
# escaped character matches exactly its own codepoint.
def _escape_ranges(int64 letter, list[int64] ranges):
    if letter == 100:          # 'd'
        ranges.append(48)
        ranges.append(57)
    elif letter == 119:        # 'w'
        ranges.append(48)
        ranges.append(57)
        ranges.append(65)
        ranges.append(90)
        ranges.append(97)
        ranges.append(122)
        ranges.append(95)
        ranges.append(95)
    elif letter == 115:        # 's'
        ranges.append(9)
        ranges.append(13)
        ranges.append(32)
        ranges.append(32)
    else:
        ranges.append(letter)
        ranges.append(letter)

# Read a quantifier (if any) starting at index i; returns [qmin, qmax, next_i].
def _read_quantifier(list[int64] p, int64 i) -> list[int64]:
    if i >= len(p):
        return [1, 1, i]
    auto c = p[i]
    if c == 42:                # *
        return [0, -1, i + 1]
    if c == 43:                # +
        return [1, -1, i + 1]
    if c == 63:                # ?
        return [0, 1, i + 1]
    if c != 123:               # not a '{' — no quantifier
        return [1, 1, i]
    # Parse {m}, {m,} or {m,n}.
    auto j = i + 1
    auto m = 0
    auto saw_m = False
    auto go = True
    while go:
        if j >= len(p):
            go = False
        elif _is_digit(p[j]):
            m = m * 10 + (p[j] - 48)
            saw_m = True
            j = j + 1
        else:
            go = False
    auto lo = m
    auto hi = m
    auto has_comma = False
    if j < len(p):
        if p[j] == 44:         # comma
            has_comma = True
    if has_comma:
        j = j + 1
        auto has_n = False
        if j < len(p):
            if _is_digit(p[j]):
                has_n = True
        if has_n:
            auto nn = 0
            auto go2 = True
            while go2:
                if j >= len(p):
                    go2 = False
                elif _is_digit(p[j]):
                    nn = nn * 10 + (p[j] - 48)
                    j = j + 1
                else:
                    go2 = False
            hi = nn
        else:
            hi = -1             # {m,}
    # Require a closing '}'.
    auto closed = False
    if j < len(p):
        if p[j] == 125:
            closed = True
    if closed and saw_m:
        return [lo, hi, j + 1]
    # Malformed: treat the '{' as an ordinary literal (no quantifier here).
    return [1, 1, i]

# Compile a pattern string into a list of Atoms. Tolerant: unsupported or
# malformed constructs fall back to literal matching rather than failing.
def compile(str pattern) -> list[Atom]:
    auto p = _codepoints(pattern)
    list[Atom] atoms = []
    auto i = 0
    auto n = len(p)
    # Optional anchors: matching is full-string, so drop a leading ^ / trailing $.
    auto hi = n
    if i < hi:
        if p[i] == 94:         # ^
            i = i + 1
    if hi > i:
        if p[hi - 1] == 36:    # $
            hi = hi - 1
    while i < hi:
        auto c = p[i]
        auto kind = 0
        auto lit = 0
        auto negate = False
        list[int64] ranges = []
        if c == 46:               # .
            kind = 1
            i = i + 1
        elif c == 92:             # backslash escape
            kind = 2
            if i + 1 < hi:
                _escape_ranges(p[i + 1], ranges)
                i = i + 2
            else:
                # trailing backslash: match a literal backslash
                ranges.append(92)
                ranges.append(92)
                i = i + 1
        elif c == 91:             # [ class
            kind = 2
            i = i + 1
            if i < hi:
                if p[i] == 94:     # ^ negate
                    negate = True
                    i = i + 1
            auto scanning = True
            while scanning:
                if i >= hi:
                    scanning = False
                elif p[i] == 93:   # ]
                    scanning = False
                elif p[i] == 92:   # escape inside class
                    if i + 1 < hi:
                        _escape_ranges(p[i + 1], ranges)
                        i = i + 2
                    else:
                        ranges.append(92)
                        ranges.append(92)
                        i = i + 1
                else:
                    # Is this a `a-z` range? Need a '-' and a non-']' after it.
                    auto is_range = False
                    if i + 2 < hi:
                        if p[i + 1] == 45:
                            if p[i + 2] != 93:
                                is_range = True
                    if is_range:
                        ranges.append(p[i])
                        ranges.append(p[i + 2])
                        i = i + 3
                    else:
                        ranges.append(p[i])
                        ranges.append(p[i])
                        i = i + 1
            if i < hi:
                if p[i] == 93:
                    i = i + 1      # consume ]
        else:                     # ordinary literal
            kind = 0
            lit = c
            i = i + 1
        auto q = _read_quantifier(p, i)
        i = q[2]
        atoms.append(Atom(kind=kind, lit=lit, negate=negate, ranges=ranges, qmin=q[0], qmax=q[1]))
    return atoms

# Does a single codepoint `c` satisfy atom `a` (ignoring its quantifier)?
def _atom_matches(Atom a, int64 c) -> bool:
    if a.kind == 0:
        return c == a.lit
    if a.kind == 1:
        return True
    # kind 2: character class.
    auto inside = False
    auto j = 0
    while j + 1 < len(a.ranges):
        if c >= a.ranges[j]:
            if c <= a.ranges[j + 1]:
                inside = True
        j = j + 2
    if a.negate:
        return inside == False
    return inside

# Greedy backtracking match of atoms[ai..] against cps[si..]. Returns True iff
# the atoms consume exactly the remaining codepoints.
def _match_from(list[Atom] atoms, int64 ai, list[int64] cps, int64 si) -> bool:
    if ai >= len(atoms):
        return si >= len(cps)
    auto a = atoms[ai]
    # How many consecutive codepoints from si can this atom consume (up to qmax)?
    auto maxc = 0
    auto j = si
    auto go = True
    while go:
        if j >= len(cps):
            go = False
        elif _atom_matches(a, cps[j]) == False:
            go = False
        elif a.qmax >= 0 and maxc >= a.qmax:
            go = False
        else:
            maxc = maxc + 1
            j = j + 1
    # Try the greediest count first, backing off down to qmin.
    auto k = maxc
    while k >= a.qmin:
        if _match_from(atoms, ai + 1, cps, si + k):
            return True
        k = k - 1
    return False

# Public: does `s` match `pattern` in full?
def fullmatch(str pattern, str s) -> bool:
    auto atoms = compile(pattern)
    auto cps = _codepoints(s)
    return _match_from(atoms, 0, cps, 0)
