# syntax=docker/dockerfile:1
# Sigil in a container — the one image behind the Windows pathway (install.ps1,
# docs/reference/windows.md) and the sandbox (tools/sandbox/run.sh).
#
#   ./docker/build.sh [tag]     # reads the jac pin and builds from the files git knows
#
# Built on jaseci's own jac image, so the container runs the same native jac a host
# install does — never a PyPI jaclang, which stopped at 0.16 and cannot run this tree.
# JAC_VERSION must equal jac.toml's `jac-version`: the build fails below if it
# does not, so the image cannot quietly drift from the one pin. Everything that
# builds it (docker/build.sh, release.yml, install.ps1's source fallback) reads the
# pin and passes it in.
#
# Layout — the same split as a host install, with the halves on different paths so
# a volume can hold the state without freezing the code:
#   /opt/sigil/app           the source tree, compiled at build time (jac's compile
#                            cache is keyed to the absolute path, and this path is
#                            final, so the image ships warm)
#   /home/jac/.sigil         Sigil's state: config, secrets, logs, run/ — a volume
#   /opt/jac/state/pg        the graph: jac 0.37 keeps it in an embedded Postgres
#                            cluster under $JAC_CACHE_HOME, one database per
#                            project path — a volume. (.jac/data in the app holds
#                            only Sigil's graph write lock; it stays in the image,
#                            owned by jac, because a lock it cannot open fails open.)
#   /opt/sigil/app/src/crystallized
#                            compiled skills: Sigil writes each one into the app
#                            tree, where a replaced container would lose it while
#                            the graph still points at it — a volume. The build
#                            creates it (it is gitignored, so not in the context):
#                            a VOLUME Docker has to create itself is root-owned.
ARG JAC_VERSION=0.37.25
FROM jaseci/jaclang:${JAC_VERSION}
ARG JAC_VERSION
# Links the published package (ghcr.io/sigilagent/sigil) to its repository.
LABEL org.opencontainers.image.source="https://github.com/sigilagent/sigil" \
      org.opencontainers.image.description="Sigil, the skill compiler, on jac ${JAC_VERSION}" \
      org.opencontainers.image.licenses="MIT"

USER root
# ps and lsof: Sigil finds who holds a port with them (sigil_serve, main). python3:
# compiled tools and model-written scripts call it by name. curl: `sigil login`
# against a gateway. The base image runs as an unprivileged account and ships jac's
# bundled bun without its exec bit in a root-owned tree, so `jac install` cannot
# build the Observatory's web client until root fixes that here. It also leaves
# XDG_CACHE_HOME root-owned, and jac (and much model-written code) writes there.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 procps lsof curl \
    && rm -rf /var/lib/apt/lists/* \
    && chown jac:jac "$JAC_CACHE_HOME"/rt/*/site/jaclang/client/_bun/bun \
    && chmod a+x "$JAC_CACHE_HOME"/rt/*/site/jaclang/client/_bun/bun \
    && mkdir -p /opt/sigil/app /home/jac/.sigil "$JAC_CACHE_HOME/pg" \
    && chown -R jac:jac /opt/sigil /home/jac/.sigil "$JAC_CACHE_HOME/pg" "$XDG_CACHE_HOME" \
    && printf '%s\n' \
        '#!/bin/sh' \
        '# Sigil launcher shim (docker/Dockerfile), the image twin of install.sh step 4' \
        'export SIGIL_PWD="${SIGIL_PWD:-$PWD}"' \
        'export SIGIL_JAC="${SIGIL_JAC:-/usr/local/bin/jac}"' \
        'cd /opt/sigil/app && exec ./sigil "$@"' \
        > /usr/local/bin/sigil \
    && printf '%s\n' \
        '#!/bin/sh' \
        '# The container entrypoint (docker/Dockerfile). A container start is a boot:' \
        '# the pidfiles and attempt stamps in run/ name processes of a container that' \
        '# is gone, and PIDs restart from 1, so an old pid matches a live process here.' \
        '# Clear them the way a host clears /run, then run the command as usual.' \
        'rm -rf "${SIGIL_HOME:-$HOME/.sigil}/run"' \
        'exec sigil "$@"' \
        > /usr/local/bin/sigil-boot \
    && chmod 0755 /usr/local/bin/sigil /usr/local/bin/sigil-boot

# The container is a machine of its own: the Observatory listens on every interface
# so its published port reaches it, while its Host check still answers to localhost
# (SIGIL_SERVE_BIND, not SIGIL_SERVE_HOST). Browser sign-ins come back on one fixed
# port for the same reason. Publish both on the host's loopback only:
#   -p 127.0.0.1:8199:8199 -p 127.0.0.1:1455:1455
# The model-written code this agent runs stays in here; the only host files it sees
# are the ones you mount (install.ps1 mounts your user folder at /host).
ENV SIGIL_SERVE_BIND=0.0.0.0 \
    SIGIL_OAUTH_BIND=0.0.0.0 \
    SIGIL_OAUTH_PORT=1455 \
    SIGIL_AUTOSTART=0

USER jac
WORKDIR /opt/sigil/app
COPY --chown=jac:jac . /opt/sigil/app

# The pin check, then everything jac.toml declares (Python deps land in the
# project's .jac/venv, the Observatory's npm deps in .jac/client), then one CLI run
# so its compile cache is in the image rather than in every container's first
# minute. (The Observatory cannot be warmed the same way: every `jac run main.jac`
# — the daemon starting is one — rewrites the client build, so it rebuilds at
# start on a host too.) SIGIL_NO_DAEMON/SERVE: a build step must not leave
# services behind; the graph it touched is wiped so a container starts with its own.
RUN want="$(sed -n 's/^jac-version *= *"=*\([0-9][0-9.]*\)".*/\1/p' jac.toml | head -1)" \
    && have="$(jac --version | sed -n 's/^jac \([0-9][0-9.]*\).*/\1/p')" \
    && { [ "$want" = "$have" ] || { echo "jac.toml pins jac $want; this image is jac $have (JAC_VERSION=$JAC_VERSION)." >&2; exit 1; }; } \
    && chmod +x sigil \
    && jac install \
    && SIGIL_NO_DAEMON=1 SIGIL_NO_SERVE=1 sigil local help | grep -q "the skill compiler" \
    && rm -rf .jac/data/* "$JAC_CACHE_HOME"/pg/* /home/jac/.sigil/* /tmp/* \
    && mkdir -p .jac/data src/crystallized

VOLUME ["/home/jac/.sigil", "/opt/jac/state/pg", "/opt/sigil/app/src/crystallized"]
EXPOSE 8199 1455

# The daemon in the foreground: scheduler, channels and the Observatory, one
# process tree for `docker run --init`. The container stands where the login
# service does on a host, so it carries the variable that service's unit sets
# (sigil_daemon._service_env) to bring the Observatory up with the scheduler.
# Other commands go through `docker exec` into this container, never a second
# one on the same volumes: two embedded Postgres servers on one data directory
# corrupt it.
ENV SIGIL_SERVICE_SERVE=1
ENTRYPOINT ["sigil-boot"]
CMD ["daemon", "run", "30"]
