const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Input = @import("input.zig");

const log = std.log;
const perf_counter = @import("perfcounter.zig");

pub const ticks_per_second = 83;
pub const tick: f32 = 1.0 / @as(f32, @floatFromInt(ticks_per_second));
pub const tick_ns: u64 = 1_000_000_000 / ticks_per_second;
pub const max_tick_ns: u64 = 250_000_000;

pub fn main() !void {
    sdl.setMainReady();

    var gpa_struct: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_struct.deinit();
    const gpa = gpa_struct.allocator();

    try sdl.init(sdl.c.SDL_INIT_VIDEO);
    defer sdl.quit();

    const window = try sdl.createWindow(
        "voxel_cone_tracing",
        1920,
        1080,
        sdl.c.SDL_WINDOW_RESIZABLE,
    );
    defer sdl.destroyWindow(window);

    try sdl.setWindowRelativeMouseMode(window, true);

    const device = try sdl.createGPUDevice(
        sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
        true,
        "vulkan",
    );
    defer sdl.destroyGPUDevice(device);

    var input = Input.init(gpa);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_W }, .forward);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_S }, .backward);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_D }, .right);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_A }, .left);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_SPACE }, .up);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_LCTRL }, .down);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_TAB }, .toggle_debug_view);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_GRAVE }, .toggle_voxels_follow_camera);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_Q }, .prev_debug_view);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_E }, .next_debug_view);
    defer input.deinit();

    var frame_timer = try std.time.Timer.start();
    var lag: u64 = 0;
    var time: f64 = 0.0;

    perf_counter.init(gpa);
    defer perf_counter.deinit();
    var perf_print_timer = try std.time.Timer.start();

    frame_timer.reset();
    main_loop: while (true) {
        perf_counter.start("main_loop");
        defer perf_counter.stop("main_loop");
        if (perf_print_timer.read() > 1_000_000_000) {
            var it = perf_counter.nameIterator();
            while (it.next()) |name| {
                const stats = perf_counter.stats(name);
                log.info(
                    "{s}\t{d:.3}\t({d:.3}-{d:.3})",
                    .{ name, stats[2] * 1e-6, stats[0] * 1e-6, stats[4] * 1e-6 },
                );
            }
            perf_print_timer.reset();
        }

        lag += @min(frame_timer.lap(), max_tick_ns);

        var event: sdl.c.SDL_Event = undefined;
        while (sdl.c.SDL_PollEvent(&event)) {
            if (event.type == sdl.c.SDL_EVENT_QUIT) break :main_loop;
            if (event.type == sdl.c.SDL_EVENT_KEY_DOWN) switch (event.key.key) {
                sdl.c.SDLK_ESCAPE => break :main_loop,
                else => {},
            };
            input.accumulate(event);
        }

        while (lag >= tick_ns) {
            input.decay();
            lag -= tick_ns;
            time += 1.0 / @as(f64, @floatFromInt(ticks_per_second));
        }

        const alpha = @as(f32, @floatFromInt(lag)) / @as(f32, @floatFromInt(tick_ns));
        _ = alpha;
    }
}
