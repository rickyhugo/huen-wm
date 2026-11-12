const std = @import("std");

pub fn build(builder: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0")) @panic("huen-wm requires Zig exactly 0.17.0");
    const target = builder.standardTargetOptions(.{ .default_target = .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } } } });
    if (target.result.os.tag != .macos or target.result.cpu.arch != @import("builtin").cpu.arch) @panic("huen-wm builds for the host macOS architecture only");
    const optimize = builder.standardOptimizeOption(.{});
    const module = builder.createModule(.{ .root_source_file = builder.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const sdk = std.mem.trim(u8, builder.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\r\n");
    module.addSystemFrameworkPath(.{ .cwd_relative = builder.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    module.addSystemIncludePath(.{ .cwd_relative = builder.fmt("{s}/usr/include", .{sdk}) });
    module.addLibraryPath(.{ .cwd_relative = builder.fmt("{s}/usr/lib", .{sdk}) });
    module.addIncludePath(builder.path("native"));
    module.addIncludePath(builder.path("native/vendor/lua-5.5.1"));
    module.addCSourceFiles(.{ .root = builder.path("native/vendor/lua-5.5.1"), .files = &.{ "lapi.c", "lauxlib.c", "lbaselib.c", "lcode.c", "lcorolib.c", "lctype.c", "ldblib.c", "ldebug.c", "ldo.c", "ldump.c", "lfunc.c", "lgc.c", "linit.c", "liolib.c", "llex.c", "lmathlib.c", "lmem.c", "loadlib.c", "lobject.c", "lopcodes.c", "loslib.c", "lparser.c", "lstate.c", "lstring.c", "lstrlib.c", "ltable.c", "ltablib.c", "ltm.c", "lundump.c", "lutf8lib.c", "lvm.c", "lzio.c" }, .flags = &.{"-DLUA_USE_MACOSX"} });
    const native = builder.addSystemCommand(&.{ "xcrun", "clang", "-mmacosx-version-min=14.0", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-c" });
    native.addArg("-I");
    native.addDirectoryArg(builder.path("native/vendor/lua-5.5.1"));
    native.addFileArg(builder.path("native/platform.m"));
    native.addArg("-o");
    module.addObjectFile(native.addOutputFileArg("platform.o"));
    const scene = builder.addSystemCommand(&.{ "xcrun", "clang", "-mmacosx-version-min=14.0", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-c" });
    scene.addFileArg(builder.path("native/scene.m"));
    scene.addArg("-o");
    module.addObjectFile(scene.addOutputFileArg("scene.o"));
    for ([_][]const u8{ "Cocoa", "ApplicationServices", "Carbon", "QuartzCore", "ScreenCaptureKit", "CoreGraphics" }) |framework| module.linkFramework(framework, .{});
    const executable = builder.addExecutable(.{ .name = "huen-wm", .root_module = module });
    builder.installArtifact(executable);
}
