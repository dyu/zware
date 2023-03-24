const std = @import("std");
const Builder = std.build.Builder;

const fib_c = "src/c/fib.c";
const fib_wasm = "src/c/fib.wasm";

fn concat(a: *std.heap.ArenaAllocator, str1: []const u8, str2: []const u8) ![]const u8 {
    var result = try a.allocator().alloc( u8, str1.len+str2.len);
    
    std.mem.copy(u8, result[0..], str1);
    std.mem.copy(u8, result[str1.len..], str2);
    
    return result;
}

fn c2wasm(arena: *std.heap.ArenaAllocator, wasi_clang: []const u8, src: []const u8, out: []const u8) !void {
    var child = std.ChildProcess.init(&.{
        wasi_clang,
        "-Wl,--no-entry",
        "-mexec-model=reactor",
        "-o",
        out,
        src,
    }, arena.allocator());
    try child.spawn();
    _ = try child.wait();
}

pub fn build(b: *Builder) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const cwd = std.fs.cwd();
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    
    // options
    const wasi_sdk = b.option(
        []const u8, "wasi-sdk-path", "the wasi sdk path is required",
    );
    if (wasi_sdk == null) {
        @panic("Required: -Dwasi-sdk-path=/path/to/wasi/sdk");
    }
    
    {
        var arena = std.heap.ArenaAllocator.init(gpa.allocator());
        defer arena.deinit();
        
        const wasi_clang = try concat(&arena, wasi_sdk.?, "/bin/clang"); 
        try c2wasm(&arena, wasi_clang, fib_c, fib_wasm);
        _ = cwd.access(fib_wasm, .{ .mode = .read_only }) catch {
            @panic("Expected " ++ fib_wasm);
        };
    }

    const exe = b.addExecutable("fib", "src/fib.zig");
    exe.addPackagePath("zware", "../../src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
