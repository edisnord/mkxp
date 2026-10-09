#!/usr/bin/env bash
# Build the PS5 toolchain image (cached after the first run) and use it to
# cross-compile mkxp. The result lands in ps5/out/.
#
# Extra arguments are passed to 'docker build', e.g.
#   ./ps5/build.sh --build-arg MAKEFLAGS=-j16
#   ./ps5/build.sh --build-arg WITH_MESA=0
#
# Environment:
#   TARGET           payload, native or all (default: all)
#   MKXP_TITLE_ID    native title ID, PPSAnnnnn (default PPSA77001)
#   MKXP_TITLE_NAME  native title name (default mkxp)
#   MKXP_SCE_SYS     directory (inside this repository) with replacement
#                    icon0.png / pic0.dds / pic1.dds / snd0.at9

set -euo pipefail

PS5_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "${PS5_DIR}")"
IMAGE="${IMAGE:-mkxp-ps5-dev}"

docker build -t "${IMAGE}" "$@" "${PS5_DIR}"

env_args=()
for var in MKXP_TITLE_ID MKXP_TITLE_NAME; do
    [ -n "${!var:-}" ] && env_args+=(-e "${var}=${!var}")
done
if [ -n "${MKXP_SCE_SYS:-}" ]; then
    sce_sys="$(realpath "${MKXP_SCE_SYS}")"
    case "${sce_sys}" in
        "${SRC_DIR}"/*) env_args+=(-e "MKXP_SCE_SYS=/src/${sce_sys#"${SRC_DIR}"/}") ;;
        *) echo "MKXP_SCE_SYS must be inside ${SRC_DIR}" >&2; exit 2 ;;
    esac
fi

docker run --rm \
       --user "$(id -u):$(id -g)" \
       -v "${SRC_DIR}:/src" \
       "${env_args[@]}" \
       "${IMAGE}" \
       /src/ps5/scripts/build-mkxp.sh "${TARGET:-all}"
