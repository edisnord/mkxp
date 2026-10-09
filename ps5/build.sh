#!/usr/bin/env bash
# Build the PS5 toolchain image (cached after the first run) and use it to
# cross-compile mkxp. The result lands in ps5/out/.
#
# Extra arguments are passed to 'docker build', e.g.
#   ./ps5/build.sh --build-arg MAKEFLAGS=-j16
#   ./ps5/build.sh --build-arg WITH_MESA=0

set -euo pipefail

PS5_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "${PS5_DIR}")"
IMAGE="${IMAGE:-mkxp-ps5-dev}"

docker build -t "${IMAGE}" "$@" "${PS5_DIR}"

docker run --rm \
       --user "$(id -u):$(id -g)" \
       -v "${SRC_DIR}:/src" \
       "${IMAGE}" \
       /src/ps5/scripts/build-mkxp.sh
