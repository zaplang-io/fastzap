# fastzap.wire — the HTTP/1.1 wire + URL helpers.
#
# A self-contained leaf module: it manipulates only strings, ints, lists and
# dicts (never a fastzap type), so it never imports back into `fastzap` and the
# import graph stays acyclic (Zap v1 rejects cycles, D-0081). It owns two jobs:
#
#   1. Splitting a raw request target ("/items/42?q=x&n=2") into its path and
#      query parts, decomposing the path into segments, and parsing the query
#      string into a dict (with `+` and %XX percent-decoding).
#   2. Serializing a response (status + content-type + body) into the response
#      bytes written back to the socket. The stdlib `http.respond` hard-codes
#      `text/plain` and gives no control over the content type or headers, so
#      fastzap writes its own response line via `net.send` instead, which lets a
#      JSON API send `application/json` (and any future custom headers).
#
# NOTE: Zap's `and`/`or` do not short-circuit today (both operands are always
# evaluated, zaplang-io/zap), so this module never guards an index/lookup with a
# boolean operator; such checks are written as nested `if`s. URL decoding treats
# each %XX as a single codepoint, which is exact for ASCII targets (the common
# case); full multi-byte percent-decoding is a documented follow-up.

# The reason phrase for a status code (a small common set; "OK" otherwise, which
# is a valid HTTP/1.1 reason-phrase — clients key off the numeric code).
def reason(int64 status) -> str:
    if status == 200:
        return "OK"
    if status == 201:
        return "Created"
    if status == 202:
        return "Accepted"
    if status == 204:
        return "No Content"
    if status == 400:
        return "Bad Request"
    if status == 401:
        return "Unauthorized"
    if status == 403:
        return "Forbidden"
    if status == 404:
        return "Not Found"
    if status == 405:
        return "Method Not Allowed"
    if status == 409:
        return "Conflict"
    if status == 422:
        return "Unprocessable Entity"
    if status == 500:
        return "Internal Server Error"
    if status == 503:
        return "Service Unavailable"
    return "OK"

# Build a complete HTTP/1.1 response: status line, Content-Type, byte-accurate
# Content-Length, Connection: close (fastzap serves one request per connection in
# v1), then the body. Returned as a single string to hand to `net.send`.
def build_response(int64 status, str content_type, str body) -> str:
    auto line = "HTTP/1.1 " + str(status) + " " + reason(status) + "\r\n"
    auto ct = "Content-Type: " + content_type + "\r\n"
    auto cl = "Content-Length: " + str(len(body)) + "\r\n"
    return line + ct + cl + "Connection: close\r\n\r\n" + body

# The path portion of a request target, i.e. everything before the first '?'.
def target_path(str target) -> str:
    auto q = target.find("?")
    if q < 0:
        return target
    return target[0:q]

# The query portion of a request target, i.e. everything after the first '?'
# ("" when there is no query).
def target_query(str target) -> str:
    auto q = target.find("?")
    if q < 0:
        return ""
    return target[q + 1:len(target)]

# Decompose a path into its non-empty segments: "/items/42/" -> ["items", "42"].
# The root path "/" yields the empty list.
def path_segments(str path) -> list[str]:
    list[str] out = []
    auto parts = path.split("/")
    auto i = 0
    while i < len(parts):
        auto p = parts[i]
        if len(p) > 0:
            out.append(p)
        i = i + 1
    return out

# Value of a single hex digit, or -1 if it is not one. ASCII codepoints are used
# directly ('0'=48, 'a'=97, 'A'=65); Zap has no char literal, and `ord` takes a
# char, so a string literal cannot be passed to it.
def _hexval(str c) -> int64:
    if c >= "0":
        if c <= "9":
            return ord(c[0]) - 48
    if c >= "a":
        if c <= "f":
            return ord(c[0]) - 97 + 10
    if c >= "A":
        if c <= "F":
            return ord(c[0]) - 65 + 10
    return -1

# Percent/plus-decode one query token. "+" becomes space; "%XX" becomes the byte
# XX (one codepoint, exact for ASCII); a malformed "%" is passed through as-is.
def url_decode(str s) -> str:
    auto out = ""
    auto i = 0
    auto n = len(s)
    while i < n:
        auto c = s[i:i + 1]
        if c == "+":
            out = out + " "
            i = i + 1
        else:
            if c == "%":
                auto ok = False
                if i + 2 < n:
                    auto hi = _hexval(s[i + 1:i + 2])
                    auto lo = _hexval(s[i + 2:i + 3])
                    if hi >= 0:
                        if lo >= 0:
                            out = out + str(chr(hi * 16 + lo))
                            i = i + 3
                            ok = True
                if ok == False:
                    out = out + c
                    i = i + 1
            else:
                out = out + c
                i = i + 1
    return out

# Parse a query string ("a=1&b=two&flag") into a dict. A key with no '=' maps to
# "" (a present-but-empty flag); on a repeated key the last value wins. Keys and
# values are URL-decoded.
def parse_query(str raw) -> dict[str, str]:
    dict[str, str] out = {}
    if len(raw) == 0:
        return out
    auto pairs = raw.split("&")
    auto i = 0
    while i < len(pairs):
        auto pair = pairs[i]
        if len(pair) > 0:
            auto eq = pair.find("=")
            if eq < 0:
                out[url_decode(pair)] = ""
            else:
                auto k = pair[0:eq]
                auto v = pair[eq + 1:len(pair)]
                out[url_decode(k)] = url_decode(v)
        i = i + 1
    return out
