#!/usr/bin/env bash
# Cross-compile the mkxp dependencies that ps5-payload-dev/pacbrew-repo does
# not provide, and install them into the SDK sysroot
# (${PS5_PAYLOAD_SDK}/target/user/homebrew).
#
# Every source is pinned: tarballs by sha256, git checkouts by commit.
# Tarballs found in ${SRCDEST} are used instead of being downloaded.
#
# Usage: build-deps.sh [COMPONENT...]   (default: all, in dependency order)

set -euo pipefail

: "${PS5_PAYLOAD_SDK:=/opt/ps5-payload-sdk}"
: "${SRCDEST:=${HOME}/sources}"
PATCHDIR="${PATCHDIR:-${HOME}/patches}"
COMPATDIR="${COMPATDIR:-${HOME}/compat}"
WORKDIR="${WORKDIR:-${HOME}/deps-build}"

source "${PS5_PAYLOAD_SDK}/toolchain/prospero.sh"
NPROC="$(nproc)"

mkdir -p "${SRCDEST}" "${WORKDIR}"

# fetch URL SHA256 -> path of the verified tarball
fetch() {
    local url="$1" sha="$2"
    local file="${SRCDEST}/$(basename "${url}")"
    if [ ! -f "${file}" ]; then
        curl -fL --retry 4 -o "${file}.part" "${url}" >&2
        mv "${file}.part" "${file}"
    fi
    echo "${sha}  ${file}" | sha256sum -c - >&2
    echo "${file}"
}

# checkout URL TAG COMMIT DIR -> clone TAG into DIR and verify it is COMMIT
checkout() {
    local url="$1" tag="$2" commit="$3" dir="$4"
    rm -rf "${dir}"
    git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" "${url}" "${dir}" >&2 \
        || { git clone "${url}" "${dir}" >&2 && git -C "${dir}" checkout "${commit}" >&2; }
    local got
    got="$(git -C "${dir}" rev-parse HEAD)"
    if [ "${got}" != "${commit}" ]; then
        echo "${url}@${tag}: expected ${commit}, got ${got}" >&2
        exit 1
    fi
}

# Common autotools configure invocation for the PS5 target
ps5_configure() {
    ./configure --host=x86_64-pc-freebsd --prefix="${PREFIX}" \
                --enable-static --disable-shared "$@"
}

cd "${WORKDIR}"

# libc gap fillers (see compat/ps5compat.c)
build_ps5compat() {
    ${CC} -O2 -fPIC -c "${COMPATDIR}/ps5compat.c" -o ps5compat.o
    ${AR} rcs "${PS5_SYSROOT}${PREFIX}/lib/libps5compat.a" ps5compat.o
    rm -f ps5compat.o
}

# libsigc++ 2.x
build_libsigc() {
    checkout https://github.com/libsigcplusplus/libsigcplusplus.git \
             2.12.1 6bef4e0005f00f0844d917866aec7e3b2d829fdf libsigcplusplus
    (
        cd libsigcplusplus
        ${MESON} setup build -Dbuild-examples=false -Dbuild-tests=false \
                 -Dbuild-documentation=false -Dvalidation=false
        ${MESON} compile -C build
        ${MESON} install -C build --destdir "${PS5_SYSROOT}"
    )
}

# pixman
build_pixman() {
    tarball=$(fetch https://www.cairographics.org/releases/pixman-0.42.2.tar.gz \
                    ea1480efada2fd948bc75366f7c349e1c96d3297d09a3fe62626e38e234a625e)
    rm -rf pixman-0.42.2 && tar xf "${tarball}"
    (
        cd pixman-0.42.2
        ${MESON} setup build -Dtests=disabled -Dgtk=disabled \
                 -Dlibpng=disabled -Dopenmp=disabled
        ${MESON} compile -C build
        ${MESON} install -C build --destdir "${PS5_SYSROOT}"
    )
}

# PhysFS
build_physfs() {
    checkout https://github.com/icculus/physfs.git \
             release-3.2.0 eb3383b532c5f74bfeb42ec306ba2cf80eed988c physfs
    (
        cd physfs
        ${CMAKE} -B build -S . -DCMAKE_BUILD_TYPE=Release \
                 -DPHYSFS_BUILD_SHARED=OFF -DPHYSFS_BUILD_STATIC=ON \
                 -DPHYSFS_BUILD_TEST=OFF -DPHYSFS_BUILD_DOCS=OFF \
                 -DCMAKE_C_FLAGS="-DPHYSFS_NO_CDROM_SUPPORT=1"
        ${MAKE} -C build -j"${NPROC}"
        DESTDIR="${PS5_SYSROOT}" ${MAKE} -C build install
    )
}

# Boost (unordered headers + program_options)
build_boost() {
    tarball=$(fetch https://github.com/boostorg/boost/releases/download/boost-1.86.0/boost-1.86.0-cmake.tar.xz \
                    2c5ec5edcdff47ff55e27ed9560b0a0b94b07bd07ed9928b476150e16b0efc57)
    rm -rf boost-1.86.0 && tar xf "${tarball}"
    (
        cd boost-1.86.0
        ${CMAKE} -B build -S . -DCMAKE_BUILD_TYPE=Release \
                 -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
                 -DBOOST_INCLUDE_LIBRARIES="program_options;unordered"
        ${MAKE} -C build -j"${NPROC}"
        DESTDIR="${PS5_SYSROOT}" ${MAKE} -C build install
    )
}

# SDL_sound (Ancurio's fork, as required by mkxp)
build_sdl_sound() {
    checkout https://github.com/Ancurio/SDL_sound.git \
             master 04798ba55dccd18b094c0f6a2630c2fe7b15aa86 SDL_sound
    (
        cd SDL_sound
        ./bootstrap
        # extra_rwops.c (unused) trips clang >= 16's stricter defaults;
        # static libvorbis(file) needs its deps for configure's link tests.
        SDL2_CONFIG="${PS5_SYSROOT}${PREFIX}/bin/sdl2-config" \
        CFLAGS="-O2 -Wno-error=incompatible-function-pointer-types" \
        LIBS="-lvorbis -logg -lm" \
        ps5_configure --disable-sdltest \
                      --disable-mpg123 --disable-mikmod --disable-modplug \
                      --disable-flac --disable-speex --disable-physfs \
                      --disable-midi --disable-smpeg
        # Empty LIBS keeps libtool from copying libSDL2.a into the archive
        ${MAKE} -j"${NPROC}" LIBS= SDL_LIBS=
        ${MAKE} install DESTDIR="${PS5_SYSROOT}" LIBS= SDL_LIBS=
        "${PS5_CROSS_FIX_ROOT}" "${PS5_SYSROOT}${PREFIX}"
    )
}

# Ruby (MRI), static. patches/ruby-3.1-ps5.patch compiles the zlib extension
# into the core (RGSS provides Zlib without a require) and works around a
# crypt() prototype clash.
build_ruby() {
    checkout https://github.com/ruby/ruby.git \
             v3_1_7 0a3704f218f0aec7f92f3a46a2293175b0a7d2b3 ruby
    (
        cd ruby
        patch -p1 < "${PATCHDIR}/ruby-3.1-ps5.patch"
        ./autogen.sh
        LIBS="-lz -lps5compat" \
        ./configure --host=x86_64-pc-freebsd --target=x86_64-pc-freebsd \
                    --prefix="${PREFIX}" \
                    --with-baseruby="$(command -v ruby)" \
                    --disable-shared --enable-static \
                    --disable-install-doc --disable-rubygems \
                    --disable-jit-support \
                    --with-coroutine=amd64 \
                    --with-static-linked-ext \
                    --with-out-ext='*'
        # 'main' and 'install-local' skip the bundled gems and docs. The
        # SDK's pkg-config wrapper ignores PKG_CONFIG_PATH, which Ruby
        # needs to validate the generated ruby-3.1.pc, so use the host's.
        ${MAKE} -j"${NPROC}" main PKG_CONFIG=pkg-config
        ${MAKE} install-local DESTDIR="${PS5_SYSROOT}" PKG_CONFIG=pkg-config

        # install-local leaves out the arch-specific header (ruby/config.h)
        local archhdr="${PS5_SYSROOT}${PREFIX}/include/ruby-3.1.0/x86_64-freebsd"
        mkdir -p "${archhdr}"
        cp -r .ext/include/x86_64-freebsd/ruby "${archhdr}/"

        # ruby.pc's Libs line assumes a shared libruby; point it at the
        # static library instead.
        sed -i 's|^Libs: .*|Libs: -L${libdir} -l${RUBY_SO_NAME}-static ${MAINLIBS}|' \
            "${PS5_SYSROOT}${PREFIX}/lib/pkgconfig/ruby-3.1.pc"
    )
}

ALL=(ps5compat libsigc++ pixman physfs boost SDL_sound ruby)

# Build the components given on the command line, or all of them
for comp in "${@:-${ALL[@]}}"; do
    echo "==> ${comp}"
    case "${comp}" in
        ps5compat) build_ps5compat ;;
        libsigc++) build_libsigc ;;
        pixman) build_pixman ;;
        physfs) build_physfs ;;
        boost) build_boost ;;
        SDL_sound) build_sdl_sound ;;
        ruby) build_ruby ;;
        *) echo "unknown component: ${comp}" >&2; exit 1 ;;
    esac
done

[ $# -eq 0 ] && rm -rf "${WORKDIR}"
exit 0
