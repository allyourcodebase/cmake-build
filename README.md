# CMake built with the Zig build system

Builds [CMake](https://cmake.org) (v4.3) from source using `build.zig`, relying
only on Zig's bundled `libc`/`libc++` toolchain. Everything CMake needs
(kwsys, libuv, jsoncpp, librhash, zlib, bzip2, zstd, expat, curl, libarchive)
is vendored in the CMake source tree, so there are **no system dependencies**
and cross-compilation works out of the box.

## Requirements

- Zig `0.16.0` or master
- Nothing else — no system CMake, OpenSSL, or other libraries are needed.

## Build

There are two flavors, selected by `-Dfull`:

| Flavor | Flag | Result |
| --- | --- | --- |
| **Bootstrap** (default) | *(none)* | Minimal self-hosting `cmake` (runs `cmake -E …`); no `--help`/`--version`/docs. |
| **Full** | `-Dfull` | A real `cmake`: `--version`, `--help`, generators, configure/generate/build. |

### Targets

```sh
zig build -Dfull -Dtarget=x86_64-linux-musl     # Linux (static, host-runnable)
zig build -Dfull -Dtarget=aarch64-macos         # macOS (frameworkless)
zig build -Dfull -Dtarget=x86_64-windows-gnu    # Windows (mingw)
```

Optional flags: `-Doptimize=ReleaseFast|ReleaseSmall|ReleaseSafe|Debug` (default `Debug`).

## Use

The full build installs the runtime data (`Modules/`, `Templates/`) next to the
binary at `zig-out/share/cmake-4.3`, so `cmake` resolves `CMAKE_ROOT`
automatically — run it directly from `zig-out`.

```sh
# Version & help
./zig-out/bin/cmake --version
./zig-out/bin/cmake -h

# Command mode (works in both bootstrap and full builds)
./zig-out/bin/cmake -E echo "hello"
./zig-out/bin/cmake -E make_directory build
./zig-out/bin/cmake -E tar cf archive.tar file1 file2
```

### Configure & build a project

```sh
# Given a project with a CMakeLists.txt in ./src:
./zig-out/bin/cmake -S src -B build      # configure + generate (Unix Makefiles)
cmake --build build                       # or: make -C build
```

Example `src/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.10)
project(hello C)
add_executable(hello main.c)
```

```sh
./zig-out/bin/cmake -S src -B build
make -C build
./build/hello
```

## How it works

`build.zig` replicates the upstream `bootstrap` script's logic in Zig:

- All preprocessor configuration flows through `addCMacro` / `addConfigHeader`
  (cmake-style `@VAR@` / `#cmakedefine` templates rendered per target OS).
- Each vendored third-party library is compiled as its own static archive
  (`cLib(...)`) and linked into the final `cmake` executable.
- No build-time globbing — source lists are explicit arrays.

See the comments in `build.zig` for the per-OS specifics (config-header values,
the macOS frameworkless CoreFoundation stubs, the Windows winsock/mingw fixes,
etc.).

## License

- This build glue (`build.zig`, `build.zig.zon`, this README) — [MIT](LICENSE)
- The CMake source it builds — BSD-3-Clause, © Kitware, Inc. and Contributors,
  retained as [`LICENSE.cmake`](LICENSE.cmake).

BSD-3-Clause is permissive and compatible with MIT; the only requirement is
preserving CMake's copyright notice, which `LICENSE.cmake` does.
