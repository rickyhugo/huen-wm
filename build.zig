const std = @import("std");

pub fn build(builder: *std.Build) void {
    const zig_version = @import("builtin").zig_version;
    if (zig_version.major != 0 or zig_version.minor != 17) @panic("huen-wm requires Zig 0.17.x");
    const target = builder.standardTargetOptions(.{ .default_target = .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } } } });
    if (target.result.os.tag != .macos or target.result.cpu.arch != @import("builtin").cpu.arch) @panic("huen-wm builds for the host macOS architecture only");
    const optimize = builder.standardOptimizeOption(.{});
    const module = builder.createModule(.{ .root_source_file = builder.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const sdk = std.mem.trim(u8, builder.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\r\n");
    const native_smoke_module = builder.createModule(.{ .root_source_file = builder.path("tools/native_smoke.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_]*std.Build.Module{ module, native_smoke_module }) |sdk_user| {
        sdk_user.addSystemFrameworkPath(.{ .cwd_relative = builder.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        sdk_user.addSystemIncludePath(.{ .cwd_relative = builder.fmt("{s}/usr/include", .{sdk}) });
        sdk_user.addLibraryPath(.{ .cwd_relative = builder.fmt("{s}/usr/lib", .{sdk}) });
    }
    module.addIncludePath(builder.path("native"));
    module.addIncludePath(builder.path("native/vendor/lua-5.5.1"));
    module.addCSourceFile(.{ .file = builder.path("native/config_worker.c"), .flags = &.{ "-Wall", "-Wextra" } });
    module.addCSourceFile(.{ .file = builder.path("native/corner.c"), .flags = &.{ "-Wall", "-Wextra" } });
    module.addCSourceFiles(.{ .root = builder.path("native/vendor/lua-5.5.1"), .files = &.{ "lapi.c", "lauxlib.c", "lbaselib.c", "lcode.c", "lcorolib.c", "lctype.c", "ldblib.c", "ldebug.c", "ldo.c", "ldump.c", "lfunc.c", "lgc.c", "linit.c", "liolib.c", "llex.c", "lmathlib.c", "lmem.c", "loadlib.c", "lobject.c", "lopcodes.c", "loslib.c", "lparser.c", "lstate.c", "lstring.c", "lstrlib.c", "ltable.c", "ltablib.c", "ltm.c", "lundump.c", "lutf8lib.c", "lvm.c", "lzio.c" }, .flags = &.{"-DLUA_USE_MACOSX"} });
    for ([_][]const u8{ "platform", "scene", "groups" }) |unit| {
        const compilation = builder.addSystemCommand(&.{ "xcrun", "clang", "-mmacosx-version-min=14.0", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-c" });
        if (std.mem.eql(u8, unit, "platform")) {
            compilation.addArgs(&.{ builder.fmt("-DHUEN_ZIG_VERSION=\"{s}\"", .{@import("builtin").zig_version_string}), "-I" });
            compilation.addDirectoryArg(builder.path("native/vendor/lua-5.5.1"));
        }
        compilation.addFileArg(builder.path(builder.fmt("native/{s}.m", .{unit})));
        compilation.addArg("-o");
        module.addObjectFile(compilation.addOutputFileArg(builder.fmt("{s}.o", .{unit})));
    }
    // These native units are Zig, but they build as separate objects, as the units above do, so the suite's fake adapter can export the same symbols.
    for ([_][]const u8{ "input", "observe", "session_native" }) |unit| {
        const unit_module = builder.createModule(.{ .root_source_file = builder.path(builder.fmt("src/{s}.zig", .{unit})), .target = target, .optimize = optimize, .link_libc = true });
        module.addObject(builder.addObject(.{ .name = unit, .root_module = unit_module }));
    }
    for ([_][]const u8{ "Cocoa", "ApplicationServices", "Carbon", "QuartzCore", "ScreenCaptureKit", "CoreGraphics" }) |framework| module.linkFramework(framework, .{});
    const executable = builder.addExecutable(.{ .name = "huen-wm", .root_module = module });
    builder.installArtifact(executable);

    // Developer checks that drive the built binary or the installed app from outside, as a user would.
    const smoke = builder.addExecutable(.{ .name = "smoke", .root_module = builder.createModule(.{ .root_source_file = builder.path("tools/smoke.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    const smoke_run = builder.addRunArtifact(smoke);
    smoke_run.addArtifactArg(executable);
    smoke_run.has_side_effects = true;
    builder.step("smoke", "Run headless checks of the CLI, configuration and socket").dependOn(&smoke_run.step);
    for ([_][]const u8{ "CoreGraphics", "CoreFoundation", "ApplicationServices" }) |framework| native_smoke_module.linkFramework(framework, .{});
    const native_smoke = builder.addExecutable(.{ .name = "native-smoke", .root_module = native_smoke_module });
    builder.installArtifact(native_smoke);
    const native_smoke_run = builder.addRunArtifact(native_smoke);
    native_smoke_run.addPassthruArgs();
    builder.step("native-smoke", "Check native fixture windows against the installed manager; pass options after --").dependOn(&native_smoke_run.step);
    const login = builder.addExecutable(.{ .name = "login", .root_module = builder.createModule(.{ .root_source_file = builder.path("tools/login.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    const login_run = builder.addRunArtifact(login);
    login_run.addPassthruArgs();
    builder.step("login", "Enable, disable, or report login startup: zig build login -- enable|disable|status").dependOn(&login_run.step);

    // The suite links the manager against a fake adapter in tests/fake, so it takes none of the native objects above.
    const manager = builder.createModule(.{ .root_source_file = builder.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const suite = builder.createModule(.{ .root_source_file = builder.path("tests/manager.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "wm", .module = manager }} });
    const layout = builder.addSystemCommand(&.{ "xcrun", "clang", "-mmacosx-version-min=14.0", "-Wall", "-Wextra", "-c", "-I" });
    layout.addDirectoryArg(builder.path("native"));
    layout.addArg("-I");
    layout.addDirectoryArg(builder.path("native/vendor/lua-5.5.1"));
    layout.addFileArg(builder.path("tests/layout.c"));
    layout.addArg("-o");
    suite.addObjectFile(layout.addOutputFileArg("layout.o"));
    const tests = builder.addExecutable(.{ .name = "manager-tests", .root_module = suite });
    const test_step = builder.step("test", "Run each manager-seam test case in its own process, and the pure-module tests");
    for (@import("tests/cases.zig").all) |case| {
        const first = builder.addRunArtifact(tests);
        first.setName(case.name);
        first.addArg(case.name);
        first.has_side_effects = true;
        if (!case.restart) {
            test_step.dependOn(&first.step);
            continue;
        }
        first.addArg("--save");
        const state = first.addOutputFileArg("state.json");
        const second = builder.addRunArtifact(tests);
        second.setName(builder.fmt("{s} (after restart)", .{case.name}));
        second.addArgs(&.{ case.name, "--load" });
        second.addFileArg(state);
        second.has_side_effects = true;
        test_step.dependOn(&second.step);
    }

    // Three pure modules have a seam of their own, tested as Zig test blocks: every order of the hotkey reports, tile geometry, and corner-radius measurement.
    for ([_][]const u8{ "delivery", "layout" }) |unit| {
        const subject = builder.createModule(.{ .root_source_file = builder.path(builder.fmt("src/{s}.zig", .{unit})), .target = target, .optimize = optimize });
        const checks = builder.addTest(.{ .name = unit, .root_module = builder.createModule(.{ .root_source_file = builder.path(builder.fmt("tests/pure/{s}.zig", .{unit})), .target = target, .optimize = optimize, .imports = &.{.{ .name = unit, .module = subject }} }) });
        test_step.dependOn(&builder.addRunArtifact(checks).step);
    }
    const corner_module = builder.createModule(.{ .root_source_file = builder.path("tests/pure/corner.zig"), .target = target, .optimize = optimize, .link_libc = true });
    corner_module.addCSourceFile(.{ .file = builder.path("native/corner.c"), .flags = &.{ "-Wall", "-Wextra" } });
    const corner_checks = builder.addTest(.{ .name = "corner", .root_module = corner_module });
    test_step.dependOn(&builder.addRunArtifact(corner_checks).step);
}
