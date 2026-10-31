# Staged graceful-shutdown test (zaplang-io/zap#312 acceptance criterion).
#
# Drives the REAL signal path end to end: `signal.notify(SIGTERM)` takes over the
# signal, a watcher coroutine parked on the channel receives it and runs
# fastzap's staged drain, and we assert the observable state transitions. It is
# made deterministic exactly like the compiler's own signal goldens:
#   * `__raise_signal(15)` sends SIGTERM to the process;
#   * `__signal_drain()` blocks until the signal thread has delivered it;
#   * the watcher is an OWNED spawn, so the `scope:` join barrier does not pass
#     the dedent until the watcher has finished the staged drain — the state is
#     therefore fully settled before the assertions run.
# The propagation window is set to 0 so there is no real sleep, and the grace
# budget is set large so the backstop timer never fires during the test (the
# process exits cleanly when main returns). No client/socket round-trip is
# needed: this isolates the signal→drain→state-transition contract. The live
# accept/serve/drain loop is exercised by examples/quickstart.zap under CI.

import fastzap

def check(str label, bool cond):
    if cond:
        print("ok " + label)
    else:
        print("FAIL " + label)

# Mirror of fastzap's internal watcher, using only the public API: wait for the
# signal, then run the staged drain against the listener.
def watch(fastzap.App app, bytes listener, channel[Signal] ch):
    auto _sig = <-ch
    fastzap.begin_shutdown(app, listener)

def main():
    auto app = fastzap.app()
    # propagation 0 (no sleep), large grace (backstop never fires in-test).
    app.configure_shutdown(fastzap.shutdown_config(0, 600000, "/healthz"))
    auto listener = net.listen("127.0.0.1", 0)

    # Preconditions: a fresh server is ready and running.
    check("initially ready", app.state.ready == True)
    check("initially running", fastzap.stage_of(app) == "running")
    check("not yet triggered", app.state.triggered == False)

    auto term = signal.notify(Signal.SIGTERM)
    scope:
        spawn watch(app, listener, term)
        __raise_signal(15)
        __signal_drain()
    # Dedent: the watcher received SIGTERM and completed the staged drain.

    # Postconditions: readiness flipped (so k8s stops routing), the one-shot
    # latch fired, and the lifecycle advanced past accepting.
    check("readiness flipped unready", app.state.ready == False)
    check("shutdown latched", app.state.triggered == True)
    check("stopped accepting", fastzap.stage_of(app) == "stopping")

    print("all tests passed")
