# mkxp for the PlayStation 5

This directory cross-compiles mkxp into a PS5 payload (`mkxp.elf`) with the
[ps5-payload-dev SDK](https://github.com/ps5-payload-dev/sdk). The PS5 runs a
modified FreeBSD kernel on x86_64, and the SDK targets it as
`x86_64-sie-ps5` with Clang 18. The PS5 SDK is not available for every host
OS and needs a large set of cross-compiled libraries, so the whole toolchain
runs in a Docker image. Every upstream revision is pinned, so a rebuild on
another machine produces the same toolchain.

## Quick start

Requirements: Docker (BuildKit), about 20 GB of free disk space and an
internet connection. The first run builds the toolchain image. This takes
roughly an hour on 4 cores, and most of that is LLVM and Mesa. Later runs
reuse the cached image and only rebuild mkxp.

```console
$ ./ps5/build.sh                              # or, with more cores:
$ ./ps5/build.sh --build-arg MAKEFLAGS=-j16
```

Output in `ps5/out/`:

| File               | Purpose                                                  |
|--------------------|----------------------------------------------------------|
| `mkxp.elf`         | The payload (statically links everything except PS5 system libraries) |
| `libOSMesa.so.8`   | OpenGL implementation (Mesa llvmpipe), loaded at runtime |
| `mkxp.conf.sample` | Configuration template                                   |

Any arguments to `build.sh` are passed to `docker build`. The script then runs
`scripts/build-mkxp.sh` in the image, with the repository mounted at `/src`.

## What gets built

`Dockerfile` has three expensive layers. Each one is cached on its own:

1. **SDK and libraries from [pacbrew-repo](https://github.com/ps5-payload-dev/pacbrew-repo)**
   (`scripts/build-pacbrew.sh`, using upstream's PKGBUILDs through `makepkg`):
   the SDK, libc++, zlib, bzip2, libpng, libjpeg-turbo, libwebp, freetype,
   libogg, libvorbis, libsamplerate, SDL2 (the
   [PS5 port](https://github.com/ps5-payload-dev/SDL)), SDL2_image, SDL2_ttf
   and OpenAL Soft.
2. **LLVM and Mesa** (also from pacbrew-repo). The PS5 SDL port gets OpenGL
   by `dlopen()`ing `libOSMesa.so.8`, which renders in software with llvmpipe.
   Mesa is needed at runtime only, not for linking. See `WITH_MESA` below.
3. **mkxp dependencies that pacbrew lacks** (`scripts/build-deps.sh`):

   | Component | Version | Notes |
   |-----------|---------|-------|
   | libps5compat | in-tree (`compat/`) | `execl`, `execle` and `endpwent`, which the SDK's libc lacks and Ruby needs |
   | libsigc++ | 2.12.1 | |
   | pixman | 0.42.2 | |
   | PhysFS | 3.2.0 | |
   | Boost | 1.86.0 | `unordered` headers, `program_options` |
   | SDL_sound | [Ancurio's fork](https://github.com/Ancurio/SDL_sound) @ `04798ba` | WAV, VOC, AIFF, AU, RAW, SHN, Ogg |
   | Ruby (MRI) | 3.1.7 | static, no stdlib extensions, `Zlib` compiled into the core like in RGSS (`patches/ruby-3.1-ps5.patch`) |

Pinned upstream revisions, set as `ARG`s in the `Dockerfile`:

| ARG | Repository |
|-----|------------|
| `PS5_SDK_COMMIT` | ps5-payload-dev/sdk |
| `PS5_PACBREW_COMMIT` | ps5-payload-dev/pacbrew-repo (fixes the versions of every pacbrew package) |
| `PS5_SDL_COMMIT` | ps5-payload-dev/SDL |

Tarballs are verified by sha256 (in the PKGBUILDs or in `build-deps.sh`).
Git checkouts are verified by commit hash.

### Build arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `MAKEFLAGS` | `-j4` | Parallelism for the toolchain build |
| `WITH_MESA` | `1` | `0` skips LLVM and Mesa, which saves most of the build time. You then need a `libOSMesa.so.8` from another source on the console |
| `BASE_IMAGE` | `ubuntu:24.04` | Override this to use a derived image, e.g. one that trusts a corporate proxy CA |
| `PS5_*_COMMIT` | see above | Bump these deliberately to update the toolchain |

### Offline or mirrored sources

Any file placed in `ps5/sources/` is copied into the image as makepkg's
`SRCDEST` and as `build-deps.sh`'s download cache. Files are still checked
against their pinned sha256, so a file from a mirror works only if it is
identical to the upstream one. Missing files are downloaded as usual. File
names must match what makepkg would save, which is usually the basename of the
URL, e.g. `v0.8.6.tar.gz` for openlibm.

## Working in the image by hand

```console
$ docker run --rm -it -v "$PWD:/src" --user "$(id -u):$(id -g)" mkxp-ps5-dev bash
$ /src/ps5/scripts/build-mkxp.sh          # same as build.sh's last step
$ source $PS5_PAYLOAD_SDK/toolchain/prospero.sh
$ $CMAKE --build /src/ps5/build           # incremental rebuild
```

`build-deps.sh` also takes component names, e.g. `build-deps.sh ruby`. This
helps when you change one dependency in a derived image.

## Running on the console

You need a PS5 that runs an ELF loader such as
[elfldr](https://github.com/ps5-payload-dev/elfldr), which listens on port
9021.

1. Copy `libOSMesa.so.8` to `/user/homebrew/lib/` on the console, e.g. with
   ftpsrv. The payload loader also searches the working directory, so a copy
   next to the game works too.
2. Copy the game (the folder with `Game.ini`), `mkxp.conf` and optionally
   `mkxp.elf` to the console, e.g. `/data/mkxp/`.
3. mkxp switches to the directory of its own executable before it reads
   `mkxp.conf`. If the loader does not pass a path in `argv[0]` (for example,
   when the ELF is sent straight to port 9021), the PS5 SDL port reports
   `/data/` instead. In that case, put a `mkxp.conf` in `/data/` that points
   at the game:

   ```ini
   gameFolder=/data/mkxp/MyGame
   ```

4. Send the payload:

   ```console
   $ docker run --rm --network host -v "$PWD/ps5/out:/out" mkxp-ps5-dev \
         /opt/ps5-payload-sdk/bin/prospero-deploy -h <ps5-ip> /out/mkxp.elf
   ```

   (`socat -t 99999999 - TCP:<ps5-ip>:9021 < ps5/out/mkxp.elf` also works.)

The window always covers the whole 1920×1080 display, because the PS5 video
driver centers smaller windows instead of scaling them. mkxp scales the game
itself, so set `fixedAspectRatio` and `smoothScaling` in `mkxp.conf` to taste.

Default DualSense mapping. To change it, edit `src/keybindings.cpp`, or plug
in a USB keyboard and use mkxp's F1 menu:

| DualSense | RGSS button |
|-----------|-------------|
| Cross     | C (confirm) |
| Circle, Options | B (cancel / menu) |
| Square    | A |
| Triangle  | X |
| L1 / R1   | L / R |
| L2 / R2   | Y / Z |
| D-pad, left stick | directions |

## Changes to mkxp for this port

- `CMakeLists.txt`: name the binary `mkxp.elf` when built with the PS5
  toolchain. Import SDL2's CMake target before OpenAL, because the static
  OpenAL Soft package refers to it.
- `src/main.cpp`: on `__PROSPERO__`, create the window at desktop size.
- `src/keybindings.cpp`: DualSense default bindings on `__PROSPERO__`.
- Portability fixes that help any modern toolchain:
  - `binding-util.h`: Ruby version checks that also hold for Ruby 3.x, and a
    `rb_data_type_t` initializer that stays valid since Ruby 2.7 changed the
    struct.
  - `eventthread.cpp`: no duplicate `ALC_SOFT_pause_device` typedefs with new
    OpenAL Soft headers.
  - `fluid-fun.cpp`: recognize FreeBSD.

## Known limitations

- **Not yet tested on hardware.** The build is verified to produce a valid
  payload that links only against PS5 system libraries.
- Rendering is software OpenGL (llvmpipe). RGSS resolutions are small, but
  expect it to be slower than on a PC.
- No MIDI: mkxp would `dlopen()` fluidsynth, and no PS5 build of it is
  bundled. No MP3: SDL_sound is built without mpg123.
- Ruby is 3.1, not the 1.8/1.9 that RPG Maker used, and has no stdlib
  extensions. Scripts that rely on old syntax or on `require` of stdlib
  libraries need changes, as on any modern mkxp build.
