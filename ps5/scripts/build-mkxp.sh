#!/usr/bin/env bash
# Configure and build mkxp for the PS5. Runs inside the mkxp-ps5-dev image
# with the mkxp checkout mounted at /src.
#
# Output: /src/ps5/out/mkxp.elf (+ libOSMesa.so.8, if the image has it)

set -euo pipefail

SRC="${SRC:-/src}"
BUILD="${BUILD:-${SRC}/ps5/build}"
OUT="${OUT:-${SRC}/ps5/out}"

source "${PS5_PAYLOAD_SDK}/toolchain/prospero.sh"

${CMAKE} -S "${SRC}" -B "${BUILD}" \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_VERBOSE_MAKEFILE=OFF \
         -DBINDING=MRI -DMRIVERSION=3.1
${CMAKE} --build "${BUILD}" -j"$(nproc)"

mkdir -p "${OUT}"
"${STRIP}" --strip-debug -o "${OUT}/mkxp.elf" "${BUILD}/mkxp.elf"
cp "${SRC}/mkxp.conf.sample" "${OUT}/"

# Runtime OpenGL implementation, dlopen()ed by SDL on the console. The
# payload loader also searches the working directory, which mkxp sets to
# its own location, so it can simply sit next to mkxp.elf.
osmesa="${PS5_SYSROOT}${PS5_HBROOT}/lib/libOSMesa.so.8"
if [ -e "${osmesa}" ]; then
    cp -L "${osmesa}" "${OUT}/"
else
    echo "note: image built without mesa; libOSMesa.so.8 must already be" \
         "installed on the console (e.g. in /user/homebrew/lib)" >&2
fi

echo "Built ${OUT}/mkxp.elf"
