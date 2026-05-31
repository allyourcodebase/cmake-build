const std = @import("std");

// Build CMake from source using the Zig build system, replicating the logic of
// the upstream `bootstrap` shell script (a minimal, self-hosting `cmake`).
//
// Everything CMake needs is vendored inside the CMake source tree (kwsys,
// libuv, jsoncpp, librhash), so we rely solely on the Zig-provided libc/libc++
// toolchain and never touch system packages. This makes cross-compilation to
// x86_64-linux-musl, aarch64-macos (no Apple frameworks) and x86_64-windows-gnu
// work out of the box.
pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("cmake", .{});
    const os = target.result.os.tag;
    const is_windows = os == .windows;
    const is_darwin = os.isDarwin();

    // Zig defaults aarch64-macos to a recent deployment target (>= 13.0), which
    // makes cmMachO pull in <mach-o/utils.h> — a header absent from the
    // SDK-less, framework-free macOS toolchain. Pin the minimum to 11.0 (unless
    // the user asked for a specific version) so that gated include is skipped.
    if (is_darwin and target.query.os_version_min == null) {
        var q = target.query;
        q.os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } };
        target = b.resolveTargetQuery(q);
    }

    // The full build (real cmake with --help/--version/docs) drops
    // CMAKE_BOOTSTRAP and compiles the entire vendored third-party stack.
    if (b.option(bool, "full", "Build the complete CMake (curl/libarchive/expat/...) so cmake --version works") orelse false) {
        return buildFull(b, target, optimize, dep);
    }

    // Absolute path to the CMake source tree, baked into the bootstrap binary
    // so it can locate its Modules/ at runtime (mirrors the bootstrap script).
    const cm_root = dep.path(".").getPath(b);

    // --- Generated configuration headers -----------------------------------
    // A single WriteFiles tree gathers every generated header so the compiler
    // sees one include directory containing `cmConfigure.h`, `cmVersionConfig.h`,
    // `cmThirdParty.h` and the `cmsys/` namespace headers.
    const gen = b.addWriteFiles();

    var cfg = std.array_list.Managed(u8).init(b.allocator);
    cfg.appendSlice(
        \\#pragma once
        \\#define CMAKE_BOOTSTRAP_BINARY_DIR "/bootstrap-not-installed"
        \\#define CMake_DEFAULT_RECURSION_LIMIT 400
        \\#define CMAKE_BIN_DIR "/bootstrap-not-installed"
        \\#define CMAKE_DATA_DIR "/bootstrap-not-installed"
        \\#define CM_FALLTHROUGH
        \\#define CMAKE_BOOTSTRAP_MAKEFILES
        \\
    ) catch @panic("OOM");
    cfg.appendSlice(b.fmt("#define CMAKE_BOOTSTRAP_SOURCE_DIR \"{s}\"\n", .{cm_root})) catch @panic("OOM");
    if (is_darwin) {
        cfg.appendSlice("#define CMake_USE_MACH_PARSER\n") catch @panic("OOM");
    }
    if (is_windows) {
        cfg.appendSlice(
            \\#if defined(_WIN32) && !defined(NOMINMAX)
            \\#  define NOMINMAX
            \\#endif
            \\#if defined(_WIN32) && !defined(KWSYS_ENCODING_DEFAULT_CODEPAGE)
            \\#  define KWSYS_ENCODING_DEFAULT_CODEPAGE CP_UTF8
            \\#endif
            \\
        ) catch @panic("OOM");
    }
    _ = gen.add("cmConfigure.h", cfg.items);

    // Version (Source/CMakeVersion.cmake: 4.3.20260530).
    _ = gen.add("cmVersionConfig.h",
        \\#define CMake_VERSION_MAJOR 4
        \\#define CMake_VERSION_MINOR 3
        \\#define CMake_VERSION_PATCH 20260530
        \\#define CMake_VERSION "4.3.20260530"
        \\
    );

    // No system third-party libraries: everything is bundled.
    _ = gen.add("cmThirdParty.h", "#pragma once\n");

    // cmSTL.hxx is empty in bootstrap mode; the C++ feature availability is
    // instead injected through -DCMake_HAVE_CXX_* flags (see below).
    _ = gen.add("cmSTL.hxx", "#pragma once\n");

    // kwsys headers: only @KWSYS_NAMESPACE@ (+ a few numeric flags) need
    // substitution. b.addConfigHeader in cmake-mode performs exactly that.
    const kwsys_values = .{
        // Substituted verbatim into `@KWSYS_NAMESPACE@` (renders as a bare token).
        .KWSYS_NAMESPACE = "cmsys",
        .KWSYS_NAME_IS_KWSYS = 0,
        .KWSYS_BUILD_SHARED = 0,
        .KWSYS_CXX_HAS_EXT_STDIO_FILEBUF_H = 0,
    };
    const kwsys_headers = [_][]const u8{
        "Configure.h",      "Configure.hxx",       "Directory.hxx",
        "Encoding.h",       "Encoding.hxx",        "FStream.hxx",
        "Glob.hxx",         "Process.h",           "RegularExpression.hxx",
        "Status.hxx",       "String.h",            "System.h",
        "SystemTools.hxx",
    };
    for (kwsys_headers) |h| {
        const in_path = b.fmt("Source/kwsys/{s}.in", .{h});
        const ch = b.addConfigHeader(
            .{ .style = .{ .cmake = dep.path(in_path) }, .include_path = h },
            kwsys_values,
        );
        _ = gen.addCopyFile(ch.getOutputFile(), b.fmt("cmsys/{s}", .{h}));
    }

    // --- The cmake executable module ---------------------------------------
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        // The vendored C third-party code is not UBSan-clean; disable the C
        // sanitizer (b.sanitize_c equivalent at the module level).
        .sanitize_c = .off,
    });

    // --- Module-wide preprocessor macros (applied to every C/C++ source) ----
    // CMAKE_BOOTSTRAP gates the minimal feature set and makes uv/unix.h pick
    // the generic posix-poll backend.
    mod.addCMacro("CMAKE_BOOTSTRAP", "");
    // Zig ships clang + libc++, so std::make_unique and std::filesystem are
    // always available (the bootstrap script detects these at configure time).
    mod.addCMacro("CMake_HAVE_CXX_MAKE_UNIQUE", "1");
    mod.addCMacro("CMake_HAVE_CXX_FILESYSTEM", "1");
    if (os == .linux) {
        // 64-bit file/time offsets even on 32-bit hosts.
        mod.addCMacro("_FILE_OFFSET_BITS", "64");
        mod.addCMacro("_TIME_BITS", "64");
    }

    // kwsys is compiled into the `cmsys` namespace. Only kwsys translation
    // units consume these macros, so defining them module-wide is harmless and
    // lets us avoid per-file `-D` flags.
    mod.addCMacro("KWSYS_NAMESPACE", "cmsys");
    mod.addCMacro("KWSYS_STRING_C", ""); // gates the body of String.c
    // SystemTools capability probes (the bootstrap script detects these on the
    // host; we set them from the target instead). Only SystemTools.cxx reads them.
    const yes = "1";
    const no = "0";
    mod.addCMacro("KWSYS_CXX_HAS_SETENV", if (is_windows) no else yes);
    mod.addCMacro("KWSYS_CXX_HAS_UNSETENV", if (is_windows) no else yes);
    mod.addCMacro("KWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H", if (is_windows) yes else no);
    mod.addCMacro("KWSYS_CXX_HAS_UTIMENSAT", if (is_windows) no else yes);
    mod.addCMacro("KWSYS_CXX_HAS_UTIMES", if (is_windows) no else yes);

    // libuv platform feature macros.
    if (is_windows) {
        // kwsys Encoding sources reference this without including cmConfigure.h,
        // so provide it module-wide (CP_UTF8 comes from <windows.h>). We do NOT
        // define WIN32_LEAN_AND_MEAN globally: it makes <windows.h> drop the rpc
        // headers that declare `byte`, which SystemTools.cxx needs. _WIN32_WINNT
        // is left to Zig's mingw default (>= 0x0a00, already > libuv's minimum).
        mod.addCMacro("KWSYS_ENCODING_DEFAULT_CODEPAGE", "CP_UTF8");
    } else if (os == .linux) {
        mod.addCMacro("_GNU_SOURCE", "");
    } else if (is_darwin) {
        mod.addCMacro("_DARWIN_USE_64_BIT_INODE", "1");
        mod.addCMacro("_DARWIN_UNLIMITED_SELECT", "1");
    }

    // librhash: disable symbol import/export decorations.
    mod.addCMacro("NO_IMPORT_EXPORT", "");

    // --- Per-language flags -------------------------------------------------
    // Every preprocessor macro now flows through addCMacro above; these lists
    // only carry the language standard switch.
    var cxx_flags = std.array_list.Managed([]const u8).init(b.allocator);
    cxx_flags.append("-std=c++17") catch @panic("OOM"); // CMake 4.x requires C++17
    if (is_darwin) {
        // The macOS clang target promotes the spaced `operator"" _s` form
        // (used in cmext/string_view) to an error; downgrade it to a warning.
        cxx_flags.append("-Wno-deprecated-literal-operator") catch @panic("OOM");
    }

    // C sources use the toolchain default standard (matches bootstrap).
    const c_flags = std.array_list.Managed([]const u8).init(b.allocator);

    // Include search paths (mirror bootstrap's -I list).
    mod.addIncludePath(gen.getDirectory());
    mod.addIncludePath(dep.path("Source"));
    mod.addIncludePath(dep.path("Source/LexerParser"));
    mod.addIncludePath(dep.path("Utilities"));
    mod.addIncludePath(dep.path("Utilities/std"));
    mod.addIncludePath(dep.path("Utilities/cmjsoncpp/include"));

    // Frameworkless macOS: cmFindProgramCommand unconditionally pulls in
    // CoreFoundation under `#if __APPLE__` to resolve .app bundles. We have no
    // Apple frameworks, so satisfy it with tiny stub headers + no-op
    // implementations (bundle resolution simply returns empty at runtime).
    if (is_darwin) {
        const cf = b.addWriteFiles();
        _ = cf.add("CoreFoundation/CFBundle.h", cf_stub_header);
        _ = cf.add("CoreFoundation/CFString.h", "#pragma once\n#include <CoreFoundation/CFBundle.h>\n");
        _ = cf.add("CoreFoundation/CFURL.h", "#pragma once\n#include <CoreFoundation/CFBundle.h>\n");
        _ = cf.add("cf_stub.c", cf_stub_impl);
        mod.addIncludePath(cf.getDirectory());
        mod.addCSourceFiles(.{ .root = cf.getDirectory(), .files = &.{"cf_stub.c"}, .flags = c_flags.items });
    }

    const exe = b.addExecutable(.{ .name = "cmake", .root_module = mod });

    // --- Main C++ sources (Source/*.cxx) -----------------------------------
    var cxx = std.array_list.Managed([]const u8).init(b.allocator);
    appendExt(&cxx, b, &cmake_cxx_sources, ".cxx");
    // Makefiles generator (we bootstrap with -DCMAKE_BOOTSTRAP_MAKEFILES).
    appendExt(&cxx, b, &makefile_generator_sources, ".cxx");
    if (is_darwin) appendExt(&cxx, b, &.{"cmMachO"}, ".cxx");
    if (is_windows) appendExt(&cxx, b, &mingw_cxx_sources, ".cxx");
    // SystemTools.cxx is handled separately (extra defines); everything else
    // in the main list uses the common cxx flags.
    mod.addCSourceFiles(.{
        .root = dep.path("Source"),
        .files = cxx.items,
        .flags = cxx_flags.items,
    });

    // C sources in Source/ (cm_utf8).
    mod.addCSourceFiles(.{
        .root = dep.path("Source"),
        .files = &.{"cm_utf8.c"},
        .flags = c_flags.items,
    });

    // LexerParser sources.
    var lp_cxx = std.array_list.Managed([]const u8).init(b.allocator);
    appendExt(&lp_cxx, b, &lexerparser_cxx_sources, ".cxx");
    mod.addCSourceFiles(.{
        .root = dep.path("Source/LexerParser"),
        .files = lp_cxx.items,
        .flags = cxx_flags.items,
    });
    mod.addCSourceFiles(.{
        .root = dep.path("Source/LexerParser"),
        .files = &.{"cmListFileLexer.c"},
        .flags = c_flags.items,
    });

    // C++ standard-library shims (Utilities/std/cm/bits/*.cxx).
    mod.addCSourceFiles(.{
        .root = dep.path("Utilities/std/cm/bits"),
        .files = &.{ "fs_path.cxx", "string_view.cxx" },
        .flags = cxx_flags.items,
    });

    // --- kwsys (compiled into the cmsys namespace) -------------------------
    var kwsys_cxx_flags = std.array_list.Managed([]const u8).init(b.allocator);
    kwsys_cxx_flags.appendSlice(cxx_flags.items) catch @panic("OOM");
    kwsys_cxx_flags.append("-DKWSYS_NAMESPACE=cmsys") catch @panic("OOM");

    var kwsys_c_flags = std.array_list.Managed([]const u8).init(b.allocator);
    kwsys_c_flags.appendSlice(c_flags.items) catch @panic("OOM");
    kwsys_c_flags.append("-DKWSYS_NAMESPACE=cmsys") catch @panic("OOM");

    // kwsys C++ sources except SystemTools (which needs feature defines).
    mod.addCSourceFiles(.{
        .root = dep.path("Source/kwsys"),
        .files = &.{
            "Directory.cxx",  "EncodingCXX.cxx", "FStream.cxx",
            "Glob.cxx",       "RegularExpression.cxx", "Status.cxx",
        },
        .flags = kwsys_cxx_flags.items,
    });

    // SystemTools.cxx with platform capability flags.
    var systools_flags = std.array_list.Managed([]const u8).init(b.allocator);
    systools_flags.appendSlice(kwsys_cxx_flags.items) catch @panic("OOM");
    const has_posix_env = !is_windows;
    systools_flags.appendSlice(&.{
        if (has_posix_env) "-DKWSYS_CXX_HAS_SETENV=1" else "-DKWSYS_CXX_HAS_SETENV=0",
        if (has_posix_env) "-DKWSYS_CXX_HAS_UNSETENV=1" else "-DKWSYS_CXX_HAS_UNSETENV=0",
        if (is_windows) "-DKWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H=1" else "-DKWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H=0",
        if (has_posix_env) "-DKWSYS_CXX_HAS_UTIMENSAT=1" else "-DKWSYS_CXX_HAS_UTIMENSAT=0",
        if (has_posix_env) "-DKWSYS_CXX_HAS_UTIMES=1" else "-DKWSYS_CXX_HAS_UTIMES=0",
    }) catch @panic("OOM");
    mod.addCSourceFiles(.{
        .root = dep.path("Source/kwsys"),
        .files = &.{"SystemTools.cxx"},
        .flags = systools_flags.items,
    });

    // kwsys C sources. String.c needs -DKWSYS_STRING_C.
    const process_c = if (is_windows) "ProcessWin32.c" else "ProcessUNIX.c";
    mod.addCSourceFiles(.{
        .root = dep.path("Source/kwsys"),
        .files = &.{ "EncodingC.c", process_c, "System.c" },
        .flags = kwsys_c_flags.items,
    });
    var kwsys_string_flags = std.array_list.Managed([]const u8).init(b.allocator);
    kwsys_string_flags.appendSlice(kwsys_c_flags.items) catch @panic("OOM");
    kwsys_string_flags.append("-DKWSYS_STRING_C") catch @panic("OOM");
    mod.addCSourceFiles(.{
        .root = dep.path("Source/kwsys"),
        .files = &.{"String.c"},
        .flags = kwsys_string_flags.items,
    });

    // --- libuv -------------------------------------------------------------
    var uv_flags = std.array_list.Managed([]const u8).init(b.allocator);
    // CMAKE_BOOTSTRAP (module-wide) makes uv/unix.h select the generic
    // posix-poll backend (uv/posix.h), matching the posix-poll.c /
    // cmake-bootstrap.c sources below.
    uv_flags.append("-I") catch @panic("OOM");
    uv_flags.append(dep.path("Utilities/cmlibuv/include").getPath(b)) catch @panic("OOM");
    uv_flags.append("-I") catch @panic("OOM");
    uv_flags.append(dep.path("Utilities/cmlibuv/src").getPath(b)) catch @panic("OOM");
    if (is_windows) {
        uv_flags.append("-I") catch @panic("OOM");
        uv_flags.append(dep.path("Utilities/cmlibuv/src/win").getPath(b)) catch @panic("OOM");
        // libuv's Windows backend wants the lean header set; scope it to libuv
        // only (see note above re: SystemTools needing the rpc `byte` type).
        uv_flags.append("-DWIN32_LEAN_AND_MEAN") catch @panic("OOM");
    } else {
        uv_flags.append("-I") catch @panic("OOM");
        uv_flags.append(dep.path("Utilities/cmlibuv/src/unix").getPath(b)) catch @panic("OOM");
        if (os == .linux) {
            uv_flags.append("-D_GNU_SOURCE") catch @panic("OOM");
        } else if (is_darwin) {
            uv_flags.appendSlice(&.{ "-D_DARWIN_USE_64_BIT_INODE=1", "-D_DARWIN_UNLIMITED_SELECT=1" }) catch @panic("OOM");
        }
    }
    mod.addCSourceFiles(.{
        .root = dep.path("Utilities/cmlibuv"),
        .files = if (is_windows) &libuv_win_sources else &libuv_unix_sources,
        .flags = uv_flags.items,
    });

    // --- librhash ----------------------------------------------------------
    mod.addCSourceFiles(.{
        .root = dep.path("Utilities/cmlibrhash"),
        .files = &librhash_sources,
        .flags = &.{"-DNO_IMPORT_EXPORT"},
    });

    // --- jsoncpp -----------------------------------------------------------
    mod.addCSourceFiles(.{
        .root = dep.path("Utilities/cmjsoncpp"),
        .files = &jsoncpp_sources,
        .flags = cxx_flags.items,
    });

    // --- Platform libraries ------------------------------------------------
    if (is_windows) {
        const win_libs = [_][]const u8{
            "advapi32", "dbghelp",  "iphlpapi", "ole32",  "oleaut32",
            "psapi",    "shell32",  "user32",   "userenv", "uuid", "ws2_32",
        };
        for (win_libs) |l| mod.linkSystemLibrary(l, .{});
    } else if (os == .linux) {
        // On musl these symbols live in libc; only glibc needs explicit -l.
        if (target.result.abi != .musl and target.result.abi != .musleabi and target.result.abi != .musleabihf) {
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("rt", .{});
        }
    }
    // aarch64-macos: intentionally no Apple frameworks (per project goal).

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the bootstrapped cmake");
    run_step.dependOn(&run_cmd.step);
}

fn appendExt(list: *std.array_list.Managed([]const u8), b: *std.Build, names: []const []const u8, ext: []const u8) void {
    for (names) |n| list.append(b.fmt("{s}{s}", .{ n, ext })) catch @panic("OOM");
}

// Minimal CoreFoundation surface used by cmFindProgramCommand::GetBundleExecutable
// and (in the full build) cmGlobalXCodeGenerator (CFUUID*, CFStringGetCString,
// LSOpenCFURLRef). Frameworkless macOS has no CoreFoundation, so these are no-op
// stubs — they let the Apple-only TUs compile and link; the code paths are never
// meaningfully exercised in this toolchain.
const cf_stub_header =
    \\#pragma once
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\typedef const void* CFTypeRef;
    \\typedef const struct __CFString* CFStringRef;
    \\typedef const struct __CFURL* CFURLRef;
    \\typedef struct __CFBundle* CFBundleRef;
    \\typedef struct __CFUUID* CFUUIDRef;
    \\typedef const struct __CFAllocator* CFAllocatorRef;
    \\typedef unsigned int CFStringEncoding;
    \\typedef long CFIndex;
    \\typedef int OSStatus;
    \\#define noErr 0
    \\typedef unsigned char UInt8;
    \\typedef unsigned char Boolean;
    \\typedef CFIndex CFURLPathStyle;
    \\extern const CFAllocatorRef kCFAllocatorDefault;
    \\#define kCFStringEncodingUTF8 ((CFStringEncoding)0x08000100)
    \\#define kCFURLPOSIXPathStyle ((CFURLPathStyle)0)
    \\CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char*, CFStringEncoding);
    \\Boolean CFStringGetCString(CFStringRef, char*, CFIndex, CFStringEncoding);
    \\CFURLRef CFURLCreateWithFileSystemPath(CFAllocatorRef, CFStringRef, CFURLPathStyle, Boolean);
    \\CFBundleRef CFBundleCreate(CFAllocatorRef, CFURLRef);
    \\CFURLRef CFBundleCopyExecutableURL(CFBundleRef);
    \\Boolean CFURLGetFileSystemRepresentation(CFURLRef, Boolean, UInt8*, CFIndex);
    \\CFUUIDRef CFUUIDCreate(CFAllocatorRef);
    \\CFStringRef CFUUIDCreateString(CFAllocatorRef, CFUUIDRef);
    \\OSStatus LSOpenCFURLRef(CFURLRef, CFURLRef*);
    \\void CFRelease(CFTypeRef);
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
;

const cf_stub_impl =
    \\#include <CoreFoundation/CFBundle.h>
    \\const CFAllocatorRef kCFAllocatorDefault = (CFAllocatorRef)0;
    \\CFStringRef CFStringCreateWithCString(CFAllocatorRef a, const char* s, CFStringEncoding e){(void)a;(void)s;(void)e;return (CFStringRef)0;}
    \\Boolean CFStringGetCString(CFStringRef s, char* b, CFIndex n, CFStringEncoding e){(void)s;(void)e;if(b&&n>0)b[0]=0;return 0;}
    \\CFURLRef CFURLCreateWithFileSystemPath(CFAllocatorRef a, CFStringRef s, CFURLPathStyle p, Boolean b){(void)a;(void)s;(void)p;(void)b;return (CFURLRef)0;}
    \\CFBundleRef CFBundleCreate(CFAllocatorRef a, CFURLRef u){(void)a;(void)u;return (CFBundleRef)0;}
    \\CFURLRef CFBundleCopyExecutableURL(CFBundleRef b){(void)b;return (CFURLRef)0;}
    \\Boolean CFURLGetFileSystemRepresentation(CFURLRef u, Boolean r, UInt8* buf, CFIndex n){(void)u;(void)r;(void)buf;(void)n;return 0;}
    \\CFUUIDRef CFUUIDCreate(CFAllocatorRef a){(void)a;return (CFUUIDRef)0;}
    \\CFStringRef CFUUIDCreateString(CFAllocatorRef a, CFUUIDRef u){(void)a;(void)u;return (CFStringRef)0;}
    \\OSStatus LSOpenCFURLRef(CFURLRef u, CFURLRef* o){(void)u;if(o)*o=(CFURLRef)0;return 0;}
    \\void CFRelease(CFTypeRef r){(void)r;}
    \\
;

const makefile_generator_sources = [_][]const u8{
    "cmDepends",
    "cmDependsC",
    "cmDependsCompiler",
    "cmGlobalUnixMakefileGenerator3",
    "cmLocalUnixMakefileGenerator3",
    "cmMakefileExecutableTargetGenerator",
    "cmMakefileLibraryTargetGenerator",
    "cmMakefileTargetGenerator",
    "cmMakefileUtilityTargetGenerator",
    "cmProcessTools",
};

const mingw_cxx_sources = [_][]const u8{
    "cmGlobalMSYSMakefileGenerator",
    "cmGlobalMinGWMakefileGenerator",
    "cmVSSetupHelper",
};

const lexerparser_cxx_sources = [_][]const u8{
    "cmExprLexer",
    "cmExprParser",
    "cmGccDepfileLexer",
};

const libuv_unix_sources = [_][]const u8{
    "src/strscpy.c",
    "src/strtok.c",
    "src/timer.c",
    "src/uv-common.c",
    "src/unix/cmake-bootstrap.c",
    "src/unix/core.c",
    "src/unix/fs.c",
    "src/unix/loop.c",
    "src/unix/loop-watcher.c",
    "src/unix/no-fsevents.c",
    "src/unix/pipe.c",
    "src/unix/poll.c",
    "src/unix/posix-hrtime.c",
    "src/unix/posix-poll.c",
    "src/unix/process.c",
    "src/unix/signal.c",
    "src/unix/stream.c",
    "src/unix/tcp.c",
    "src/unix/tty.c",
};

const libuv_win_sources = [_][]const u8{
    "src/fs-poll.c",
    "src/idna.c",
    "src/inet.c",
    "src/threadpool.c",
    "src/strscpy.c",
    "src/strtok.c",
    "src/timer.c",
    "src/uv-common.c",
    "src/win/async.c",
    "src/win/core.c",
    "src/win/detect-wakeup.c",
    "src/win/dl.c",
    "src/win/error.c",
    "src/win/fs-event.c",
    "src/win/fs.c",
    "src/win/getaddrinfo.c",
    "src/win/getnameinfo.c",
    "src/win/handle.c",
    "src/win/loop-watcher.c",
    "src/win/pipe.c",
    "src/win/poll.c",
    "src/win/process-stdio.c",
    "src/win/process.c",
    "src/win/signal.c",
    "src/win/stream.c",
    "src/win/tcp.c",
    "src/win/thread.c",
    "src/win/tty.c",
    "src/win/udp.c",
    "src/win/util.c",
    "src/win/winapi.c",
    "src/win/winsock.c",
};

const librhash_sources = [_][]const u8{
    "librhash/algorithms.c",
    "librhash/byte_order.c",
    "librhash/hex.c",
    "librhash/md5.c",
    "librhash/rhash.c",
    "librhash/sha1.c",
    "librhash/sha256.c",
    "librhash/sha3.c",
    "librhash/sha512.c",
    "librhash/util.c",
};

const jsoncpp_sources = [_][]const u8{
    "src/lib_json/json_reader.cpp",
    "src/lib_json/json_value.cpp",
    "src/lib_json/json_writer.cpp",
};

const cmake_cxx_sources = [_][]const u8{
    "cmAddCompileDefinitionsCommand",
    "cmAddCustomCommandCommand",
    "cmAddCustomTargetCommand",
    "cmAddDefinitionsCommand",
    "cmAddDependenciesCommand",
    "cmAddExecutableCommand",
    "cmAddLibraryCommand",
    "cmAddSubDirectoryCommand",
    "cmAddTestCommand",
    "cmArgumentParser",
    "cmBinUtilsLinker",
    "cmBinUtilsLinuxELFGetRuntimeDependenciesTool",
    "cmBinUtilsLinuxELFLinker",
    "cmBinUtilsLinuxELFObjdumpGetRuntimeDependenciesTool",
    "cmBinUtilsMacOSMachOGetRuntimeDependenciesTool",
    "cmBinUtilsMacOSMachOLinker",
    "cmBinUtilsMacOSMachOOToolGetRuntimeDependenciesTool",
    "cmBinUtilsWindowsPEGetRuntimeDependenciesTool",
    "cmBinUtilsWindowsPEDumpbinGetRuntimeDependenciesTool",
    "cmBinUtilsWindowsPELinker",
    "cmBinUtilsWindowsPEObjdumpGetRuntimeDependenciesTool",
    "cmBlockCommand",
    "cmBreakCommand",
    "cmBuildCommand",
    "cmBuildDatabase",
    "cmCMakeLanguageCommand",
    "cmCMakeMinimumRequired",
    "cmList",
    "cmCMakeDiagnosticCommand",
    "cmCMakePath",
    "cmCMakePathCommand",
    "cmCMakePolicyCommand",
    "cmCMakeString",
    "cmCPackPropertiesGenerator",
    "cmCacheDocumentationTable",
    "cmCacheManager",
    "cmCachePatternTable",
    "cmCommands",
    "cmCommonTargetGenerator",
    "cmComputeComponentGraph",
    "cmComputeLinkDepends",
    "cmComputeLinkInformation",
    "cmComputeTargetDepends",
    "cmConditionEvaluator",
    "cmConfigureFileCommand",
    "cmContinueCommand",
    "cmCoreTryCompile",
    "cmCreateTestSourceList",
    "cmCryptoHash",
    "cmCustomCommand",
    "cmCustomCommandGenerator",
    "cmCustomCommandLines",
    "cmCxxModuleMapper",
    "cmCxxModuleUsageEffects",
    "cmDefinePropertyCommand",
    "cmDefinitions",
    "cmDiagnostics",
    "cmDiagnosticContext",
    "cmDiscoverTestsCommand",
    "cmDocumentationFormatter",
    "cmELF",
    "cmEnableLanguageCommand",
    "cmEnableTestingCommand",
    "cmEnvironment",
    "cmEvaluatedTargetProperty",
    "cmExecProgramCommand",
    "cmExecuteProcessCommand",
    "cmExpandedCommandArgument",
    "cmExperimental",
    "cmExportBuildCMakeConfigGenerator",
    "cmExportBuildFileGenerator",
    "cmExportCMakeConfigGenerator",
    "cmExportFileGenerator",
    "cmExportInstallCMakeConfigGenerator",
    "cmExportInstallFileGenerator",
    "cmExportSet",
    "cmExportTryCompileFileGenerator",
    "cmExprParserHelper",
    "cmExternalMakefileProjectGenerator",
    "cmFileCommand",
    "cmFileCommand_ReadMacho",
    "cmFileCopier",
    "cmFileInstaller",
    "cmFileSet",
    "cmFileSetMetadata",
    "cmFileTime",
    "cmFileTimeCache",
    "cmFileTimes",
    "cmFindBase",
    "cmFindCommon",
    "cmFindFileCommand",
    "cmFindLibraryCommand",
    "cmFindPackageCommand",
    "cmFindPackageStack",
    "cmFindPathCommand",
    "cmFindProgramCommand",
    "cmForEachCommand",
    "cmFunctionBlocker",
    "cmFunctionCommand",
    "cmFSPermissions",
    "cmGeneratedFileStream",
    "cmGenExContext",
    "cmGenExEvaluation",
    "cmGeneratorExpression",
    "cmGeneratorExpressionDAGChecker",
    "cmGeneratorExpressionEvaluationFile",
    "cmGeneratorExpressionEvaluator",
    "cmGeneratorExpressionLexer",
    "cmGeneratorExpressionNode",
    "cmGeneratorExpressionParser",
    "cmGeneratorFileSet",
    "cmGeneratorFileSets",
    "cmGeneratorTarget",
    "cmGeneratorTarget_CompatibleInterface",
    "cmGeneratorTarget_HeaderSetVerification",
    "cmGeneratorTarget_IncludeDirectories",
    "cmGeneratorTarget_Link",
    "cmGeneratorTarget_LinkDirectories",
    "cmGeneratorTarget_Options",
    "cmGeneratorTarget_Sources",
    "cmGeneratorTarget_TransitiveProperty",
    "cmGetCMakePropertyCommand",
    "cmGetDirectoryPropertyCommand",
    "cmGetFilenameComponentCommand",
    "cmGetPipes",
    "cmGetPropertyCommand",
    "cmGetSourceFilePropertyCommand",
    "cmGetTargetPropertyCommand",
    "cmGetTestPropertyCommand",
    "cmGlobalCommonGenerator",
    "cmGlobalGenerator",
    "cmGlobVerificationManager",
    "cmHexFileConverter",
    "cmIfCommand",
    "cmImportedCxxModuleInfo",
    "cmIncludeCommand",
    "cmIncludeGuardCommand",
    "cmIncludeDirectoryCommand",
    "cmIncludeRegularExpressionCommand",
    "cmInstallCMakeConfigExportGenerator",
    "cmInstallCommand",
    "cmInstallCommandArguments",
    "cmInstallCxxModuleBmiGenerator",
    "cmInstallDirectoryGenerator",
    "cmInstallExportGenerator",
    "cmInstallFileSetGenerator",
    "cmInstallFilesCommand",
    "cmInstallFilesGenerator",
    "cmInstallGenerator",
    "cmInstallGetRuntimeDependenciesGenerator",
    "cmInstallImportedRuntimeArtifactsGenerator",
    "cmInstallDirs",
    "cmInstallRuntimeDependencySet",
    "cmInstallRuntimeDependencySetGenerator",
    "cmInstallScriptGenerator",
    "cmInstallSubdirectoryGenerator",
    "cmInstallTargetGenerator",
    "cmInstallTargetsCommand",
    "cmInstalledFile",
    "cmJSONHelpers",
    "cmJSONState",
    "cmLDConfigLDConfigTool",
    "cmLDConfigTool",
    "cmLinkDirectoriesCommand",
    "cmLinkItem",
    "cmLinkItemGraphVisitor",
    "cmLinkLineComputer",
    "cmLinkLineDeviceComputer",
    "cmListCommand",
    "cmListFileCache",
    "cmLocalCommonGenerator",
    "cmLocalGenerator",
    "cmMSVC60LinkLineComputer",
    "cmMacroCommand",
    "cmMakeDirectoryCommand",
    "cmMakefile",
    "cmMarkAsAdvancedCommand",
    "cmMathCommand",
    "cmMessageCommand",
    "cmMessenger",
    "cmNewLineStyle",
    "cmOSXBundleGenerator",
    "cmOptionCommand",
    "cmOrderDirectories",
    "cmObjectLocation",
    "cmOutputConverter",
    "cmParseArgumentsCommand",
    "cmPathLabel",
    "cmPathResolver",
    "cmPolicies",
    "cmProcessOutput",
    "cmProjectCommand",
    "cmValue",
    "cmPropertyDefinition",
    "cmPropertyMap",
    "cmGccDepfileLexerHelper",
    "cmGccDepfileReader",
    "cmReturnCommand",
    "cmPackageInfoReader",
    "cmPlaceholderExpander",
    "cmPlistParser",
    "cmRulePlaceholderExpander",
    "cmRuntimeDependencyArchive",
    "cmScriptGenerator",
    "cmSearchPath",
    "cmSeparateArgumentsCommand",
    "cmSetCommand",
    "cmSetDirectoryPropertiesCommand",
    "cmSetPropertyCommand",
    "cmSetSourceFilesPropertiesCommand",
    "cmSetTargetPropertiesCommand",
    "cmSetTestsPropertiesCommand",
    "cmSiteNameCommand",
    "cmSourceFile",
    "cmSourceFileLocation",
    "cmStandardLevelResolver",
    "cmState",
    "cmStateDirectory",
    "cmStateSnapshot",
    "cmStdIoConsole",
    "cmStdIoInit",
    "cmStdIoStream",
    "cmStdIoTerminal",
    "cmString",
    "cmStringAlgorithms",
    "cmStringReplaceHelper",
    "cmStringCommand",
    "cmSubcommandTable",
    "cmSubdirCommand",
    "cmSystemTools",
    "cmTarget",
    "cmTargetCompileDefinitionsCommand",
    "cmTargetCompileFeaturesCommand",
    "cmTargetCompileOptionsCommand",
    "cmTargetIncludeDirectoriesCommand",
    "cmTargetLinkLibrariesCommand",
    "cmTargetLinkOptionsCommand",
    "cmTargetPrecompileHeadersCommand",
    "cmTargetPropCommandBase",
    "cmTargetPropertyComputer",
    "cmTargetPropertyEntry",
    "cmTargetSourcesCommand",
    "cmTargetTraceDependencies",
    "cmTest",
    "cmTestGenerator",
    "cmTimestamp",
    "cmTransformDepfile",
    "cmTryCompileCommand",
    "cmTryRunCommand",
    "cmUnsetCommand",
    "cmUVHandlePtr",
    "cmUVProcessChain",
    "cmVersion",
    "cmWhileCommand",
    "cmWindowsRegistry",
    "cmWorkingDirectory",
    "cmXcFramework",
    "cmake",
    "cmakemain",
    "cmcmd",
    "cm_fileno",
};

// ===========================================================================
// FULL build: the complete CMake (no CMAKE_BOOTSTRAP) so the binary behaves
// like a real cmake (--version/--help/docs). Selected with `-Dfull`.
// All third-party code is vendored under Utilities/ — still no system deps.
// ===========================================================================

const Macro = [2][]const u8;

/// Build one vendored C library as a static archive.
fn cLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root: std.Build.LazyPath,
    files: []const []const u8,
    includes: []const std.Build.LazyPath,
    macros: []const Macro,
) *std.Build.Step.Compile {
    const m = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    for (includes) |inc| m.addIncludePath(inc);
    for (macros) |kv| m.addCMacro(kv[0], kv[1]);
    m.addCSourceFiles(.{ .root = root, .files = files, .flags = &.{} });
    return b.addLibrary(.{ .name = name, .root_module = m, .linkage = .static });
}

fn buildFull(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep: *std.Build.Dependency,
) void {
    const os = target.result.os.tag;
    const is_windows = os == .windows;
    const is_darwin = os.isDarwin();

    // ---- Generated headers (cmsys/, cmConfigure.h, cmVersionConfig.h, ...) --
    const gen = b.addWriteFiles();
    const kwsys_values = .{
        .KWSYS_NAMESPACE = "cmsys",
        .KWSYS_NAME_IS_KWSYS = 0,
        .KWSYS_BUILD_SHARED = 0,
        .KWSYS_CXX_HAS_EXT_STDIO_FILEBUF_H = 0,
    };
    for ([_][]const u8{
        "Configure.h",   "Configure.hxx",        "Directory.hxx",
        "Encoding.h",    "Encoding.hxx",         "FStream.hxx",
        "Glob.hxx",      "Process.h",            "RegularExpression.hxx",
        "Status.hxx",    "String.h",             "System.h",
        "SystemTools.hxx", "SystemInformation.hxx",
    }) |h| {
        const ch = b.addConfigHeader(
            .{ .style = .{ .cmake = dep.path(b.fmt("Source/kwsys/{s}.in", .{h})) }, .include_path = h },
            kwsys_values,
        );
        _ = gen.addCopyFile(ch.getOutputFile(), b.fmt("cmsys/{s}", .{h}));
    }
    _ = gen.add("cmVersionConfig.h",
        \\#define CMake_VERSION_MAJOR 4
        \\#define CMake_VERSION_MINOR 3
        \\#define CMake_VERSION_PATCH 20260530
        \\#define CMake_VERSION_SUFFIX ""
        \\#define CMake_VERSION_IS_DIRTY 0
        \\#define CMake_VERSION "4.3.20260530"
        \\
    );
    _ = gen.add("cmThirdParty.h", "#pragma once\n");
    _ = gen.add("cmSTL.hxx", "#pragma once\n");

    // cmConfigure.h from the real template.
    const cmcfg = b.addConfigHeader(
        .{ .style = .{ .cmake = dep.path("Source/cmConfigure.cmake.h.in") }, .include_path = "cmConfigure.h" },
        .{},
    );
    cmcfg.addValue("CMake_DEFAULT_RECURSION_LIMIT", i64, 400);
    cmcfg.addValue("CMAKE_BIN_DIR", []const u8, "bin");
    cmcfg.addValue("CMAKE_DATA_DIR", []const u8, "share/cmake-4.3");
    cmcfg.addValue("CMAKE_DOC_DIR", []const u8, "doc/cmake-4.3");
    if (!is_windows) cmcfg.addValue("HAVE_UNSETENV", void, {}); // mingw lacks unsetenv (uses _putenv)
    if (!is_windows) cmcfg.addValue("HAVE_ENVIRON_NOT_REQUIRE_PROTOTYPE", void, {});
    if (is_darwin) {
        cmcfg.addValue("CMake_USE_MACH_PARSER", void, {});
        cmcfg.addValue("CMake_STAT_HAS_ST_MTIMESPEC", i64, 1);
        cmcfg.addValue("CMake_STAT_HAS_ST_MTIM", i64, 0);
    } else {
        cmcfg.addValue("CMake_STAT_HAS_ST_MTIM", i64, if (is_windows) 0 else 1);
        cmcfg.addValue("CMake_STAT_HAS_ST_MTIMESPEC", i64, 0);
    }
    // These appear as `@VAR@` even on disabled `#cmakedefine` lines; the cmake
    // renderer expands every `@VAR@` regardless, so they must carry a value.
    // `.undef` (null) expands to nothing and leaves the macro undefined.
    cmcfg.addValue("CURL_CA_BUNDLE", @TypeOf(null), null);
    cmcfg.addValue("CURL_CA_PATH", @TypeOf(null), null);
    if (is_windows) {
        cmcfg.addValue("KWSYS_ENCODING_DEFAULT_CODEPAGE", @TypeOf(.CP_UTF8), .CP_UTF8);
    } else {
        cmcfg.addValue("KWSYS_ENCODING_DEFAULT_CODEPAGE", @TypeOf(null), null);
    }
    _ = gen.addCopyFile(cmcfg.getOutputFile(), "cmConfigure.h");

    // ---- Third-party static libraries -------------------------------------
    const U = struct {
        fn p(d: *std.Build.Dependency, sub: []const u8) std.Build.LazyPath {
            return d.path(sub);
        }
    };

    // zlib (no config header needed).
    const zlib = cLib(b, target, optimize, "cmzlib", U.p(dep, "Utilities/cmzlib"), &zlib_sources, &.{U.p(dep, "Utilities/cmzlib")}, &.{
        .{ "HAVE_STDARG_H", "1" },
    });

    // bzip2 (library sources only — standalone tools/tests excluded).
    const bzip2 = cLib(b, target, optimize, "cmbzip2", U.p(dep, "Utilities/cmbzip2"), &bzip2_sources, &.{U.p(dep, "Utilities/cmbzip2")}, &.{});

    // zstd (single-threaded, asm disabled).
    const zstd = cLib(b, target, optimize, "cmzstd", U.p(dep, "Utilities/cmzstd"), &zstd_sources, &.{
        U.p(dep, "Utilities/cmzstd/lib"),
        U.p(dep, "Utilities/cmzstd/lib/common"),
    }, &.{
        .{ "ZSTD_DISABLE_ASM", "1" },
    });

    // expat (needs expat_config.h).
    const expat_cfg = b.addConfigHeader(
        .{ .style = .{ .cmake = dep.path("Utilities/cmexpat/expat_config.h.cmake") }, .include_path = "expat_config.h" },
        .{},
    );
    expat_cfg.addValue("STDC_HEADERS", void, {});
    expat_cfg.addValue("HAVE_STDINT_H", void, {});
    expat_cfg.addValue("HAVE_STRING_H", void, {});
    expat_cfg.addValue("HAVE_STDLIB_H", void, {});
    expat_cfg.addValue("HAVE_SYS_TYPES_H", void, {});
    expat_cfg.addValue("HAVE_MEMORY_H", void, {});
    expat_cfg.addValue("XML_GE", i64, 1);
    expat_cfg.addValue("XML_CONTEXT_BYTES", i64, 1024);
    expat_cfg.addValue("XML_DTD", void, {});
    expat_cfg.addValue("XML_NS", void, {});
    expat_cfg.addValue("BYTEORDER", i64, 1234);
    if (!is_windows) {
        expat_cfg.addValue("HAVE_UNISTD_H", void, {});
        expat_cfg.addValue("HAVE_FCNTL_H", void, {});
        expat_cfg.addValue("HAVE_DLFCN_H", void, {});
        expat_cfg.addValue("XML_DEV_URANDOM", void, {});
        // arc4random_buf exists on macOS/BSD but not on musl; Linux falls back
        // to /dev/urandom via XML_DEV_URANDOM.
        if (is_darwin) expat_cfg.addValue("HAVE_ARC4RANDOM_BUF", void, {});
    }
    const expat = cLib(b, target, optimize, "cmexpat", U.p(dep, "Utilities/cmexpat/lib"), &.{
        "xmlparse.c", "xmlrole.c", "xmltok.c",
    }, &.{
        U.p(dep, "Utilities/cmexpat/lib"),
        expat_cfg.getOutputDir(),
        U.p(dep, "Utilities"), // <cm3p/kwiml/int.h>, <KWIML/include/...>
        gen.getDirectory(), // cmThirdParty.h
    }, &.{
        .{ "HAVE_EXPAT_CONFIG_H", "1" },
    });

    // cmllpkgc — tiny pkg-config grammar parser used by cmPkgConfigParser.
    const llpkgc = cLib(b, target, optimize, "cmllpkgc", U.p(dep, "Utilities/cmllpkgc"), &.{
        "llpkgc.c", "llpkgc__internal.c",
    }, &.{
        U.p(dep, "Utilities/cmllpkgc"),
        U.p(dep, "Utilities"),
    }, &.{});

    // curl — no TLS / HTTP2 / SSH; just enough for file(DOWNLOAD).
    const curl_cfg = b.addConfigHeader(
        .{ .style = .{ .cmake = dep.path("Utilities/cmcurl/lib/curl_config-cmake.h.in") }, .include_path = "curl_config.h" },
        .{},
    );
    addCurlConfig(curl_cfg, os);
    // curl_setup.h gates the whole winsock block (USE_WINSOCK, sread/swrite,
    // socket support) behind `#ifdef HAVE_WINSOCK2_H` — a macro the cmake config
    // template never emits. Supply it (and ws2tcpip) directly on Windows so curl
    // uses winsock instead of the POSIX socket layer.
    var curl_macros = std.array_list.Managed(Macro).init(b.allocator);
    curl_macros.appendSlice(&.{
        .{ "HAVE_CONFIG_H", "1" },
        .{ "BUILDING_LIBCURL", "1" },
        .{ "CURL_STATICLIB", "1" },
    }) catch @panic("OOM");
    if (is_windows) curl_macros.appendSlice(&.{
        .{ "HAVE_WINDOWS_H", "1" },
        .{ "HAVE_WINSOCK2_H", "1" },
        .{ "HAVE_WS2TCPIP_H", "1" },
        // recv()/send() winsock signatures: int recv(SOCKET, char*, int, int),
        // int send(SOCKET, const char*, int, int). curl's sread/swrite macros
        // expand to these casts; the cmake template doesn't carry them, so the
        // curl build (and curl's own CMake) supplies them as compile defs.
        .{ "RECV_TYPE_ARG1", "SOCKET" },
        .{ "RECV_TYPE_ARG2", "char *" },
        .{ "RECV_TYPE_ARG3", "int" },
        .{ "RECV_TYPE_ARG4", "int" },
        .{ "RECV_TYPE_RETV", "int" },
        .{ "SEND_TYPE_ARG1", "SOCKET" },
        .{ "SEND_TYPE_ARG2", "char *" },
        .{ "SEND_QUAL_ARG2", "const" },
        .{ "SEND_TYPE_ARG3", "int" },
        .{ "SEND_TYPE_ARG4", "int" },
        .{ "SEND_TYPE_RETV", "int" },
    }) catch @panic("OOM");
    var curl_incs = std.array_list.Managed(std.Build.LazyPath).init(b.allocator);
    if (is_windows) {
        // Shadow curl's public <curl/stdcheaders.h>: it forward-declares
        // strcasecmp/strncasecmp, which mingw's <string.h> macro-maps to
        // _stricmp/_strnicmp, clashing with their dllimport decls. curl.h pulls
        // it via `#include "curl/stdcheaders.h"` (resolved through the -I path),
        // so a dir placed *before* cmcurl/include with a minimal replacement
        // wins. fread/fwrite come from <stdio.h>; the str*cmp decls are dropped.
        const sh = b.addWriteFiles();
        _ = sh.add("curl/stdcheaders.h",
            \\#ifndef CURLINC_STDCHEADERS_H
            \\#define CURLINC_STDCHEADERS_H
            \\#include <sys/types.h>
            \\#include <stdio.h>
            \\#endif
            \\
        );
        curl_incs.append(sh.getDirectory()) catch @panic("OOM");
    }
    curl_incs.appendSlice(&.{
        curl_cfg.getOutputDir(),
        U.p(dep, "Utilities/cmcurl/lib"),
        U.p(dep, "Utilities/cmcurl/include"),
        U.p(dep, "Utilities/cmzlib"),
        U.p(dep, "Utilities"),
        gen.getDirectory(),
    }) catch @panic("OOM");
    const curl = cLib(b, target, optimize, "cmcurl", U.p(dep, "Utilities/cmcurl"), &curl_sources, curl_incs.items, curl_macros.items);

    // libarchive — common archive formats backed by zlib/bzip2/zstd.
    const la_cfg = b.addConfigHeader(
        .{ .style = .{ .cmake = dep.path("Utilities/cmlibarchive/build/cmake/config.h.in") }, .include_path = "config.h" },
        .{},
    );
    addLibarchiveConfig(la_cfg, os);
    // NOTE: keep archive_read_support_filter_program.c on ALL targets — it
    // defines __archive_read_program, referenced by the xz/lzma/lzip/lz4 read
    // filters as their external-command fallback. On Windows it compiles via
    // filter_fork_windows.c (HAVE_SYS_WAIT_H/HAVE_WORKING_FORK are off there).
    const libarchive = cLib(b, target, optimize, "cmarchive", U.p(dep, "Utilities/cmlibarchive"), &libarchive_sources, &.{
        la_cfg.getOutputDir(),
        U.p(dep, "Utilities/cmlibarchive/libarchive"),
        U.p(dep, "Utilities/cmzlib"),
        U.p(dep, "Utilities/cmbzip2"),
        U.p(dep, "Utilities/cmzstd/lib"),
        U.p(dep, "Utilities"),
        gen.getDirectory(),
    }, &.{
        .{ "HAVE_CONFIG_H", "1" },
    });

    // ---- The cmake executable module --------------------------------------
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    mod.addCMacro("CMake_HAVE_CXX_MAKE_UNIQUE", "1");
    mod.addCMacro("CMake_HAVE_CXX_FILESYSTEM", "1");
    mod.addCMacro("KWSYS_NAMESPACE", "cmsys");
    mod.addCMacro("KWSYS_STRING_C", "");
    const yes = "1";
    const no = "0";
    mod.addCMacro("KWSYS_CXX_HAS_SETENV", if (is_windows) no else yes);
    mod.addCMacro("KWSYS_CXX_HAS_UNSETENV", if (is_windows) no else yes);
    mod.addCMacro("KWSYS_CXX_HAS_ENVIRON_IN_STDLIB_H", if (is_windows) yes else no);
    mod.addCMacro("KWSYS_CXX_HAS_UTIMENSAT", if (is_windows) no else yes);
    mod.addCMacro("KWSYS_CXX_HAS_UTIMES", if (is_windows) no else yes);
    if (os == .linux) {
        mod.addCMacro("_FILE_OFFSET_BITS", "64");
        mod.addCMacro("_TIME_BITS", "64");
        // NB: do not define _GNU_SOURCE here — libuv's sources define it
        // themselves and a duplicate command-line define is a hard error.
    } else if (is_darwin) {
        mod.addCMacro("_DARWIN_USE_64_BIT_INODE", "1");
    } else if (is_windows) {
        mod.addCMacro("KWSYS_ENCODING_DEFAULT_CODEPAGE", "CP_UTF8");
        // cmCurl.cxx includes <curl/curl.h>; curl is a STATIC lib, so the
        // consumer TU must define CURL_STATICLIB too — otherwise curl.h marks
        // curl_* as __declspec(dllimport) and linking fails.
        mod.addCMacro("CURL_STATICLIB", "1");
    }

    // Include search paths.
    mod.addIncludePath(gen.getDirectory());
    mod.addIncludePath(dep.path("Source"));
    mod.addIncludePath(dep.path("Source/LexerParser"));
    mod.addIncludePath(dep.path("Utilities"));
    mod.addIncludePath(dep.path("Utilities/std"));
    mod.addIncludePath(dep.path("Utilities/cmjsoncpp/include"));
    mod.addIncludePath(dep.path("Utilities/cmcurl/include"));
    mod.addIncludePath(dep.path("Utilities/cmzlib"));
    mod.addIncludePath(dep.path("Utilities/cmzstd/lib"));
    mod.addIncludePath(dep.path("Utilities/cmbzip2"));
    mod.addIncludePath(dep.path("Utilities/cmexpat/lib"));
    mod.addIncludePath(dep.path("Utilities/cmlibarchive/libarchive"));
    mod.addIncludePath(dep.path("Utilities/cmliblzma/liblzma/api"));
    mod.addIncludePath(dep.path("Utilities/cmnghttp2/lib/includes"));

    // Frameworkless macOS: cmFindProgramCommand AND cmGlobalXCodeGenerator pull in
    // CoreFoundation/LaunchServices under `#if __APPLE__`. Satisfy them with no-op
    // stub headers + impls (same approach as the bootstrap build).
    if (is_darwin) {
        const cf = b.addWriteFiles();
        _ = cf.add("CoreFoundation/CFBundle.h", cf_stub_header);
        _ = cf.add("CoreFoundation/CFString.h", "#pragma once\n#include <CoreFoundation/CFBundle.h>\n");
        _ = cf.add("CoreFoundation/CFURL.h", "#pragma once\n#include <CoreFoundation/CFBundle.h>\n");
        _ = cf.add("CoreFoundation/CFUUID.h", "#pragma once\n#include <CoreFoundation/CFBundle.h>\n");
        // cmGlobalXCodeGenerator.cxx includes <ApplicationServices/ApplicationServices.h>
        // for LSOpenCFURLRef; our CFBundle stub already declares it.
        _ = cf.add("ApplicationServices/ApplicationServices.h", "#pragma once\n#include <CoreFoundation/CFBundle.h>\n");
        _ = cf.add("cf_stub.c", cf_stub_impl);
        mod.addIncludePath(cf.getDirectory());
        mod.addCSourceFiles(.{ .root = cf.getDirectory(), .files = &.{"cf_stub.c"}, .flags = &.{} });
    }

    const cxx_flags = [_][]const u8{ "-std=c++17", "-Wno-deprecated-literal-operator" };

    // C++ sources: full CMakeLib list.
    var cxx = std.array_list.Managed([]const u8).init(b.allocator);
    cxx.appendSlice(&cmakelib_full_sources) catch @panic("OOM");
    cxx.appendSlice(&.{ "cmakemain.cxx", "cmcmd.cxx" }) catch @panic("OOM");
    cxx.appendSlice(&full_wmake_sources) catch @panic("OOM"); // WIN32|Linux|Darwin
    if (is_darwin) cxx.appendSlice(&full_apple_sources) catch @panic("OOM");
    if (os == .linux or is_windows) cxx.appendSlice(&full_ghs_sources) catch @panic("OOM");
    if (is_windows) cxx.appendSlice(&full_win_sources) catch @panic("OOM");
    mod.addCSourceFiles(.{ .root = dep.path("Source"), .files = cxx.items, .flags = &cxx_flags });

    // kwsys + std shims + jsoncpp + librhash + libuv reuse bootstrap layout.
    mod.addCSourceFiles(.{ .root = dep.path("Source/kwsys"), .files = &.{
        "Directory.cxx", "EncodingCXX.cxx", "FStream.cxx", "Glob.cxx",
        "RegularExpression.cxx", "Status.cxx", "SystemTools.cxx", "SystemInformation.cxx",
    }, .flags = &cxx_flags });
    mod.addCSourceFiles(.{ .root = dep.path("Source/kwsys"), .files = &.{
        "EncodingC.c", if (is_windows) "ProcessWin32.c" else "ProcessUNIX.c", "System.c", "String.c",
    }, .flags = &.{} });
    mod.addCSourceFiles(.{ .root = dep.path("Utilities/std/cm/bits"), .files = &.{ "fs_path.cxx", "string_view.cxx" }, .flags = &cxx_flags });
    mod.addCSourceFiles(.{ .root = dep.path("Utilities/cmjsoncpp"), .files = &jsoncpp_sources, .flags = &cxx_flags });
    mod.addCSourceFiles(.{ .root = dep.path("Utilities/cmlibrhash"), .files = &librhash_sources, .flags = &.{"-DNO_IMPORT_EXPORT"} });
    // C sources that live in Source/ (not in the .cxx list).
    mod.addCSourceFiles(.{ .root = dep.path("Source"), .files = &.{ "cm_utf8.c", "cm_parse_date.c" }, .flags = &.{} });
    mod.addCSourceFiles(.{ .root = dep.path("Source/LexerParser"), .files = &.{"cmListFileLexer.c"}, .flags = &.{} });

    // libuv as a proper static library with the real backend (epoll/kqueue/
    // threads) — not the bootstrap posix-poll stub.
    var uv_files = std.array_list.Managed([]const u8).init(b.allocator);
    var uv_incs = std.array_list.Managed(std.Build.LazyPath).init(b.allocator);
    var uv_macros = std.array_list.Managed(Macro).init(b.allocator);
    uv_files.appendSlice(&libuv_full_common) catch @panic("OOM");
    uv_incs.appendSlice(&.{ dep.path("Utilities/cmlibuv/include"), dep.path("Utilities/cmlibuv/src") }) catch @panic("OOM");
    if (is_windows) {
        uv_files.appendSlice(&libuv_full_win) catch @panic("OOM");
        uv_incs.append(dep.path("Utilities/cmlibuv/src/win")) catch @panic("OOM");
        uv_macros.append(.{ "WIN32_LEAN_AND_MEAN", "" }) catch @panic("OOM");
    } else {
        uv_files.appendSlice(&libuv_full_unix) catch @panic("OOM");
        uv_incs.append(dep.path("Utilities/cmlibuv/src/unix")) catch @panic("OOM");
        if (os == .linux) {
            uv_files.appendSlice(&libuv_full_linux) catch @panic("OOM");
            // glibc/musl gate cpu_set_t, sched_getaffinity, sendmmsg, etc.
            // behind _GNU_SOURCE. Use "1" to match the toolchain's own
            // definition and avoid a "macro redefined" error.
            uv_macros.append(.{ "_GNU_SOURCE", "1" }) catch @panic("OOM");
        }
        if (is_darwin) {
            uv_files.appendSlice(&libuv_full_darwin) catch @panic("OOM");
            uv_macros.appendSlice(&.{ .{ "_DARWIN_USE_64_BIT_INODE", "1" }, .{ "_DARWIN_UNLIMITED_SELECT", "1" } }) catch @panic("OOM");
        }
    }
    const libuv = cLib(b, target, optimize, "cmuv", dep.path("Utilities/cmlibuv"), uv_files.items, uv_incs.items, uv_macros.items);
    mod.addIncludePath(dep.path("Utilities/cmlibuv/include"));

    const exe = b.addExecutable(.{ .name = "cmake", .root_module = mod });
    mod.linkLibrary(zlib);
    mod.linkLibrary(bzip2);
    mod.linkLibrary(zstd);
    mod.linkLibrary(expat);
    mod.linkLibrary(llpkgc);
    mod.linkLibrary(curl);
    mod.linkLibrary(libarchive);
    mod.linkLibrary(libuv);

    // Platform system libraries.
    if (is_windows) {
        for ([_][]const u8{
            "advapi32", "dbghelp", "iphlpapi", "ole32",   "oleaut32",
            "psapi",    "shell32", "user32",   "userenv", "uuid",
            "ws2_32",   "rpcrt4",  "crypt32",
            // bcrypt: curl rand.c BCryptGenRandom; powrprof: kwsys
            // SystemInformation CallNtPowerInformation; kernel32: libuv util.c
            // GetUserDefaultLocaleName.
            "bcrypt",   "powrprof", "kernel32",
        }) |l| mod.linkSystemLibrary(l, .{});
    } else if (os == .linux) {
        if (target.result.abi != .musl) {
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("rt", .{});
        }
    }

    b.installArtifact(exe);

    // ---- Install CMAKE_ROOT data files (Modules/, Templates/) ----------------
    // cmake resolves CMAKE_ROOT relative to the executable: <prefix>/share/cmake-4.3.
    // Without these the binary runs but warns "Could not find CMAKE_ROOT".
    inline for ([_][]const u8{ "Modules", "Templates" }) |d| {
        b.installDirectory(.{
            .source_dir = dep.path(d),
            .install_dir = .prefix,
            .install_subdir = "share/cmake-4.3/" ++ d,
        });
    }
}

const full_wmake_sources = [_][]const u8{
    "cmGlobalWatcomWMakeGenerator.cxx",
};

const full_ghs_sources = [_][]const u8{
    "cmGlobalGhsMultiGenerator.cxx",
    "cmLocalGhsMultiGenerator.cxx",
    "cmGhsMultiTargetGenerator.cxx",
    "cmGhsMultiGpj.cxx",
};

const full_apple_sources = [_][]const u8{
    "cmMachO.cxx",
    "cmXCodeObject.cxx",
    "cmXCode21Object.cxx",
    "cmXCodeScheme.cxx",
    "cmGlobalXCodeGenerator.cxx",
    "cmLocalXCodeGenerator.cxx",
};

const full_win_sources = [_][]const u8{
    "cmCallVisualStudioMacro.cxx",
    "cmGlobalBorlandMakefileGenerator.cxx",
    "cmGlobalMSYSMakefileGenerator.cxx",
    "cmGlobalMinGWMakefileGenerator.cxx",
    "cmGlobalNMakeMakefileGenerator.cxx",
    "cmGlobalJOMMakefileGenerator.cxx",
    "cmGlobalVisualStudio7Generator.cxx",
    "cmGlobalVisualStudio8Generator.cxx",
    "cmVisualStudioGeneratorOptions.cxx",
    "cmVisualStudio10TargetGenerator.cxx",
    "cmLocalVisualStudio10Generator.cxx",
    "cmGlobalVisualStudio10Generator.cxx",
    "cmGlobalVisualStudio11Generator.cxx",
    "cmGlobalVisualStudio12Generator.cxx",
    "cmGlobalVisualStudio14Generator.cxx",
    "cmGlobalVisualStudioGenerator.cxx",
    "cmGlobalVisualStudioVersionedGenerator.cxx",
    "cmIDEOptions.cxx",
    "cmLocalVisualStudio7Generator.cxx",
    "cmLocalVisualStudioGenerator.cxx",
    "cmVisualStudioSlnData.cxx",
    "cmVisualStudioSlnParser.cxx",
    "cmVisualStudioWCEPlatformParser.cxx",
    "cmVSSetupHelper.cxx",
    "cmVSSolution.cxx",
};

const cmakelib_full_sources = [_][]const u8{
    "LexerParser/cmDependsJavaLexer.cxx",
    "LexerParser/cmDependsJavaParser.cxx",
    "LexerParser/cmExprLexer.cxx",
    "LexerParser/cmExprParser.cxx",
    "LexerParser/cmFortranLexer.cxx",
    "LexerParser/cmFortranParser.cxx",
    "LexerParser/cmGccDepfileLexer.cxx",
    "bindexplib.cxx",
    "cmAddCompileDefinitionsCommand.cxx",
    "cmAddCompileOptionsCommand.cxx",
    "cmAddCustomCommandCommand.cxx",
    "cmAddCustomTargetCommand.cxx",
    "cmAddDefinitionsCommand.cxx",
    "cmAddDependenciesCommand.cxx",
    "cmAddExecutableCommand.cxx",
    "cmAddLibraryCommand.cxx",
    "cmAddLinkOptionsCommand.cxx",
    "cmAddSubDirectoryCommand.cxx",
    "cmAddTestCommand.cxx",
    "cmAffinity.cxx",
    "cmArchiveWrite.cxx",
    "cmArgumentParser.cxx",
    "cmAuxSourceDirectoryCommand.cxx",
    "cmBase32.cxx",
    "cmBinUtilsLinker.cxx",
    "cmBinUtilsLinuxELFGetRuntimeDependenciesTool.cxx",
    "cmBinUtilsLinuxELFLinker.cxx",
    "cmBinUtilsLinuxELFObjdumpGetRuntimeDependenciesTool.cxx",
    "cmBinUtilsMacOSMachOGetRuntimeDependenciesTool.cxx",
    "cmBinUtilsMacOSMachOLinker.cxx",
    "cmBinUtilsMacOSMachOOToolGetRuntimeDependenciesTool.cxx",
    "cmBinUtilsWindowsPEDumpbinGetRuntimeDependenciesTool.cxx",
    "cmBinUtilsWindowsPEGetRuntimeDependenciesTool.cxx",
    "cmBinUtilsWindowsPELinker.cxx",
    "cmBinUtilsWindowsPEObjdumpGetRuntimeDependenciesTool.cxx",
    "cmBlockCommand.cxx",
    "cmBreakCommand.cxx",
    "cmBuildCommand.cxx",
    "cmBuildDatabase.cxx",
    "cmCLocaleEnvironmentScope.cxx",
    "cmCMakeDiagnosticCommand.cxx",
    "cmCMakeHostSystemInformationCommand.cxx",
    "cmCMakeLanguageCommand.cxx",
    "cmCMakeMinimumRequired.cxx",
    "cmCMakePath.cxx",
    "cmCMakePathCommand.cxx",
    "cmCMakePkgConfigCommand.cxx",
    "cmCMakePolicyCommand.cxx",
    "cmCMakePresetsErrors.cxx",
    "cmCMakePresetsGraph.cxx",
    "cmCMakePresetsGraphReadJSON.cxx",
    "cmCMakePresetsGraphReadJSONBuildPresets.cxx",
    "cmCMakePresetsGraphReadJSONConfigurePresets.cxx",
    "cmCMakePresetsGraphReadJSONPackagePresets.cxx",
    "cmCMakePresetsGraphReadJSONTestPresets.cxx",
    "cmCMakePresetsGraphReadJSONWorkflowPresets.cxx",
    "cmCMakePresetsGraphResolve.cxx",
    "cmCMakeString.cxx",
    "cmCPackPropertiesGenerator.cxx",
    "cmCacheDocumentationTable.cxx",
    "cmCacheManager.cxx",
    "cmCachePatternTable.cxx",
    "cmCommands.cxx",
    "cmCommonTargetGenerator.cxx",
    "cmComputeComponentGraph.cxx",
    "cmComputeLinkDepends.cxx",
    "cmComputeLinkInformation.cxx",
    "cmComputeTargetDepends.cxx",
    "cmConditionEvaluator.cxx",
    "cmConfigureFileCommand.cxx",
    "cmConfigureLog.cxx",
    "cmContinueCommand.cxx",
    "cmCoreTryCompile.cxx",
    "cmCreateTestSourceList.cxx",
    "cmCryptoHash.cxx",
    "cmCurl.cxx",
    "cmCustomCommand.cxx",
    "cmCustomCommandGenerator.cxx",
    "cmCustomCommandLines.cxx",
    "cmCxxModuleMapper.cxx",
    "cmCxxModuleMetadata.cxx",
    "cmCxxModuleUsageEffects.cxx",
    "cmDefinePropertyCommand.cxx",
    "cmDefinitions.cxx",
    "cmDepends.cxx",
    "cmDependsC.cxx",
    "cmDependsCompiler.cxx",
    "cmDependsFortran.cxx",
    "cmDependsJava.cxx",
    "cmDependsJavaParserHelper.cxx",
    "cmDiagnosticContext.cxx",
    "cmDiagnostics.cxx",
    "cmDiscoverTestsCommand.cxx",
    "cmDocumentation.cxx",
    "cmDocumentationFormatter.cxx",
    "cmDuration.cxx",
    "cmDyndepCollation.cxx",
    "cmELF.cxx",
    "cmEnableLanguageCommand.cxx",
    "cmEnableTestingCommand.cxx",
    "cmEnvironment.cxx",
    "cmEvaluatedTargetProperty.cxx",
    "cmExecProgramCommand.cxx",
    "cmExecuteProcessCommand.cxx",
    "cmExpandedCommandArgument.cxx",
    "cmExperimental.cxx",
    "cmExportAndroidMKGenerator.cxx",
    "cmExportBuildAndroidMKGenerator.cxx",
    "cmExportBuildCMakeConfigGenerator.cxx",
    "cmExportBuildFileGenerator.cxx",
    "cmExportBuildPackageInfoGenerator.cxx",
    "cmExportBuildSbomGenerator.cxx",
    "cmExportCMakeConfigGenerator.cxx",
    "cmExportCommand.cxx",
    "cmExportFileGenerator.cxx",
    "cmExportInstallAndroidMKGenerator.cxx",
    "cmExportInstallCMakeConfigGenerator.cxx",
    "cmExportInstallFileGenerator.cxx",
    "cmExportInstallPackageInfoGenerator.cxx",
    "cmExportInstallSbomGenerator.cxx",
    "cmExportPackageInfoGenerator.cxx",
    "cmExportSbomGenerator.cxx",
    "cmExportSet.cxx",
    "cmExportTryCompileFileGenerator.cxx",
    "cmExprParserHelper.cxx",
    "cmExternalMakefileProjectGenerator.cxx",
    "cmExtraCodeBlocksGenerator.cxx",
    "cmExtraCodeLiteGenerator.cxx",
    "cmExtraEclipseCDT4Generator.cxx",
    "cmExtraKateGenerator.cxx",
    "cmExtraSublimeTextGenerator.cxx",
    "cmFLTKWrapUICommand.cxx",
    "cmFSPermissions.cxx",
    "cmFastbuildLinkLineComputer.cxx",
    "cmFastbuildNormalTargetGenerator.cxx",
    "cmFastbuildTargetGenerator.cxx",
    "cmFastbuildUtilityTargetGenerator.cxx",
    "cmFileAPI.cxx",
    "cmFileAPICMakeFiles.cxx",
    "cmFileAPICache.cxx",
    "cmFileAPICodemodel.cxx",
    "cmFileAPICommand.cxx",
    "cmFileAPIConfigureLog.cxx",
    "cmFileAPIToolchains.cxx",
    "cmFileCommand.cxx",
    "cmFileCommand_ReadMacho.cxx",
    "cmFileCopier.cxx",
    "cmFileInstaller.cxx",
    "cmFileLock.cxx",
    "cmFileLockPool.cxx",
    "cmFileLockResult.cxx",
    "cmFilePathChecksum.cxx",
    "cmFileSet.cxx",
    "cmFileSetMetadata.cxx",
    "cmFileTime.cxx",
    "cmFileTimeCache.cxx",
    "cmFileTimes.cxx",
    "cmFindBase.cxx",
    "cmFindCommon.cxx",
    "cmFindFileCommand.cxx",
    "cmFindLibraryCommand.cxx",
    "cmFindPackageCommand.cxx",
    "cmFindPackageStack.cxx",
    "cmFindPathCommand.cxx",
    "cmFindProgramCommand.cxx",
    "cmForEachCommand.cxx",
    "cmFortranParserImpl.cxx",
    "cmFunctionBlocker.cxx",
    "cmFunctionCommand.cxx",
    "cmGccDepfileLexerHelper.cxx",
    "cmGccDepfileReader.cxx",
    "cmGenExContext.cxx",
    "cmGenExEvaluation.cxx",
    "cmGeneratedFileStream.cxx",
    "cmGeneratorExpression.cxx",
    "cmGeneratorExpressionDAGChecker.cxx",
    "cmGeneratorExpressionEvaluationFile.cxx",
    "cmGeneratorExpressionEvaluator.cxx",
    "cmGeneratorExpressionLexer.cxx",
    "cmGeneratorExpressionNode.cxx",
    "cmGeneratorExpressionParser.cxx",
    "cmGeneratorFileSet.cxx",
    "cmGeneratorFileSets.cxx",
    "cmGeneratorTarget.cxx",
    "cmGeneratorTarget_CompatibleInterface.cxx",
    "cmGeneratorTarget_HeaderSetVerification.cxx",
    "cmGeneratorTarget_IncludeDirectories.cxx",
    "cmGeneratorTarget_Link.cxx",
    "cmGeneratorTarget_LinkDirectories.cxx",
    "cmGeneratorTarget_Options.cxx",
    "cmGeneratorTarget_Sources.cxx",
    "cmGeneratorTarget_TransitiveProperty.cxx",
    "cmGetCMakePropertyCommand.cxx",
    "cmGetDirectoryPropertyCommand.cxx",
    "cmGetFilenameComponentCommand.cxx",
    "cmGetPipes.cxx",
    "cmGetPropertyCommand.cxx",
    "cmGetSourceFilePropertyCommand.cxx",
    "cmGetTargetPropertyCommand.cxx",
    "cmGetTestPropertyCommand.cxx",
    "cmGlobVerificationManager.cxx",
    "cmGlobalCommonGenerator.cxx",
    "cmGlobalFastbuildGenerator.cxx",
    "cmGlobalGenerator.cxx",
    "cmGlobalNinjaGenerator.cxx",
    "cmGlobalUnixMakefileGenerator3.cxx",
    "cmGraphVizWriter.cxx",
    "cmHexFileConverter.cxx",
    "cmIfCommand.cxx",
    "cmImportedCxxModuleInfo.cxx",
    "cmIncludeCommand.cxx",
    "cmIncludeDirectoryCommand.cxx",
    "cmIncludeExternalMSProjectCommand.cxx",
    "cmIncludeGuardCommand.cxx",
    "cmIncludeRegularExpressionCommand.cxx",
    "cmInstallAndroidMKExportGenerator.cxx",
    "cmInstallCMakeConfigExportGenerator.cxx",
    "cmInstallCommand.cxx",
    "cmInstallCommandArguments.cxx",
    "cmInstallCxxModuleBmiGenerator.cxx",
    "cmInstallDirectoryGenerator.cxx",
    "cmInstallDirs.cxx",
    "cmInstallExportGenerator.cxx",
    "cmInstallFileSetGenerator.cxx",
    "cmInstallFilesCommand.cxx",
    "cmInstallFilesGenerator.cxx",
    "cmInstallGenerator.cxx",
    "cmInstallGetRuntimeDependenciesGenerator.cxx",
    "cmInstallImportedRuntimeArtifactsGenerator.cxx",
    "cmInstallPackageInfoExportGenerator.cxx",
    "cmInstallProgramsCommand.cxx",
    "cmInstallRuntimeDependencySet.cxx",
    "cmInstallRuntimeDependencySetGenerator.cxx",
    "cmInstallSbomExportGenerator.cxx",
    "cmInstallScriptGenerator.cxx",
    "cmInstallScriptHandler.cxx",
    "cmInstallSubdirectoryGenerator.cxx",
    "cmInstallTargetGenerator.cxx",
    "cmInstallTargetsCommand.cxx",
    "cmInstalledFile.cxx",
    "cmInstrumentation.cxx",
    "cmInstrumentationCommand.cxx",
    "cmInstrumentationQuery.cxx",
    "cmJSONHelpers.cxx",
    "cmJSONState.cxx",
    "cmLDConfigLDConfigTool.cxx",
    "cmLDConfigTool.cxx",
    "cmLinkDirectoriesCommand.cxx",
    "cmLinkItem.cxx",
    "cmLinkItemGraphVisitor.cxx",
    "cmLinkLibrariesCommand.cxx",
    "cmLinkLineComputer.cxx",
    "cmLinkLineDeviceComputer.cxx",
    "cmList.cxx",
    "cmListCommand.cxx",
    "cmListFileCache.cxx",
    "cmLoadCacheCommand.cxx",
    "cmLocalCommonGenerator.cxx",
    "cmLocalFastbuildGenerator.cxx",
    "cmLocalGenerator.cxx",
    "cmLocalNinjaGenerator.cxx",
    "cmLocalUnixMakefileGenerator3.cxx",
    "cmMSVC60LinkLineComputer.cxx",
    "cmMacroCommand.cxx",
    "cmMakeDirectoryCommand.cxx",
    "cmMakefile.cxx",
    "cmMakefileExecutableTargetGenerator.cxx",
    "cmMakefileLibraryTargetGenerator.cxx",
    "cmMakefileProfilingData.cxx",
    "cmMakefileTargetGenerator.cxx",
    "cmMakefileUtilityTargetGenerator.cxx",
    "cmMarkAsAdvancedCommand.cxx",
    "cmMathCommand.cxx",
    "cmMessageCommand.cxx",
    "cmMessenger.cxx",
    "cmNewLineStyle.cxx",
    "cmNinjaLinkLineComputer.cxx",
    "cmNinjaLinkLineDeviceComputer.cxx",
    "cmNinjaNormalTargetGenerator.cxx",
    "cmNinjaTargetGenerator.cxx",
    "cmNinjaUtilityTargetGenerator.cxx",
    "cmOSXBundleGenerator.cxx",
    "cmObjectLocation.cxx",
    "cmOptionCommand.cxx",
    "cmOrderDirectories.cxx",
    "cmOutputConverter.cxx",
    "cmPackageInfoArguments.cxx",
    "cmPackageInfoReader.cxx",
    "cmParseArgumentsCommand.cxx",
    "cmPathLabel.cxx",
    "cmPathResolver.cxx",
    "cmPkgConfigParser.cxx",
    "cmPkgConfigResolver.cxx",
    "cmPlaceholderExpander.cxx",
    "cmPlistParser.cxx",
    "cmPolicies.cxx",
    "cmProcessOutput.cxx",
    "cmProcessTools.cxx",
    "cmProjectCommand.cxx",
    "cmProjectInfoArguments.cxx",
    "cmPropertyDefinition.cxx",
    "cmPropertyMap.cxx",
    "cmQTWrapCPPCommand.cxx",
    "cmQTWrapUICommand.cxx",
    "cmQtAutoGen.cxx",
    "cmQtAutoGenGlobalInitializer.cxx",
    "cmQtAutoGenInitializer.cxx",
    "cmQtAutoGenerator.cxx",
    "cmQtAutoMocUic.cxx",
    "cmQtAutoRcc.cxx",
    "cmRST.cxx",
    "cmRemoveCommand.cxx",
    "cmRemoveDefinitionsCommand.cxx",
    "cmReturnCommand.cxx",
    "cmRulePlaceholderExpander.cxx",
    "cmRuntimeDependencyArchive.cxx",
    "cmSarifLog.cxx",
    "cmSbomArguments.cxx",
    "cmScanDepFormat.cxx",
    "cmScriptGenerator.cxx",
    "cmSearchPath.cxx",
    "cmSeparateArgumentsCommand.cxx",
    "cmSetCommand.cxx",
    "cmSetDirectoryPropertiesCommand.cxx",
    "cmSetPropertyCommand.cxx",
    "cmSetSourceFilesPropertiesCommand.cxx",
    "cmSetTargetPropertiesCommand.cxx",
    "cmSetTestsPropertiesCommand.cxx",
    "cmSiteNameCommand.cxx",
    "cmSourceFile.cxx",
    "cmSourceFileLocation.cxx",
    "cmSourceGroup.cxx",
    "cmSourceGroupCommand.cxx",
    "cmSpdx.cxx",
    "cmSpdxSerializer.cxx",
    "cmStandardLevelResolver.cxx",
    "cmState.cxx",
    "cmStateDirectory.cxx",
    "cmStateSnapshot.cxx",
    "cmStdIoConsole.cxx",
    "cmStdIoInit.cxx",
    "cmStdIoStream.cxx",
    "cmStdIoTerminal.cxx",
    "cmString.cxx",
    "cmStringAlgorithms.cxx",
    "cmStringCommand.cxx",
    "cmStringReplaceHelper.cxx",
    "cmSubcommandTable.cxx",
    "cmSubdirCommand.cxx",
    "cmSystemTools.cxx",
    "cmTarget.cxx",
    "cmTargetCompileDefinitionsCommand.cxx",
    "cmTargetCompileFeaturesCommand.cxx",
    "cmTargetCompileOptionsCommand.cxx",
    "cmTargetIncludeDirectoriesCommand.cxx",
    "cmTargetLinkDirectoriesCommand.cxx",
    "cmTargetLinkLibrariesCommand.cxx",
    "cmTargetLinkOptionsCommand.cxx",
    "cmTargetPrecompileHeadersCommand.cxx",
    "cmTargetPropCommandBase.cxx",
    "cmTargetPropertyComputer.cxx",
    "cmTargetPropertyEntry.cxx",
    "cmTargetSourcesCommand.cxx",
    "cmTargetTraceDependencies.cxx",
    "cmTest.cxx",
    "cmTestGenerator.cxx",
    "cmTimestamp.cxx",
    "cmTransformDepfile.cxx",
    "cmTryCompileCommand.cxx",
    "cmTryRunCommand.cxx",
    "cmUVHandlePtr.cxx",
    "cmUVProcessChain.cxx",
    "cmUnsetCommand.cxx",
    "cmUuid.cxx",
    "cmValue.cxx",
    "cmVariableWatch.cxx",
    "cmVariableWatchCommand.cxx",
    "cmVersion.cxx",
    "cmVersion_Dependencies.cxx",
    "cmWhileCommand.cxx",
    "cmWindowsRegistry.cxx",
    "cmWorkerPool.cxx",
    "cmWorkingDirectory.cxx",
    "cmWriteFileCommand.cxx",
    "cmXMLParser.cxx",
    "cmXMLSafe.cxx",
    "cmXMLWriter.cxx",
    "cmXcFramework.cxx",
    "cm_codecvt.cxx",
    "cm_fileno.cxx",
    "cmake.cxx",
};

const zlib_sources = [_][]const u8{
    "adler32.c",  "compress.c", "crc32.c",   "deflate.c", "gzclose.c",
    "gzlib.c",    "gzread.c",   "gzwrite.c", "inffast.c", "inflate.c",
    "inftrees.c", "trees.c",    "uncompr.c", "zutil.c",
};

const bzip2_sources = [_][]const u8{
    "blocksort.c", "bzlib.c",    "compress.c", "crctable.c",
    "decompress.c", "huffman.c", "randtable.c",
};

const zstd_sources = [_][]const u8{
    "lib/common/debug.c",                  "lib/common/entropy_common.c",
    "lib/common/error_private.c",          "lib/common/fse_decompress.c",
    "lib/common/pool.c",                   "lib/common/threading.c",
    "lib/common/xxhash.c",                 "lib/common/zstd_common.c",
    "lib/compress/fse_compress.c",         "lib/compress/hist.c",
    "lib/compress/huf_compress.c",         "lib/compress/zstd_compress.c",
    "lib/compress/zstd_compress_literals.c", "lib/compress/zstd_compress_sequences.c",
    "lib/compress/zstd_compress_superblock.c", "lib/compress/zstd_double_fast.c",
    "lib/compress/zstd_fast.c",            "lib/compress/zstd_lazy.c",
    "lib/compress/zstd_ldm.c",             "lib/compress/zstd_opt.c",
    "lib/compress/zstd_preSplit.c",        "lib/compress/zstdmt_compress.c",
    "lib/decompress/huf_decompress.c",     "lib/decompress/zstd_ddict.c",
    "lib/decompress/zstd_decompress.c",    "lib/decompress/zstd_decompress_block.c",
    "lib/deprecated/zbuff_common.c",       "lib/deprecated/zbuff_compress.c",
    "lib/deprecated/zbuff_decompress.c",   "lib/dictBuilder/cover.c",
    "lib/dictBuilder/divsufsort.c",        "lib/dictBuilder/fastcover.c",
    "lib/dictBuilder/zdict.c",
};

// Real libuv source lists (from Utilities/cmlibuv/CMakeLists.txt).
const libuv_full_common = [_][]const u8{
    "src/fs-poll.c", "src/idna.c",    "src/inet.c",      "src/strscpy.c",
    "src/strtok.c",  "src/threadpool.c", "src/timer.c",  "src/uv-common.c",
    "src/uv-data-getter-setters.c", "src/version.c",
};
const libuv_full_unix = [_][]const u8{
    "src/unix/async.c",       "src/unix/core.c",      "src/unix/dl.c",
    "src/unix/fs.c",          "src/unix/getaddrinfo.c", "src/unix/getnameinfo.c",
    "src/unix/loop-watcher.c", "src/unix/loop.c",     "src/unix/pipe.c",
    "src/unix/poll.c",        "src/unix/process.c",   "src/unix/signal.c",
    "src/unix/stream.c",      "src/unix/tcp.c",       "src/unix/thread.c",
    "src/unix/tty.c",         "src/unix/udp.c",
};
const libuv_full_linux = [_][]const u8{
    "src/unix/linux.c",          "src/unix/procfs-exepath.c",
    "src/unix/proctitle.c",      "src/unix/sysinfo-loadavg.c",
    "src/unix/sysinfo-memory.c",
};
const libuv_full_darwin = [_][]const u8{
    "src/unix/bsd-ifaddrs.c",    "src/unix/darwin.c",
    "src/unix/darwin-proctitle.c", "src/unix/fsevents.c",
    "src/unix/kqueue.c",         "src/unix/proctitle.c",
};
const libuv_full_win = [_][]const u8{
    "src/win/async.c",  "src/win/core.c",   "src/win/detect-wakeup.c",
    "src/win/dl.c",     "src/win/error.c",  "src/win/fs-event.c",
    "src/win/fs.c",     "src/win/getaddrinfo.c", "src/win/getnameinfo.c",
    "src/win/handle.c", "src/win/loop-watcher.c", "src/win/pipe.c",
    "src/win/poll.c",   "src/win/process-stdio.c", "src/win/process.c",
    "src/win/signal.c", "src/win/stream.c", "src/win/tcp.c",
    "src/win/thread.c", "src/win/tty.c",    "src/win/udp.c",
    "src/win/util.c",   "src/win/winapi.c", "src/win/winsock.c",
};

const curl_sources = [_][]const u8{
    "lib/altsvc.c",
    "lib/amigaos.c",
    "lib/asyn-ares.c",
    "lib/asyn-base.c",
    "lib/asyn-thrdd.c",
    "lib/bufq.c",
    "lib/bufref.c",
    "lib/cf-dns.c",
    "lib/cf-h1-proxy.c",
    "lib/cf-h2-proxy.c",
    "lib/cf-haproxy.c",
    "lib/cf-https-connect.c",
    "lib/cf-ip-happy.c",
    "lib/cf-socket.c",
    "lib/cfilters.c",
    "lib/conncache.c",
    "lib/connect.c",
    "lib/content_encoding.c",
    "lib/cookie.c",
    "lib/cshutdn.c",
    "lib/curl_addrinfo.c",
    "lib/curl_endian.c",
    "lib/curl_fnmatch.c",
    "lib/curl_fopen.c",
    "lib/curl_get_line.c",
    "lib/curl_gethostname.c",
    "lib/curl_gssapi.c",
    "lib/curl_memrchr.c",
    "lib/curl_ntlm_core.c",
    "lib/curl_range.c",
    "lib/curl_sasl.c",
    "lib/curl_sha512_256.c",
    "lib/curl_share.c",
    "lib/curl_sspi.c",
    "lib/curl_threads.c",
    "lib/curl_trc.c",
    "lib/curlx/base64.c",
    "lib/curlx/basename.c",
    "lib/curlx/dynbuf.c",
    "lib/curlx/fopen.c",
    "lib/curlx/inet_ntop.c",
    "lib/curlx/inet_pton.c",
    "lib/curlx/multibyte.c",
    "lib/curlx/nonblock.c",
    "lib/curlx/snprintf.c",
    "lib/curlx/strcopy.c",
    "lib/curlx/strdup.c",
    "lib/curlx/strerr.c",
    "lib/curlx/strparse.c",
    "lib/curlx/timediff.c",
    "lib/curlx/timeval.c",
    "lib/curlx/version_win32.c",
    "lib/curlx/wait.c",
    "lib/curlx/warnless.c",
    "lib/curlx/winapi.c",
    "lib/cw-out.c",
    "lib/cw-pause.c",
    "lib/dict.c",
    "lib/dnscache.c",
    "lib/doh.c",
    "lib/dynhds.c",
    "lib/easy.c",
    "lib/easygetopt.c",
    "lib/easyoptions.c",
    "lib/escape.c",
    "lib/fake_addrinfo.c",
    "lib/file.c",
    "lib/fileinfo.c",
    "lib/formdata.c",
    "lib/ftp.c",
    "lib/ftplistparser.c",
    "lib/getenv.c",
    "lib/getinfo.c",
    "lib/gopher.c",
    "lib/hash.c",
    "lib/headers.c",
    "lib/hmac.c",
    "lib/hostip.c",
    "lib/hostip4.c",
    "lib/hostip6.c",
    "lib/hsts.c",
    "lib/http.c",
    "lib/http1.c",
    "lib/http2.c",
    "lib/http_aws_sigv4.c",
    "lib/http_chunks.c",
    "lib/http_digest.c",
    "lib/http_negotiate.c",
    "lib/http_ntlm.c",
    "lib/http_proxy.c",
    "lib/httpsrr.c",
    "lib/idn.c",
    "lib/if2ip.c",
    "lib/imap.c",
    "lib/ldap.c",
    "lib/llist.c",
    "lib/macos.c",
    "lib/md4.c",
    "lib/md5.c",
    "lib/memdebug.c",
    "lib/mime.c",
    "lib/mprintf.c",
    "lib/mqtt.c",
    "lib/multi.c",
    "lib/multi_ev.c",
    "lib/multi_ntfy.c",
    "lib/netrc.c",
    "lib/noproxy.c",
    "lib/openldap.c",
    "lib/parsedate.c",
    "lib/pingpong.c",
    "lib/pop3.c",
    "lib/progress.c",
    "lib/protocol.c",
    "lib/psl.c",
    "lib/rand.c",
    "lib/ratelimit.c",
    "lib/request.c",
    "lib/rtsp.c",
    "lib/select.c",
    "lib/sendf.c",
    "lib/setopt.c",
    "lib/sha256.c",
    "lib/slist.c",
    "lib/smb.c",
    "lib/smtp.c",
    "lib/socketpair.c",
    "lib/socks.c",
    "lib/socks_gssapi.c",
    "lib/socks_sspi.c",
    "lib/splay.c",
    "lib/strcase.c",
    "lib/strequal.c",
    "lib/strerror.c",
    "lib/system_win32.c",
    "lib/telnet.c",
    "lib/tftp.c",
    "lib/thrdpool.c",
    "lib/thrdqueue.c",
    "lib/transfer.c",
    "lib/uint-bset.c",
    "lib/uint-hash.c",
    "lib/uint-spbset.c",
    "lib/uint-table.c",
    "lib/url.c",
    "lib/urlapi.c",
    "lib/vauth/cleartext.c",
    "lib/vauth/cram.c",
    "lib/vauth/digest.c",
    "lib/vauth/digest_sspi.c",
    "lib/vauth/gsasl.c",
    "lib/vauth/krb5_gssapi.c",
    "lib/vauth/krb5_sspi.c",
    "lib/vauth/ntlm.c",
    "lib/vauth/ntlm_sspi.c",
    "lib/vauth/oauth2.c",
    "lib/vauth/spnego_gssapi.c",
    "lib/vauth/spnego_sspi.c",
    "lib/vauth/vauth.c",
    "lib/version.c",
    "lib/vquic/curl_ngtcp2.c",
    "lib/vquic/curl_quiche.c",
    "lib/vquic/vquic-tls.c",
    "lib/vquic/vquic.c",
    "lib/vssh/libssh.c",
    "lib/vssh/libssh2.c",
    "lib/vssh/vssh.c",
    "lib/vtls/apple.c",
    "lib/vtls/cipher_suite.c",
    "lib/vtls/gtls.c",
    "lib/vtls/hostcheck.c",
    "lib/vtls/keylog.c",
    "lib/vtls/mbedtls.c",
    "lib/vtls/openssl.c",
    "lib/vtls/rustls.c",
    "lib/vtls/schannel.c",
    "lib/vtls/schannel_verify.c",
    "lib/vtls/vtls.c",
    "lib/vtls/vtls_scache.c",
    "lib/vtls/vtls_spack.c",
    "lib/vtls/wolfssl.c",
    "lib/vtls/x509asn1.c",
    "lib/ws.c",
};

const libarchive_sources = [_][]const u8{
    "libarchive/archive_acl.c",
    "libarchive/archive_blake2s_ref.c",
    "libarchive/archive_blake2sp_ref.c",
    "libarchive/archive_check_magic.c",
    "libarchive/archive_cmdline.c",
    "libarchive/archive_cryptor.c",
    "libarchive/archive_digest.c",
    "libarchive/archive_disk_acl_darwin.c",
    "libarchive/archive_disk_acl_freebsd.c",
    "libarchive/archive_disk_acl_linux.c",
    "libarchive/archive_disk_acl_sunos.c",
    "libarchive/archive_entry.c",
    "libarchive/archive_entry_copy_bhfi.c",
    "libarchive/archive_entry_copy_stat.c",
    "libarchive/archive_entry_link_resolver.c",
    "libarchive/archive_entry_sparse.c",
    "libarchive/archive_entry_stat.c",
    "libarchive/archive_entry_strmode.c",
    "libarchive/archive_entry_xattr.c",
    "libarchive/archive_hmac.c",
    "libarchive/archive_match.c",
    "libarchive/archive_options.c",
    "libarchive/archive_pack_dev.c",
    "libarchive/archive_parse_date.c",
    "libarchive/archive_pathmatch.c",
    "libarchive/archive_ppmd7.c",
    "libarchive/archive_ppmd8.c",
    "libarchive/archive_random.c",
    "libarchive/archive_rb.c",
    "libarchive/archive_read.c",
    "libarchive/archive_read_add_passphrase.c",
    "libarchive/archive_read_append_filter.c",
    "libarchive/archive_read_data_into_fd.c",
    "libarchive/archive_read_disk_entry_from_file.c",
    "libarchive/archive_read_disk_posix.c",
    "libarchive/archive_read_disk_set_standard_lookup.c",
    "libarchive/archive_read_disk_windows.c",
    "libarchive/archive_read_extract.c",
    "libarchive/archive_read_extract2.c",
    "libarchive/archive_read_open_fd.c",
    "libarchive/archive_read_open_file.c",
    "libarchive/archive_read_open_filename.c",
    "libarchive/archive_read_open_memory.c",
    "libarchive/archive_read_set_format.c",
    "libarchive/archive_read_set_options.c",
    "libarchive/archive_read_support_filter_all.c",
    "libarchive/archive_read_support_filter_by_code.c",
    "libarchive/archive_read_support_filter_bzip2.c",
    "libarchive/archive_read_support_filter_compress.c",
    "libarchive/archive_read_support_filter_grzip.c",
    "libarchive/archive_read_support_filter_gzip.c",
    "libarchive/archive_read_support_filter_lrzip.c",
    "libarchive/archive_read_support_filter_lz4.c",
    "libarchive/archive_read_support_filter_lzop.c",
    "libarchive/archive_read_support_filter_none.c",
    "libarchive/archive_read_support_filter_program.c",
    "libarchive/archive_read_support_filter_rpm.c",
    "libarchive/archive_read_support_filter_uu.c",
    "libarchive/archive_read_support_filter_xz.c",
    "libarchive/archive_read_support_filter_zstd.c",
    "libarchive/archive_read_support_format_7zip.c",
    "libarchive/archive_read_support_format_all.c",
    "libarchive/archive_read_support_format_ar.c",
    "libarchive/archive_read_support_format_by_code.c",
    "libarchive/archive_read_support_format_cab.c",
    "libarchive/archive_read_support_format_cpio.c",
    "libarchive/archive_read_support_format_empty.c",
    "libarchive/archive_read_support_format_iso9660.c",
    "libarchive/archive_read_support_format_lha.c",
    "libarchive/archive_read_support_format_mtree.c",
    "libarchive/archive_read_support_format_rar.c",
    "libarchive/archive_read_support_format_rar5.c",
    "libarchive/archive_read_support_format_raw.c",
    "libarchive/archive_read_support_format_tar.c",
    "libarchive/archive_read_support_format_warc.c",
    "libarchive/archive_read_support_format_xar.c",
    "libarchive/archive_read_support_format_zip.c",
    "libarchive/archive_string.c",
    "libarchive/archive_string_sprintf.c",
    "libarchive/archive_time.c",
    "libarchive/archive_util.c",
    "libarchive/archive_version_details.c",
    "libarchive/archive_virtual.c",
    "libarchive/archive_windows.c",
    "libarchive/archive_write.c",
    "libarchive/archive_write_add_filter.c",
    "libarchive/archive_write_add_filter_b64encode.c",
    "libarchive/archive_write_add_filter_by_name.c",
    "libarchive/archive_write_add_filter_bzip2.c",
    "libarchive/archive_write_add_filter_compress.c",
    "libarchive/archive_write_add_filter_grzip.c",
    "libarchive/archive_write_add_filter_gzip.c",
    "libarchive/archive_write_add_filter_lrzip.c",
    "libarchive/archive_write_add_filter_lz4.c",
    "libarchive/archive_write_add_filter_lzop.c",
    "libarchive/archive_write_add_filter_none.c",
    "libarchive/archive_write_add_filter_program.c",
    "libarchive/archive_write_add_filter_uuencode.c",
    "libarchive/archive_write_add_filter_xz.c",
    "libarchive/archive_write_add_filter_zstd.c",
    "libarchive/archive_write_disk_posix.c",
    "libarchive/archive_write_disk_set_standard_lookup.c",
    "libarchive/archive_write_disk_windows.c",
    "libarchive/archive_write_open_fd.c",
    "libarchive/archive_write_open_file.c",
    "libarchive/archive_write_open_filename.c",
    "libarchive/archive_write_open_memory.c",
    "libarchive/archive_write_set_format.c",
    "libarchive/archive_write_set_format_7zip.c",
    "libarchive/archive_write_set_format_ar.c",
    "libarchive/archive_write_set_format_by_name.c",
    "libarchive/archive_write_set_format_cpio.c",
    "libarchive/archive_write_set_format_cpio_binary.c",
    "libarchive/archive_write_set_format_cpio_newc.c",
    "libarchive/archive_write_set_format_cpio_odc.c",
    "libarchive/archive_write_set_format_filter_by_ext.c",
    "libarchive/archive_write_set_format_gnutar.c",
    "libarchive/archive_write_set_format_iso9660.c",
    "libarchive/archive_write_set_format_mtree.c",
    "libarchive/archive_write_set_format_pax.c",
    "libarchive/archive_write_set_format_raw.c",
    "libarchive/archive_write_set_format_shar.c",
    "libarchive/archive_write_set_format_ustar.c",
    "libarchive/archive_write_set_format_v7tar.c",
    "libarchive/archive_write_set_format_warc.c",
    "libarchive/archive_write_set_format_xar.c",
    "libarchive/archive_write_set_format_zip.c",
    "libarchive/archive_write_set_options.c",
    "libarchive/archive_write_set_passphrase.c",
    "libarchive/filter_fork_posix.c",
    "libarchive/filter_fork_windows.c",
    "libarchive/xxhash.c",
};

fn def(ch: *std.Build.Step.ConfigHeader, name: []const u8) void {
    ch.addValue(name, void, {});
}

fn addCurlConfig(ch: *std.Build.Step.ConfigHeader, os: std.Target.Os.Tag) void {
    // Networking/POSIX feature set for a TLS-less static libcurl.
    // Headers/funcs/types are split: `common_*` exist on mingw too; `posix_*`
    // are POSIX-only. On Windows we omit the POSIX networking surface and let
    // curl_setup.h's `_WIN32` branch select winsock (the cmake config template
    // carries no winsock knobs — it is driven purely by which HAVE_* we set).
    const is_win = os == .windows;
    const common_headers = [_][]const u8{
        "HAVE_FCNTL_H", "HAVE_SIGNAL_H", "HAVE_STDBOOL_H", "HAVE_SYS_PARAM_H",
        "HAVE_SYS_STAT_H", "HAVE_SYS_TIME_H", "HAVE_SYS_TYPES_H", "HAVE_UNISTD_H",
        "HAVE_LOCALE_H",
    };
    const posix_headers = [_][]const u8{
        "HAVE_ARPA_INET_H", "HAVE_NETDB_H", "HAVE_NETINET_IN_H", "HAVE_NETINET_TCP_H",
        "HAVE_NET_IF_H", "HAVE_POLL_H", "HAVE_PWD_H", "HAVE_STRINGS_H",
        "HAVE_SYS_IOCTL_H", "HAVE_SYS_RESOURCE_H", "HAVE_SYS_SELECT_H",
        "HAVE_SYS_SOCKET_H", "HAVE_SYS_UN_H", "HAVE_TERMIOS_H", "HAVE_IFADDRS_H",
        "HAVE_NETINET_UDP_H",
    };
    const common_funcs = [_][]const u8{
        "HAVE_FTRUNCATE", "HAVE_GETTIMEOFDAY", "HAVE_SETLOCALE", "HAVE_SIGNAL",
        "HAVE_STRDUP", "HAVE_STRTOLL", "HAVE_UTIME",
    };
    const posix_funcs = [_][]const u8{
        "HAVE_FCNTL", "HAVE_FCNTL_O_NONBLOCK", "HAVE_FREEADDRINFO",
        "HAVE_GETADDRINFO", "HAVE_GETEUID", "HAVE_GETHOSTNAME", "HAVE_GETIFADDRS",
        "HAVE_GETPEERNAME", "HAVE_GETPPID", "HAVE_GETPWUID", "HAVE_GETPWUID_R",
        "HAVE_GETRLIMIT", "HAVE_GETSOCKNAME", "HAVE_IF_NAMETOINDEX",
        "HAVE_IOCTL", "HAVE_IOCTL_FIONBIO", "HAVE_IOCTL_SIOCGIFADDR", "HAVE_POLL",
        "HAVE_POLL_FINE", "HAVE_PIPE", "HAVE_RECV", "HAVE_SELECT", "HAVE_SEND",
        "HAVE_SETRLIMIT", "HAVE_SIGACTION", "HAVE_SIGINTERRUPT",
        "HAVE_SIGSETJMP", "HAVE_SOCKET", "HAVE_SOCKETPAIR",
        "HAVE_STRCASECMP", "HAVE_STRERROR_R", "HAVE_STRTOK_R", "HAVE_UTIMES",
    };
    const common_types = [_][]const u8{
        "HAVE_BOOL_T", "HAVE_STRUCT_TIMEVAL", "HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID",
        "HAVE_STRUCT_SOCKADDR_STORAGE",
    };
    const posix_types = [_][]const u8{"HAVE_SA_FAMILY_T"};
    for (common_headers) |h| def(ch, h);
    for (common_funcs) |f| def(ch, f);
    for (common_types) |t| def(ch, t);
    if (!is_win) {
        for (posix_headers) |h| def(ch, h);
        for (posix_funcs) |f| def(ch, f);
        for (posix_types) |t| def(ch, t);
        // POSIX strerror_r variant (windows uses strerror_s, handled by curl).
        def(ch, "HAVE_POSIX_STRERROR_R");
    } else {
        // Winsock socket layer: recv/send/select exist via winsock2.h. curl_setup.h
        // needs HAVE_RECV/HAVE_SEND (+ RECV_TYPE_ARG*/SEND_TYPE_ARG* macros, set on
        // the curl lib) or it errors "Missing definition of sread/swrite". Also the
        // non-blocking method (ioctlsocket FIONBIO) and str*cmp variants.
        for ([_][]const u8{
            "HAVE_RECV",        "HAVE_SEND",        "HAVE_SELECT",
            "HAVE_SOCKET",      "HAVE_CLOSESOCKET", "HAVE_IOCTLSOCKET",
            "HAVE_IOCTLSOCKET_FIONBIO", "HAVE_STRICMP", "HAVE_STRCMPI",
        }) |n| def(ch, n);
    }
    def(ch, "HAVE_ZLIB_H");
    def(ch, "HAVE_LIBZ");
    def(ch, "CURL_DISABLE_LDAP");
    def(ch, "CURL_DISABLE_LDAPS");
    if (os == .linux) def(ch, "HAVE_LINUX_TCP_H");
    if (os.isDarwin()) def(ch, "HAVE_MACH_ABSOLUTE_TIME");
    // ${VAR}-style tokens the renderer must resolve. Optional ones stay
    // undefined; emit explicit sizeof blocks (x86_64/arm64 LP64 model).
    for ([_][]const u8{
        "CURL_DEFAULT_SSL_BACKEND", "CURL_EXTERN_SYMBOL", "CURL_KRB5_VERSION",
        "CURL_BORINGSSL_VERSION",   "CURL_PATCHSTAMP",
        "_FILE_OFFSET_BITS",
    }) |n| ch.addValue(n, @TypeOf(null), null);
    ch.addValue("CURL_OS", []const u8, "\"zig\""); // version.c uses it as a string
    ch.addValue("SIZEOF_OFF_T_CODE", []const u8, "#define SIZEOF_OFF_T 8");
    ch.addValue("SIZEOF_CURL_OFF_T_CODE", []const u8, "#define SIZEOF_CURL_OFF_T 8");
    // curl_socket_t is `int` on POSIX (4); on Win64 it is SOCKET=UINT_PTR (8).
    ch.addValue("SIZEOF_CURL_SOCKET_T_CODE", []const u8, if (os == .windows) "#define SIZEOF_CURL_SOCKET_T 8" else "#define SIZEOF_CURL_SOCKET_T 4");
    ch.addValue("SIZEOF_SIZE_T_CODE", []const u8, "#define SIZEOF_SIZE_T 8");
    ch.addValue("SIZEOF_SSIZE_T_CODE", []const u8, "#define SIZEOF_SSIZE_T 8");
    ch.addValue("SIZEOF_TIME_T_CODE", []const u8, "#define SIZEOF_TIME_T 8");
}

fn addLibarchiveConfig(ch: *std.Build.Step.ConfigHeader, os: std.Target.Os.Tag) void {
    // --- @VAR@ substitutions (every token must resolve) ---
    ch.addValue("ICONV_CONST", []const u8, ""); // plain #define ICONV_CONST
    ch.addValue("LIBARCHIVE_VERSION_NUMBER", []const u8, "3007009");
    ch.addValue("LIBARCHIVE_VERSION_STRING", []const u8, "3.7.9");
    ch.addValue("VERSION", []const u8, "3.7.9");
    ch.addValue("SIZEOF_WCHAR_T", i64, if (os == .windows) 2 else 4);
    // Type fallbacks: leave undefined (the real types exist) and version
    // strings / Windows-only macros undefined as well.
    for ([_][]const u8{
        "const",                  "mode_t",               "off_t",
        "pid_t",                  "size_t",               "ssize_t",
        "BSDCAT_VERSION_STRING",  "BSDCPIO_VERSION_STRING", "BSDTAR_VERSION_STRING",
        "BSDUNZIP_VERSION_STRING", "LIBACL_PKGCONFIG_VERSION", "LIBATTR_PKGCONFIG_VERSION",
        "LIBRICHACL_PKGCONFIG_VERSION", "_FILE_OFFSET_BITS", "_LARGE_FILES",
        "NTDDI_VERSION",          "_WIN32_WINNT",         "WINVER",
    }) |n| ch.addValue(n, @TypeOf(null), null);
    // uid_t/gid_t/id_t: present on POSIX (leave undef → real type used), but
    // absent on mingw — there libarchive's CMake defines them to `short`.
    if (os == .windows) {
        for ([_][]const u8{ "uid_t", "gid_t", "id_t" }) |n| ch.addValue(n, []const u8, "short");
    } else {
        for ([_][]const u8{ "uid_t", "gid_t", "id_t" }) |n| ch.addValue(n, @TypeOf(null), null);
    }

    // --- Feature set for read/write of common formats ---
    // `feats` are present on mingw too; `posix_feats` are POSIX-only (absent on
    // mingw — its headers/funcs differ; libarchive's *_windows.c paths cover them).
    const feats = [_][]const u8{
        "HAVE_ZLIB_H",        "HAVE_BZLIB_H",       "HAVE_ZSTD_H",
        "HAVE_LIBZ",          "HAVE_LIBBZ2",        "HAVE_LIBZSTD",
        "HAVE_ERRNO_H",       "HAVE_FCNTL_H",       "HAVE_LIMITS_H",
        "HAVE_STDARG_H",      "HAVE_STDINT_H",      "HAVE_STDLIB_H",
        "HAVE_STRING_H",      "HAVE_INTTYPES_H",    "HAVE_SYS_STAT_H",
        "HAVE_SYS_TYPES_H",   "HAVE_UNISTD_H",      "HAVE_WCHAR_H",
        "HAVE_WCTYPE_H",      "HAVE_DIRENT_H",      "HAVE_SYS_TIME_H",
        "HAVE_TIME_H",        "HAVE_CTYPE_H",       "HAVE_SIGNAL_H",
        "HAVE_LOCALE_H",      "HAVE_MEMORY_H",      "HAVE_STDBOOL_H",
        "HAVE_SYS_PARAM_H",   "HAVE_FCNTL",         "HAVE_FSEEKO",
        "HAVE_FSTAT",         "HAVE_FTRUNCATE",     "HAVE_GETPID",
        "HAVE_MEMMOVE",       "HAVE_MEMSET",        "HAVE_MKDIR",
        "HAVE_STRCHR",        "HAVE_STRDUP",        "HAVE_STRERROR",
        "HAVE_STRRCHR",       "HAVE_TZSET",         "HAVE_UTIME",
        "HAVE_VPRINTF",       "HAVE_WCRTOMB",       "HAVE_WCSCMP",
        "HAVE_WCSCPY",        "HAVE_WCSLEN",        "HAVE_WMEMCMP",
        "HAVE_WMEMCPY",       "HAVE_STRNLEN",       "HAVE_DECL_INT64_MAX",
        "HAVE_DECL_INT64_MIN", "HAVE_DECL_SIZE_MAX", "HAVE_INTMAX_T",
        "HAVE_UINTMAX_T",
    };
    // POSIX headers/funcs that mingw lacks (must stay undefined on Windows).
    const posix_feats = [_][]const u8{
        "HAVE_PWD_H",         "HAVE_GRP_H",         "HAVE_POLL_H",
        "HAVE_LANGINFO_H",    "HAVE_SYS_UTSNAME_H", "HAVE_SYS_WAIT_H",
        "HAVE_SYS_IOCTL_H",   "HAVE_SYS_SELECT_H",  "HAVE_FCHDIR",
        "HAVE_GETEUID",       "HAVE_LSTAT",         "HAVE_LCHOWN",
        "HAVE_MKFIFO",        "HAVE_MKNOD",         "HAVE_PIPE",
        "HAVE_POLL",          "HAVE_READLINK",      "HAVE_SELECT",
        "HAVE_SETENV",        "HAVE_SYMLINK",       "HAVE_TIMEGM",
        "HAVE_UNSETENV",      "HAVE_UTIMES",        "HAVE_DIRFD",
        "HAVE_GETLINE",
        // nanosecond stat field (mingw struct stat has no st_mtim), the
        // FS_IOC_GETFLAGS ioctl, and fork() for the program filter.
        "HAVE_STRUCT_STAT_ST_MTIM_TV_NSEC", "HAVE_WORKING_FS_IOC_GETFLAGS",
        "HAVE_FORK", "HAVE_VFORK", "HAVE_WORKING_FORK",
    };
    for (feats) |f| def(ch, f);
    if (os != .windows) {
        for (posix_feats) |f| def(ch, f);
    }
    if (os == .linux) {
        for ([_][]const u8{ "HAVE_LINUX_FS_H", "HAVE_SYS_STATFS_H", "MAJOR_IN_SYSMACROS", "HAVE_SYS_SYSMACROS_H" }) |f| def(ch, f);
        // iconv lives in libc on Linux (musl + glibc), so no extra link dep.
        // Needed so `cmake -E tar` (pax) can set hdrcharset=UTF-8 — without it
        // libarchive reports "character-set conversion not fully supported".
        for ([_][]const u8{ "HAVE_ICONV", "HAVE_ICONV_H" }) |f| def(ch, f);
    } else if (os.isDarwin()) {
        for ([_][]const u8{ "HAVE_STRUCT_STAT_ST_BIRTHTIME", "HAVE_STRUCT_STAT_ST_MTIMESPEC_TV_NSEC", "HAVE_COPYFILE_H" }) |f| def(ch, f);
    } else if (os == .windows) {
        // archive_random.c / archive_util.c use the CryptoAPI on _WIN32; without
        // HAVE_WINCRYPT_H (or HAVE_BCRYPT_H) <wincrypt.h> is never included yet
        // CryptAcquireContext/CryptGenRandom are still called. advapi32 (already
        // linked) provides them. Also expose the Windows-native headers.
        for ([_][]const u8{ "HAVE_WINCRYPT_H", "HAVE_WINDOWS_H", "HAVE_IO_H", "HAVE_DIRECT_H" }) |f| def(ch, f);
    }
}
