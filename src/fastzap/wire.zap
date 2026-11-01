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

# The HTTP/1.1 status line, "HTTP/1.1 <status> <reason>\r\n".
def status_line(int64 status) -> str:
    return "HTTP/1.1 " + str(status) + " " + reason(status) + "\r\n"

# The `Connection` header token for a response: "keep-alive" when the connection
# is being reused for the next request (fastzap#6), "close" when it ends after
# this response.
def _conn_token(bool keep_alive) -> str:
    if keep_alive:
        return "keep-alive"
    return "close"

# Serialize any extra response headers (fastzap#2 middleware sets these —
# `X-Request-Id`, `Access-Control-Allow-*`) as `Name: value\r\n` lines. Header map
# iteration order is unspecified, which is fine — HTTP header order is not
# significant. The framework's own Content-Type/Content-Length/Connection (and
# Transfer-Encoding for a streamed body) are emitted separately, never from here.
def _extra_headers(dict[str, str] headers) -> str:
    auto extra = ""
    for name in headers:
        extra = extra + name + ": " + headers[name] + "\r\n"
    return extra

# Build a complete buffered HTTP/1.1 response: status line, Content-Type,
# byte-accurate Content-Length, any extra headers, the `Connection` token, then
# the body. Returned as a single string to hand to `net.send`.
def _buffered(
    int64 status,
    str content_type,
    str body,
    dict[str, str] headers,
    str conn_token,
) -> str:
    auto ct = "Content-Type: " + content_type + "\r\n"
    auto cl = "Content-Length: " + str(len(body)) + "\r\n"
    auto conn = "Connection: " + conn_token + "\r\n"
    return status_line(status) + ct + cl + _extra_headers(headers) + conn + "\r\n" + body

# A buffered response that CLOSES the connection after it (the bare form used by
# the error backstops and by callers that do not negotiate keep-alive).
def build_response(int64 status, str content_type, str body) -> str:
    dict[str, str] none = {}
    return _buffered(status, content_type, body, none, "close")

# As `build_response`, plus any extra response headers; still `Connection: close`.
# Kept so the middleware-era signature and the existing wire golden are unchanged.
def build_response_with(
    int64 status,
    str content_type,
    str body,
    dict[str, str] headers,
) -> str:
    return _buffered(status, content_type, body, headers, "close")

# A buffered response whose `Connection` header reflects the negotiated keep-alive
# decision (fastzap#6): `keep-alive` to reuse the connection for the next request,
# `close` to end it. The server picks `keep_alive` from the request's `Connection`
# header and the lifecycle (see `fastzap.connection_keep_alive`).
def build_response_keepalive(
    int64 status,
    str content_type,
    str body,
    dict[str, str] headers,
    bool keep_alive,
) -> str:
    return _buffered(status, content_type, body, headers, _conn_token(keep_alive))

# ---------------------------------------------------------------------------
# Chunked transfer-encoding (fastzap#6)
# ---------------------------------------------------------------------------
#
# A streamed response omits Content-Length and frames its body as a series of
# chunks: each is its byte length in lowercase hex, CRLF, the bytes, CRLF; a final
# zero-length chunk ("0\r\n\r\n") terminates the body. The server writes the head
# once, pumps the handler's producer through `chunk_encode` per chunk, then writes
# `chunk_final`. `dechunk` is the inverse (used by tests to assert a client
# reassembles the exact body).

# The header block for a chunked response: status line, Content-Type,
# `Transfer-Encoding: chunked` (NO Content-Length — the two are mutually
# exclusive), any extra headers, the `Connection` token, and the blank line. The
# body follows as chunks written separately.
def build_chunked_head(
    int64 status,
    str content_type,
    dict[str, str] headers,
    bool keep_alive,
) -> str:
    auto ct = "Content-Type: " + content_type + "\r\n"
    auto te = "Transfer-Encoding: chunked\r\n"
    auto conn = "Connection: " + _conn_token(keep_alive) + "\r\n"
    return status_line(status) + ct + te + _extra_headers(headers) + conn + "\r\n"

# One wire chunk: "<hex-length>\r\n<bytes>\r\n". The caller must not pass an empty
# chunk — a zero-length chunk is the terminator, so emitting one early would end
# the body prematurely (StreamWriter.write drops empty chunks for this reason).
def chunk_encode(str chunk) -> str:
    return hex_len(len(chunk)) + "\r\n" + chunk + "\r\n"

# The terminating zero-length chunk that ends a chunked body.
def chunk_final() -> str:
    return "0\r\n\r\n"

# A non-negative length as lowercase hexadecimal (chunk sizes are hex per the
# HTTP/1.1 grammar). `0` renders as "0"; integer floor-division (`//`) and `%`
# keep the result exact for any `int64` length.
def hex_len(int64 n) -> str:
    if n <= 0:
        return "0"
    auto digits = "0123456789abcdef"
    auto out = ""
    auto v = n
    while v > 0:
        auto d = v % 16
        out = digits[d:d + 1] + out
        v = v // 16
    return out

# Decode a chunked body back to its payload (the inverse of `chunk_encode` +
# `chunk_final`): read each "<hex>\r\n<bytes>\r\n" chunk, concatenating the bytes,
# until the zero-length chunk. Lets a test assert the exact body a client
# reassembles without a socket. Returns the payload; a malformed stream stops at
# the first bad length.
def dechunk(str body) -> str:
    auto out = ""
    auto i = 0
    auto n = len(body)
    auto going = True
    while going:
        if i >= n:
            going = False
        else:
            auto nl = _find_from(body, "\r\n", i)
            if nl < 0:
                going = False
            else:
                auto size = _parse_hex(body[i:nl])
                if size <= 0:
                    going = False
                else:
                    auto start = nl + 2
                    out = out + body[start:start + size]
                    i = start + size + 2
    return out

# Index of `needle` in `s` at or after `from_i`, or -1. (`str.find` has no start
# offset, so this slices from `from_i` and re-bases the hit.)
def _find_from(str s, str needle, int64 from_i) -> int64:
    auto rel = s[from_i:len(s)].find(needle)
    if rel < 0:
        return -1
    return from_i + rel

# Parse a lowercase/uppercase hex string to an int (0 on an empty or bad digit).
def _parse_hex(str s) -> int64:
    auto v = 0
    auto i = 0
    auto n = len(s)
    while i < n:
        auto d = _hexval(s[i:i + 1])
        if d < 0:
            return 0
        v = v * 16 + d
        i = i + 1
    return v

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
