# Offline test driver for HTTP/1.1 keep-alive + chunked/streaming bodies
# (fastzap#6, DECISIONS.md D-FZ-0014). Everything here is deterministic and needs
# NO socket: the keep-alive DECISION is a pure function, the buffered/chunked wire
# framing are pure string builders, and the incremental streaming producer is
# pumped through a `StreamWriter` whose sink COLLECTS chunks into a list (the
# server's sink sends them on the connection — same `fn(str) -> int64` seam). The
# live socket keep-alive loop and the staged drain are exercised by CI (the
# toolchain image) and the example; see DESIGN.md "Testing".
#
# Proven here:
#   * keep-alive negotiation — default keep-alive, explicit keep-alive, honoring
#     `Connection: close` (case-insensitively), and shutdown forcing close;
#   * buffered framing — a correct status line + byte-accurate Content-Length +
#     the negotiated `Connection` token, and NO Transfer-Encoding;
#   * chunked framing — hex chunk sizes (incl. multi-digit), a single chunk's
#     exact bytes, the terminating `0\r\n\r\n`, a chunked head that carries
#     `Transfer-Encoding: chunked` and OMITS Content-Length;
#   * reassembly — `dechunk` reconstructs the exact body a client would, so an
#     encode→decode round-trip returns the original payload;
#   * the streaming Response SHAPE — a handler returns `streaming_response`, the
#     uniform `fn(Request) -> Response` contract is unchanged, and pumping its
#     producer yields the expected chunks (an empty chunk is dropped) which
#     reassemble into the full body; a buffered response is not streaming.
#
# Each check prints a stable `ok <label>` token; tools/run-tests.sh diffs stdout
# against tests/keepalive_test.expected.

import fastzap
import fastzap.wire

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

# --- a streaming producer + a collecting sink (no socket) ------------------

# Write a few body pieces, including an EMPTY one (which StreamWriter drops — a
# zero-length chunk is the terminator). Returns the chunk count (advisory).
def _stream_body(fastzap.StreamWriter w) -> int64:
    w.write("alpha")
    w.write("")
    w.write("beta")
    w.write("gamma")
    return 3

def h_stream(fastzap.Request req) -> fastzap.Response:
    return fastzap.streaming_response(200, "text/plain; charset=utf-8", _stream_body)

# A sink that collects each (non-empty) chunk into `acc` instead of sending it.
def _collect(list[str] acc, str c) -> int64:
    acc.append(c)
    return len(c)

def main():
    # --- keep-alive decision (pure) ----------------------------------------
    check("ka default", fastzap.connection_keep_alive("", False) == True)
    check("ka explicit", fastzap.connection_keep_alive("keep-alive", False) == True)
    check("ka close honored", fastzap.connection_keep_alive("close", False) == False)
    check("ka close ci", fastzap.connection_keep_alive("Close", False) == False)
    check(
        "ka shutdown closes",
        fastzap.connection_keep_alive("keep-alive", True) == False,
    )

    # --- buffered framing ---------------------------------------------------
    dict[str, str] none = {}
    auto bk = wire.build_response_keepalive(
        200,
        "application/json",
        "{\"ok\":true}",
        none,
        True,
    )
    check("buffered status line", bk.startswith("HTTP/1.1 200 OK\r\n"))
    check("buffered content-length", bk.contains("Content-Length: 11\r\n"))
    check("buffered keepalive token", bk.contains("Connection: keep-alive\r\n"))
    check("buffered no chunked", bk.contains("Transfer-Encoding") == False)
    check("buffered body after blank", bk.endswith("\r\n\r\n{\"ok\":true}"))
    auto bc = wire.build_response_keepalive(200, "application/json", "x", none, False)
    check("buffered close token", bc.contains("Connection: close\r\n"))
    auto bare = wire.build_response(200, "application/json", "x")
    check("build_response closes", bare.contains("Connection: close\r\n"))

    # --- chunked framing ----------------------------------------------------
    check("hex 0", wire.hex_len(0) == "0")
    check("hex 5", wire.hex_len(5) == "5")
    check("hex 16", wire.hex_len(16) == "10")
    check("hex 255", wire.hex_len(255) == "ff")
    check("hex 4096", wire.hex_len(4096) == "1000")
    check("chunk encode", wire.chunk_encode("hello") == "5\r\nhello\r\n")
    check("chunk final", wire.chunk_final() == "0\r\n\r\n")
    auto head = wire.build_chunked_head(200, "text/plain; charset=utf-8", none, True)
    check("chunked transfer-encoding", head.contains("Transfer-Encoding: chunked\r\n"))
    check("chunked no content-length", head.contains("Content-Length") == False)
    check("chunked keepalive token", head.contains("Connection: keep-alive\r\n"))
    check("chunked head ends blank", head.endswith("\r\n\r\n"))

    # --- reassembly (dechunk is the inverse of encode) ---------------------
    auto enc = wire.chunk_encode("ab") + wire.chunk_encode("cde") + wire.chunk_final()
    check("dechunk round trip", wire.dechunk(enc) == "abcde")
    auto big = "0123456789abcdefghij"
    auto enc2 = wire.chunk_encode(big) + wire.chunk_final()
    check("dechunk multi-hex", wire.dechunk(enc2) == big)

    # --- the streaming Response shape, through dispatch --------------------
    auto app = fastzap.app()
    app.get("/stream", h_stream)
    auto resp = fastzap.dispatch(app, fastzap.request("GET", "/stream", ""))
    check("stream flagged", resp.streaming == True)
    check("stream status", resp.status == 200)
    check("stream content-type", resp.content_type == "text/plain; charset=utf-8")
    check("stream empty buffered body", resp.body == "")

    # Pump the producer through a COLLECTING writer (no socket): the empty write
    # is dropped, so three chunks are collected, and encoding+dechunking them
    # reconstructs exactly the body a client reassembles.
    list[str] got = []
    fn(str) -> int64 emit = lambda c: _collect(got, c)
    auto w = fastzap.StreamWriter(emit)
    fn(fastzap.StreamWriter) -> int64 p = resp.produce
    auto _n = p(w)
    check("stream chunk count", len(got) == 3)
    check("stream chunk 0", got[0] == "alpha")
    check("stream chunk 1", got[1] == "beta")
    check("stream chunk 2", got[2] == "gamma")
    auto wire_body = ""
    for c in got:
        wire_body = wire_body + wire.chunk_encode(c)
    wire_body = wire_body + wire.chunk_final()
    check("stream client reassembles", wire.dechunk(wire_body) == "alphabetagamma")

    # --- a buffered response is not streaming ------------------------------
    check("buffered not streaming", fastzap.json_response(200, "x").streaming == False)
    auto st = fastzap.streaming_text(200, _stream_body)
    check("streaming_text flagged", st.streaming == True)
    check("streaming_text content-type", st.content_type == "text/plain; charset=utf-8")

    print("all tests passed")
