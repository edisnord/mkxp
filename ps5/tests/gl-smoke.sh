#!/usr/bin/env bash
# Host-side check of mkxp's rendering, including the OpenGL core profile
# path that the PS5 native title uses (Mesa llvmpipe in Docker; no console
# needed). See gl-smoke/run-in-container.sh.
#
#   ./ps5/tests/gl-smoke.sh [docker run args...]

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

docker run --rm -v "${SRC_DIR}:/src:ro" "$@" "${BASE_IMAGE:-ubuntu:24.04}" \
       bash /src/ps5/tests/gl-smoke/run-in-container.sh
