# Example container image for a fastzap server, wired for zero-downtime rolling
# deploys. The point of this file is the SHUTDOWN SIGNAL PATH, not the build
# details: the server must be PID 1 (or behind a real init) so SIGTERM reaches it
# and fastzap's staged drain runs — see the README "Deploying for zero-downtime".
#
# ---- build stage: compile the example through the Zap toolchain image --------
FROM ghcr.io/zaplang-io/zap:latest AS build
WORKDIR /src
COPY . .
# Assemble a flat build root (fastzap modules + the vendored validation
# dependency + the example) and compile+link it, exactly as tools/build-examples.sh
# does, producing a self-contained binary at /src/build/example-quickstart/quickstart.
RUN sh tools/build-examples.sh

# ---- runtime stage -----------------------------------------------------------
FROM debian:bookworm-slim
# `tini` is an init that is PID 1, reaps zombies, and FORWARDS SIGTERM to the
# child. Equivalently, make the server itself PID 1 with an exec-form ENTRYPOINT
# and no shell wrapper; what must NOT happen is a shell (sh -c "...") as PID 1,
# which would not forward SIGTERM — the kernel ignores an unhandled SIGTERM to
# PID 1, so the process would survive until the SIGKILL at the end of
# terminationGracePeriodSeconds and drop every in-flight request.
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/example-quickstart/quickstart /usr/local/bin/api
EXPOSE 8000

# Exec form (JSON array) — NOT the shell form — so `api` is the direct child of
# tini and receives the forwarded SIGTERM.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/api"]

# Kubernetes pod spec (sketch) to pair with this image:
#
#   spec:
#     terminationGracePeriodSeconds: 30     # > propagation_ms + grace_ms (3s+20s)
#     containers:
#       - name: api
#         image: your-registry/fastzap-example:latest
#         ports: [{ containerPort: 8000 }]
#         readinessProbe:
#           httpGet: { path: /healthz, port: 8000 }
#           periodSeconds: 2
#
# On a rolling update k8s sends SIGTERM; fastzap flips /healthz to 503 (the probe
# removes the pod from Service endpoints), keeps serving for propagation_ms,
# stops accepting, drains in-flight within grace_ms, and exits — before the 30s
# SIGKILL deadline.
