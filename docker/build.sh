#!/usr/bin/env bash
# Build the Sigil image from this checkout.
#
#   ./docker/build.sh                 # tags sigil:local
#   ./docker/build.sh sigil:dev       # any tag
#
# Reads the jac pin from jac.toml (the one place it lives) and passes it as
# JAC_VERSION, so the base image is always the jac this tree runs on.
#
# The context is a tarball of the files git knows about, not the directory: a
# working checkout carries untracked weight (skillsbench/, a live graph in .jac/)
# that must never reach an image, and the legacy builder — still the default
# where buildx is missing — ignores docker/Dockerfile.dockerignore entirely.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-sigil:local}"
JAC_VERSION="$(sed -n 's/^jac-version *= *"=*\([0-9][0-9.]*\)".*/\1/p' jac.toml | head -1)"
[ -n "$JAC_VERSION" ] || { echo "no jac-version pin in jac.toml" >&2; exit 1; }

echo "==> building $TAG on jaseci/jaclang:$JAC_VERSION" >&2
# macOS tar ships provenance xattrs the daemon refuses to apply ("lsetxattr ...
# operation not supported"), so strip them there; GNU tar has no such flags.
strip=()
tar --version 2>/dev/null | grep -q bsdtar && strip=(--no-xattrs --no-mac-metadata)
git ls-files -co --exclude-standard \
    sigil jac.toml observatory.jac src docs web examples LICENSE README.md docker \
  | COPYFILE_DISABLE=1 tar "${strip[@]}" -cf - -T - \
  | docker build -f docker/Dockerfile --build-arg "JAC_VERSION=$JAC_VERSION" -t "$TAG" -
