#!/usr/bin/env bash
# Link step for the native-title build, used as CMake's executable link rule:
#
#   native-link.sh <objects...> -o <target> <link libraries...>
#
# Instead of a payload ELF, this produces a PS5 title folder: the objects and
# static libraries go into a linker GROUP that ps5-native-app-boilerplate's
# builder links with its startup code, ps5-opengl's allocator and the system
# import stubs, converts to an FSELF (eboot.bin) and packages with sce_sys
# metadata and the clean-room libc.prx. This mirrors ps5-opengl's
# integration/SDL2/folder.py.
#
# Environment:
#   PS5_NATIVE          ps5-opengl / boilerplate install (setup-native.sh)
#   NATIVE_OUT          where to put the title folder (default: next to target)
#   MKXP_TITLE_ID       PPSAnnnnn title ID (default PPSA77001)
#   MKXP_TITLE_NAME     title name shown on the home screen (default mkxp)
#   MKXP_OUTSIDER_SHIMS Outsider's JavaScript shims, copied into the title as
#                       outsider/shims when Outsider is linked in

set -euo pipefail

: "${PS5_PAYLOAD_SDK:=/opt/ps5-payload-sdk}"
: "${PS5_NATIVE:=/opt/ps5-native}"
: "${MKXP_TITLE_ID:=PPSA77001}"
: "${MKXP_TITLE_NAME:=mkxp}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSROOT="${PS5_PAYLOAD_SDK}/target"
BP="${PS5_NATIVE}/boilerplate"
GL="${PS5_NATIVE}/gl"
GLSRC="${PS5_NATIVE}/ps5-opengl"

[[ ${MKXP_TITLE_ID} =~ ^PPSA[0-9]{5}$ ]] || {
    echo "MKXP_TITLE_ID must be PPSA followed by five digits" >&2; exit 2;
}

# Parse the link line
objects=()
archives=()
libdirs=()
target=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) target="$2"; shift ;;
        -L) libdirs+=("$2"); shift ;;
        -L*) libdirs+=("${1#-L}") ;;
        -l*)
            name="${1#-l}"
            found=
            for dir in "${libdirs[@]}" "${SYSROOT}/user/native/lib" \
                       "${SYSROOT}/user/homebrew/lib" "${SYSROOT}/lib"; do
                if [ -f "${dir}/lib${name}.a" ]; then
                    found="${dir}/lib${name}.a"
                    break
                fi
            done
            # Anything else is a system module import stub; the builder
            # links all of them (--as-needed)
            [ -n "${found}" ] && archives+=("$(realpath "${found}")")
            ;;
        *.o|*.obj) objects+=("$(realpath "$1")") ;;
        *.a) archives+=("$(realpath "$1")") ;;
        *) ;; # compiler/linker flags, .so stubs: not needed here
    esac
    shift
done
[ -n "${target}" ] || { echo "native-link.sh: no -o given" >&2; exit 2; }

target_dir="$(cd "$(dirname "${target}")" && pwd)"
app="${target_dir}/native-app"
NATIVE_OUT="${NATIVE_OUT:-${target_dir}/native}"

# The boilerplate's builder works on a project directory; assemble a fresh
# one the way ps5-opengl's folder.py does
rm -rf "${app}"
mkdir -p "${app}/src" "${app}/vendor" "${app}/.deps"
for dir in runtime sce_sys tooling tools; do
    cp -a "${BP}/${dir}" "${app}/${dir}"
done
cp -a "${BP}/.deps/native" "${app}/.deps/native"

cp "${GLSRC}/native-app/app_heap.c" "${HERE}/mkxp_native.c" "${app}/src/"
cp "${app}/tooling/native/ps5-pie.ld" "${app}/tooling/native/ps5-pie-base.ld"
cp "${GLSRC}/native-app/ps5-pie.ld" "${GLSRC}/native-app/app-symbols.map" \
   "${app}/tooling/native/"

# replace_once FILE OLD NEW
replace_once() {
    python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if text.count(old) != 1:
    raise SystemExit(f"native template changed: {path}: {old}")
open(path, "w").write(text.replace(old, new))
PY
}
replace_once "${app}/tooling/native/sce_module_writer.cpp" \
    "write_u64(result.data, result.heap_size, std::numeric_limits<std::uint64_t>::max());" \
    "write_u64(result.data, result.heap_size, 0x10000000ULL);"
replace_once "${app}/tools/build.sh" \
    'bash "$root/tools/setup-native-dependencies.sh" >/dev/null' \
    'test -x "$root/.deps/native/ps5-payload-sdk/bin/prospero-lld"'
replace_once "${app}/tools/build.sh" \
    '[[ -f $root/runtime/libc.prx ]] || bash "$root/tools/rebuild-libc.sh"' \
    'test -f "$root/runtime/libc.prx"'
# Drop debug info, add ps5-opengl's allocator wraps, and resolve the weak
# references nothing
# defines here (libc++abi's __cxa_thread_atexit_impl; the payload loader's
# __dlopen & co. and kernel_mprotect, used by the SDK's libc.a) to zero, as
# the converter only accepts imports that system stubs export
# The SDK's libc.a implements these as raw syscalls, which a title can't
# execute; mkxp_native.c replaces them (see there)
raw_syscall_wraps=
for sym in mmap mprotect ppoll readlink umask chown lchown lchmod \
           getcwd chdir; do
    raw_syscall_wraps="${raw_syscall_wraps} --wrap=${sym}"
done
weak_null=
for sym in __cxa_thread_atexit_impl __dladdr __dlclose __dlerror __dlopen \
           __dlsym kernel_mprotect; do
    weak_null="${weak_null} --defsym=${sym}=0"
done
replace_once "${app}/tools/build.sh" \
    '--eh-frame-hdr \' \
    "--eh-frame-hdr --strip-debug --wrap=malloc --wrap=calloc --wrap=realloc --wrap=free --wrap=posix_memalign --wrap=malloc_usable_size${raw_syscall_wraps}${weak_null} \\"

# Title metadata: ps5-opengl's template (it sets the GPU memory budgets)
python3 - "${GLSRC}/native-app/param.json" "${app}/sce_sys/param.json" \
          "${MKXP_TITLE_ID}" "${MKXP_TITLE_NAME}" <<'PY'
import json, sys
src, dst, title_id, name = sys.argv[1:]
param = json.load(open(src))
param["titleId"] = title_id
param["conceptId"] = title_id[4:]
param["contentId"] = f"UP9000-{title_id}_00-MKXPRGSSPLAYER00"
lang = param["localizedParameters"]["defaultLanguage"]
param["localizedParameters"][lang]["titleName"] = name
json.dump(param, open(dst, "w"), indent=2)
PY
if [ -n "${MKXP_SCE_SYS:-}" ]; then
    # Custom icon0.png (512x512), pic0.dds/pic1.dds, snd0.at9
    cp "${MKXP_SCE_SYS}"/* "${app}/sce_sys/"
fi

# Besides mkxp and its libraries: the OpenGL runtime, the C++ runtime, and the
# payload SDK's libc for what the native libc lacks (locale functions libc++
# needs, a few syscalls), as the payload build gets from it too
builtins="$(clang-18 --print-resource-dir)/lib/linux/libclang_rt.builtins-x86_64.a"
{
    printf 'SEARCH_DIR("%s")\n' "${SYSROOT}/lib" "${GL}/lib"
    printf 'EXTERN(ps5_agc_gate2_run)\n'
    printf 'GROUP (\n'
    printf '  "%s"\n' "${objects[@]}" "${archives[@]}" \
        "${GL}/lib/libPS5OpenGL.a" \
        "${SYSROOT}/lib/libunwind.a" "${SYSROOT}/lib/libc++abi.a" \
        "${SYSROOT}/lib/libc++.a" "${builtins}" \
        "${SYSROOT}/lib/libc.a"
    printf ')\n'
} > "${app}/vendor/mkxp.a"

(
    cd "${app}"
    # The builder compiles host tools with $CXX if set; don't let the PS5
    # toolchain environment (prospero.sh) leak into them
    env -u CC -u CXX -u LD -u AR -u RANLIB -u STRIP -u NM -u OBJCOPY -u AS \
        APP_STATIC_ARCHIVES=vendor/mkxp.a \
        APP_DEFINITIONS= APP_INCLUDE_PATHS= APP_IMPORT_STUBS= \
        APP_RUNTIME_MODULES= APP_ROOT_FILES= \
        PACBREW_PACKAGES= PACBREW_INCLUDE_PATHS= PACBREW_STATIC_ARCHIVES= \
        USE_CCACHE=0 \
        bash tools/build.sh Folder
)

rm -rf "${NATIVE_OUT}/${MKXP_TITLE_ID}"
mkdir -p "${NATIVE_OUT}"
cp -a "${app}/dist/${MKXP_TITLE_ID}" "${NATIVE_OUT}/"
if [ -n "${MKXP_OUTSIDER_SHIMS:-}" ]; then
    mkdir -p "${NATIVE_OUT}/${MKXP_TITLE_ID}/outsider"
    cp -r "${MKXP_OUTSIDER_SHIMS}" "${NATIVE_OUT}/${MKXP_TITLE_ID}/outsider/shims"
fi
cp "${app}/build/eboot.elf" "${target}"
echo "Native title folder: ${NATIVE_OUT}/${MKXP_TITLE_ID}"
