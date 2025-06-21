const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Input = @import("input.zig");
const Scene = @import("scene.zig");

const log = std.log;
const perf_counter = @import("perfcounter.zig");

pub const ticks_per_second = 83;
pub const tick: f32 = 1.0 / @as(f32, @floatFromInt(ticks_per_second));
pub const tick_ns: u64 = 1_000_000_000 / ticks_per_second;
pub const max_tick_ns: u64 = 250_000_000;

const window_width = 1920;
const window_height = 1080;

pub fn main() !void {
    sdl.setMainReady();

    var gpa_struct: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_struct.deinit();
    const gpa = gpa_struct.allocator();

    try sdl.init(sdl.c.SDL_INIT_VIDEO);
    defer sdl.quit();

    const window = try sdl.createWindow(
        "voxel_cone_tracing",
        window_width,
        window_height,
        sdl.c.SDL_WINDOW_RESIZABLE,
    );
    defer sdl.destroyWindow(window);

    const device = try sdl.createGPUDevice(
        sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
        true,
        "vulkan",
    );
    defer sdl.destroyGPUDevice(device);
    log.info("Using backend {s}", .{sdl.getGPUDeviceDriver(device)});

    try sdl.claimWindowForGPUDevice(device, window);

    try sdl.setWindowRelativeMouseMode(window, true);

    // if (sdl.windowSupportsGPUPresentMode(device, window, sdl.c.SDL_GPU_PRESENTMODE_MAILBOX)) {
    //     log.info("Swapchain composition set to mailbox", .{});
    //     try sdl.setGPUSwapchainParameters(
    //         device,
    //         window,
    //         sdl.c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
    //         sdl.c.SDL_GPU_PRESENTMODE_MAILBOX,
    //     );
    // } else if (sdl.windowSupportsGPUPresentMode(
    //     device,
    //     window,
    //     sdl.c.SDL_GPU_PRESENTMODE_IMMEDIATE,
    // )) {
    //     log.info("Swapchain composition set to immediate", .{});
    //     try sdl.setGPUSwapchainParameters(
    //         device,
    //         window,
    //         sdl.c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
    //         sdl.c.SDL_GPU_PRESENTMODE_IMMEDIATE,
    //     );
    // }

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
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_F1 }, .trigger_capture);
    defer input.deinit();

    var draw_pass = try DrawPass.init(gpa, device);
    defer draw_pass.deinit();
    var present_pass = try PresentPass.init(gpa, device, window);
    defer present_pass.deinit();
    var voxelize_pass = try VoxelizePass.init(gpa, device);
    defer voxelize_pass.deinit();
    var debug_pass = try DebugPass.init(gpa, device);
    defer debug_pass.deinit();

    var camera = Camera{
        .pos = zm.f32x4(-4.0, 0.0, 0.0, 1.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .prev_pos = zm.f32x4(-4.0, 0.0, 0.0, 1.0),
        .prev_yaw = 0.0,
        .prev_pitch = 0.0,
    };
    var scene = try Scene.init(gpa, device);
    defer scene.deinit(gpa, device);

    var debug_mode: bool = false;

    var frame_timer = try std.time.Timer.start();
    var lag: u64 = 0;
    var time: f64 = 0.0;

    perf_counter.init(gpa);
    defer perf_counter.deinit();
    var perf_print_timer = try std.time.Timer.start();
    var frame_counter: u32 = 0;

    var first_frame: bool = true;

    frame_timer.reset();
    main_loop: while (true) {
        perf_counter.start("main_loop");
        defer perf_counter.stop("main_loop");
        defer frame_counter += 1;
        if (perf_print_timer.read() >= 1_000_000_000) {
            var it = perf_counter.nameIterator();
            while (it.next()) |name| {
                const stats = perf_counter.stats(name);
                log.info(
                    "{s}:\t{d:.3}\t[{d:.3}-{d:.3}]\t({} FPS)",
                    .{ name, stats[2] * 1e-6, stats[0] * 1e-6, stats[4] * 1e-6, frame_counter },
                );
            }
            perf_print_timer.reset();
            frame_counter = 0;
        }

        // if we had a lagspike, capture a trace
        if (perf_print_timer.read() > 900_000_000 and frame_timer.read() > 20_000_000) {
            try trigger();
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
            camera.update(&input);
            for (scene.objects.items) |*object| object.update(tick);
            if (input.peek(.toggle_debug_view).pressed) debug_mode = !debug_mode;
            if (input.peek(.trigger_capture).pressed) try trigger();
            if (input.peek(.prev_debug_view).pressed) debug_pass.mode = (debug_pass.mode -% 1) % 2;
            if (input.peek(.next_debug_view).pressed) debug_pass.mode = (debug_pass.mode +% 1) % 2;

            input.decay();
            lag -= tick_ns;
            time += 1.0 / @as(f64, @floatFromInt(ticks_per_second));
        }

        const alpha = @as(f32, @floatFromInt(lag)) / @as(f32, @floatFromInt(tick_ns));

        const command_buffer = try sdl.acquireGPUCommandBuffer(device);

        {
            try voxelize_pass.begin(command_buffer);
            for (scene.objects.items) |object| voxelize_pass.voxelizeObject(
                command_buffer,
                object,
                alpha,
            );
            try voxelize_pass.end(command_buffer);
        }

        {
            try draw_pass.begin(
                command_buffer,
                voxelize_pass.opacity_cascades,
                voxelize_pass.radiance_cache_cascades,
            );
            const vp_matrix = camera.vp(alpha);
            for (scene.objects.items) |object| draw_pass.drawObject(
                command_buffer,
                object,
                vp_matrix,
                alpha,
            );
            draw_pass.end(command_buffer);
        }

        if (debug_mode) {
            try debug_pass.run(
                command_buffer,
                voxelize_pass.opacity_cascades,
                voxelize_pass.radiance_cache_cascades,
                camera.v(alpha),
                camera.p(alpha),
            );
        }

        try present_pass.run(
            window,
            command_buffer,
            if (debug_mode) debug_pass.color_target else draw_pass.color_target,
        );

        try sdl.submitGPUCommandBuffer(command_buffer);

        first_frame = false;
    }
}

const VoxelizePass = struct {
    const VoxelizationUBO = extern struct {
        model_matrix: [16]f32 align(16),
        normal_matrix: [16]f32 align(16),
        diffuse: [4]f32 align(16),
        emissive: [4]f32 align(16),
        target_cascades: [2]u32,
        n_triangles: u32,
    };

    const AveragingUBO = extern struct {
        target_cascades: [2]u32 align(16),
        temporal_slots: [2]u32,
        new_cascades_packed: u32,
        blending_factors: [8]f32 align(16),
    };

    comptime {
        std.debug.assert(@offsetOf(AveragingUBO, "target_cascades") == 0);
        std.debug.assert(@offsetOf(AveragingUBO, "temporal_slots") == 8);
        std.debug.assert(@offsetOf(AveragingUBO, "new_cascades_packed") == 16);
        std.debug.assert(@offsetOf(AveragingUBO, "blending_factors") == 32);
    }

    const time_slices = [8][2]u32{
        .{ 0, 1 },
        .{ 2, 3 },
        .{ 0, 1 },
        .{ 4, 5 },
        .{ 0, 1 },
        .{ 2, 3 },
        .{ 0, 1 },
        .{ 6, 7 },
    };
    const maximum_ages = [8]f32{ 2.0, 2.0, 4.0, 4.0, 8.0, 8.0, 8.0, 8.0 };

    device: *sdl.GPUDevice,
    clear_pipeline: *sdl.GPUComputePipeline,
    voxelization_pipeline: *sdl.GPUComputePipeline,
    averaging_pipeline: *sdl.GPUComputePipeline,
    injection_pipeline: *sdl.GPUComputePipeline,
    mipmap_pipeline: *sdl.GPUComputePipeline,

    voxelize_pass: ?*sdl.GPUComputePass = null,
    opacity_targets: *sdl.GPUTexture,
    diffuse_targets: *sdl.GPUTexture,
    emissive_targets: *sdl.GPUTexture,
    opacity_cascades: *sdl.GPUTexture,
    diffuse_cascades: *sdl.GPUTexture,
    emissive_cascades: *sdl.GPUTexture,
    radiance_cache_cascades: *sdl.GPUTexture,

    sampler: *sdl.GPUSampler,

    ix_time_slice: u32 = @intCast(time_slices.len - 1),
    cascade_ages: [8]u32 = [_]u32{0} ** time_slices.len,
    new_cascades_packed: u32 = 0,

    fn init(gpa: std.mem.Allocator, device: *sdl.GPUDevice) !VoxelizePass {
        const clear_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/clear.comp.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUComputePipeline(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .num_samplers = 0,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 0,
                .num_readwrite_storage_textures = 4,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 0,
                .threadcount_x = 4,
                .threadcount_y = 4,
                .threadcount_z = 4,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, clear_pipeline);

        const voxelization_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/voxelization.comp.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUComputePipeline(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .num_samplers = 0,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 2,
                .num_readwrite_storage_textures = 3,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 1,
                .threadcount_x = 64,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, voxelization_pipeline);

        const averaging_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/averaging.comp.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUComputePipeline(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .num_samplers = 3,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 0,
                .num_readwrite_storage_textures = 3,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 1,
                .threadcount_x = 4,
                .threadcount_y = 4,
                .threadcount_z = 4,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, averaging_pipeline);

        const injection_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/inject.comp.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUComputePipeline(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .num_samplers = 3,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 0,
                .num_readwrite_storage_textures = 1,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 0,
                .threadcount_x = 4,
                .threadcount_y = 4,
                .threadcount_z = 4,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, injection_pipeline);

        const mipmap_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/mipmap.comp.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUComputePipeline(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .num_samplers = 0,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 0,
                .num_readwrite_storage_textures = 1,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 1,
                .threadcount_x = 4,
                .threadcount_y = 4,
                .threadcount_z = 4,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, mipmap_pipeline);

        const opacity_targets = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R32_UINT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 2, // two cascades are voxelized each frame
            .height = 66,
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, opacity_targets);

        const diffuse_targets = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R32_UINT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 2, // two cascades are voxelized each frame
            .height = 66,
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, diffuse_targets);

        const emissive_targets = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R32_UINT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 2, // two cascades are voxelized each frame
            .height = 66,
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, emissive_targets);

        const opacity_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 8, // eight cascades of larger and larger voxels
            .height = 66 * 3, // two time slices, and the interpolation for the current frame
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, opacity_cascades);

        const diffuse_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R32_UINT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 8,
            .height = 66 * 3,
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, diffuse_cascades);

        const emissive_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R32_UINT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 8,
            .height = 66 * 3,
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, emissive_cascades);

        const radiance_cache_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 8,
            .height = 66 * 6, // radiance is directional and stored per cardinal direction
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, radiance_cache_cascades);

        const sampler = try sdl.createGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        });
        errdefer sdl.releaseGPUSampler(device, sampler);

        return .{
            .device = device,
            .clear_pipeline = clear_pipeline,
            .voxelization_pipeline = voxelization_pipeline,
            .averaging_pipeline = averaging_pipeline,
            .injection_pipeline = injection_pipeline,
            .mipmap_pipeline = mipmap_pipeline,
            .sampler = sampler,
            .opacity_targets = opacity_targets,
            .diffuse_targets = diffuse_targets,
            .emissive_targets = emissive_targets,
            .opacity_cascades = opacity_cascades,
            .diffuse_cascades = diffuse_cascades,
            .emissive_cascades = emissive_cascades,
            .radiance_cache_cascades = radiance_cache_cascades,
        };
    }

    fn deinit(pass: *VoxelizePass) void {
        sdl.releaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUTexture(pass.device, pass.radiance_cache_cascades);
        sdl.releaseGPUTexture(pass.device, pass.emissive_cascades);
        sdl.releaseGPUTexture(pass.device, pass.diffuse_cascades);
        sdl.releaseGPUTexture(pass.device, pass.opacity_cascades);
        sdl.releaseGPUTexture(pass.device, pass.emissive_targets);
        sdl.releaseGPUTexture(pass.device, pass.diffuse_targets);
        sdl.releaseGPUTexture(pass.device, pass.opacity_targets);
        sdl.releaseGPUComputePipeline(pass.device, pass.mipmap_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.injection_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.averaging_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.voxelization_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.clear_pipeline);
        pass.* = undefined;
    }

    fn begin(pass: *VoxelizePass, command_buffer: *sdl.GPUCommandBuffer) !void {
        pass.ix_time_slice = (pass.ix_time_slice + 1) % @as(u32, @intCast(time_slices.len));
        const time_slice = time_slices[pass.ix_time_slice];
        pass.new_cascades_packed ^= (@as(u32, 1) << @intCast(time_slice[0]));
        pass.new_cascades_packed ^= (@as(u32, 1) << @intCast(time_slice[1]));
        for (0..time_slices.len) |i| pass.cascade_ages[i] += 1;
        pass.cascade_ages[time_slice[0]] = 0;
        pass.cascade_ages[time_slice[1]] = 0;

        // std.debug.print("---\n", .{});
        // std.debug.print("{any}\n", .{time_slice});
        // std.debug.print("{any}\n", .{pass.cascade_ages});
        // std.debug.print("{b:08}\n", .{pass.new_cascades_packed});

        sdl.pushGPUDebugGroup(command_buffer, "voxelize");

        sdl.pushGPUDebugGroup(command_buffer, "clear");
        const clear_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{
                .{ .texture = pass.opacity_targets, .cycle = true },
                .{ .texture = pass.diffuse_targets, .cycle = true },
                .{ .texture = pass.emissive_targets, .cycle = true },
                .{ .texture = pass.radiance_cache_cascades, .cycle = true },
            },
            &.{},
        );
        sdl.bindGPUComputePipeline(clear_pass, pass.clear_pipeline);
        sdl.dispatchGPUCompute(clear_pass, 132, 99, 33);
        sdl.endGPUComputePass(clear_pass);
        sdl.popGPUDebugGroup(command_buffer);

        pass.voxelize_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{
                .{ .texture = pass.opacity_targets },
                .{ .texture = pass.diffuse_targets },
                .{ .texture = pass.emissive_targets },
            },
            &.{},
        );
        sdl.bindGPUComputePipeline(pass.voxelize_pass.?, pass.voxelization_pipeline);
    }

    fn voxelizeObject(
        pass: *VoxelizePass,
        command_buffer: *sdl.GPUCommandBuffer,
        object: Scene.Object,
        alpha: f32,
    ) void {
        sdl.bindGPUComputeStorageBuffers(pass.voxelize_pass.?, 0, &.{
            object.model.vertex_buffer,
            object.model.index_buffer,
        });
        const transform = object.transform(alpha);
        const n_triangles: u32 = object.model.n_indices / 3;
        sdl.pushGPUComputeUniformData(
            command_buffer,
            0,
            &VoxelizationUBO{
                .model_matrix = zm.matToArr(transform),
                .normal_matrix = zm.matToArr(zm.transpose(zm.inverse(transform))),
                .diffuse = object.diffuse,
                .emissive = object.emissive,
                .target_cascades = time_slices[pass.ix_time_slice],
                .n_triangles = n_triangles,
            },
            @sizeOf(VoxelizationUBO),
        );
        sdl.dispatchGPUCompute(
            pass.voxelize_pass.?,
            (n_triangles + 63) / 64,
            2,
            1,
        );
    }

    fn end(
        pass: *VoxelizePass,
        command_buffer: *sdl.GPUCommandBuffer,
    ) !void {
        const time_slice = time_slices[pass.ix_time_slice];
        var blending_factors: [8]f32 = undefined;
        for (0..8) |i| {
            const age: f32 = @floatFromInt(pass.cascade_ages[i]);
            blending_factors[i] = age / maximum_ages[i];
        }
        // std.debug.print("{any}\n", .{blending_factors});

        defer sdl.popGPUDebugGroup(command_buffer);

        sdl.endGPUComputePass(pass.voxelize_pass.?);
        pass.voxelize_pass = null;

        sdl.pushGPUDebugGroup(command_buffer, "average");
        const averaging_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{
                .{ .texture = pass.opacity_cascades },
                .{ .texture = pass.diffuse_cascades },
                .{ .texture = pass.emissive_cascades },
            },
            &.{},
        );
        sdl.bindGPUComputePipeline(averaging_pass, pass.averaging_pipeline);
        sdl.bindGPUComputeSamplers(averaging_pass, 0, &.{
            .{ .texture = pass.opacity_targets, .sampler = pass.sampler },
            .{ .texture = pass.diffuse_targets, .sampler = pass.sampler },
            .{ .texture = pass.emissive_targets, .sampler = pass.sampler },
        });
        sdl.pushGPUComputeUniformData(
            command_buffer,
            0,
            &AveragingUBO{
                .target_cascades = time_slice,
                .temporal_slots = .{
                    (pass.new_cascades_packed >> @intCast(time_slice[0])) & 1,
                    (pass.new_cascades_packed >> @intCast(time_slice[1])) & 1,
                },
                .new_cascades_packed = pass.new_cascades_packed,
                .blending_factors = blending_factors,
            },
            @sizeOf(VoxelizationUBO),
        );
        sdl.dispatchGPUCompute(averaging_pass, 33, 33, 33);
        sdl.endGPUComputePass(averaging_pass);
        sdl.popGPUDebugGroup(command_buffer);

        sdl.pushGPUDebugGroup(command_buffer, "inject");
        const inject_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{.{ .texture = pass.radiance_cache_cascades }},
            &.{},
        );
        sdl.bindGPUComputePipeline(inject_pass, pass.injection_pipeline);
        sdl.bindGPUComputeSamplers(inject_pass, 0, &.{
            .{ .texture = pass.opacity_cascades, .sampler = pass.sampler },
            .{ .texture = pass.diffuse_cascades, .sampler = pass.sampler },
            .{ .texture = pass.emissive_cascades, .sampler = pass.sampler },
        });
        sdl.dispatchGPUCompute(inject_pass, 33, 33, 33);
        sdl.endGPUComputePass(inject_pass);
        sdl.popGPUDebugGroup(command_buffer);

        sdl.pushGPUDebugGroup(command_buffer, "mipmap");
        for (1..8) |i| {
            const mipmap_pass = try sdl.beginGPUComputePass(
                command_buffer,
                &.{.{ .texture = pass.radiance_cache_cascades }},
                &.{},
            );
            sdl.bindGPUComputePipeline(mipmap_pass, pass.mipmap_pipeline);
            sdl.pushGPUComputeUniformData(
                command_buffer,
                0,
                &@as(u32, @intCast(i)),
                @sizeOf(u32),
            );
            sdl.dispatchGPUCompute(mipmap_pass, 8, 48, 8);
            sdl.endGPUComputePass(mipmap_pass);
        }
        sdl.popGPUDebugGroup(command_buffer);
    }
};

const DrawPass = struct {
    const VertexUBO = extern struct {
        mvp_matrix: [16]f32 align(16),
        normal_matrix: [16]f32 align(16),
        model_matrix: [16]f32 align(16),
    };
    const FragmentUBO = extern struct {
        diffuse: [4]f32 align(16),
        emissive: [4]f32 align(16),
        roughness: f32,
    };

    device: *sdl.GPUDevice,
    pipeline: *sdl.GPUGraphicsPipeline,

    draw_pass: ?*sdl.GPURenderPass = null,
    color_target: *sdl.GPUTexture,
    depth_target: *sdl.GPUTexture,
    normal_target: *sdl.GPUTexture,
    sampler: *sdl.GPUSampler,

    fn init(gpa: std.mem.Allocator, device: *sdl.GPUDevice) !DrawPass {
        const vertex_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/draw.vert.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUShader(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_VERTEX,
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 1,
            });
        };
        defer sdl.releaseGPUShader(device, vertex_shader);

        const fragment_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/draw.frag.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUShader(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_FRAGMENT,
                .num_samplers = 2,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 1,
            });
        };
        defer sdl.releaseGPUShader(device, fragment_shader);

        const vertex_buffer_descriptions = [_]sdl.GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = @sizeOf(Scene.Vertex),
            .input_rate = sdl.c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        const vertex_attributes = [_]sdl.GPUVertexAttribute{ .{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .location = 0,
            .offset = @offsetOf(Scene.Vertex, "position"),
        }, .{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .location = 1,
            .offset = @offsetOf(Scene.Vertex, "normal"),
        } };
        const color_target_descriptions = [_]sdl.GPUColorTargetDescription{
            .{ .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT }, // hdr color
            .{ .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16_FLOAT }, // normals
        };
        // i don't like how there's no obvious name for this function in my renaming scheme...
        const depth_stencil_format = if (sdl.c.SDL_GPUTextureSupportsFormat(
            device,
            sdl.c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
            sdl.c.SDL_GPU_TEXTURETYPE_2D,
            sdl.c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        )) sdl.c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT else sdl.c.SDL_GPU_TEXTUREFORMAT_D24_UNORM;
        const pipeline_create_info = sdl.GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &vertex_buffer_descriptions[0],
                .num_vertex_buffers = vertex_buffer_descriptions.len,
                .vertex_attributes = &vertex_attributes[0],
                .num_vertex_attributes = vertex_attributes.len,
            },
            .primitive_type = sdl.c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .rasterizer_state = .{
                .front_face = sdl.c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
                .cull_mode = sdl.c.SDL_GPU_CULLMODE_BACK,
            },
            .multisample_state = .{},
            .depth_stencil_state = .{
                .compare_op = sdl.c.SDL_GPU_COMPAREOP_GREATER,
                .enable_depth_test = true,
                .enable_depth_write = true,
            },
            .target_info = .{
                .color_target_descriptions = &color_target_descriptions[0],
                .num_color_targets = color_target_descriptions.len,
                .depth_stencil_format = @intCast(depth_stencil_format),
                .has_depth_stencil_target = true,
            },
        };
        const pipeline = try sdl.createGPUGraphicsPipeline(device, &pipeline_create_info);
        errdefer sdl.releaseGPUGraphicsPipeline(device, pipeline);

        const color_target = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = window_width,
            .height = window_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, color_target);

        const depth_target = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = @intCast(depth_stencil_format),
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = window_width,
            .height = window_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, depth_target);

        const normal_target = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = window_width,
            .height = window_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, normal_target);

        const sampler = try sdl.createGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        });
        errdefer sdl.releaseGPUSampler(device, sampler);

        return .{
            .device = device,
            .pipeline = pipeline,
            .color_target = color_target,
            .depth_target = depth_target,
            .normal_target = normal_target,
            .sampler = sampler,
        };
    }

    fn deinit(pass: *DrawPass) void {
        sdl.releaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUTexture(pass.device, pass.normal_target);
        sdl.releaseGPUTexture(pass.device, pass.depth_target);
        sdl.releaseGPUTexture(pass.device, pass.color_target);
        sdl.releaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn begin(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
        opacity_cascades: *sdl.GPUTexture,
        radiance_cache_cascades: *sdl.GPUTexture,
    ) !void {
        sdl.pushGPUDebugGroup(command_buffer, "draw");

        const color_target_infos = [_]sdl.GPUColorTargetInfo{
            .{
                .texture = pass.color_target,
                .clear_color = sdl.FColor{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 },
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
            .{
                .texture = pass.normal_target,
                .clear_color = sdl.FColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
        };
        pass.draw_pass = try sdl.beginGPURenderPass(
            command_buffer,
            &color_target_infos,
            &.{
                .texture = pass.depth_target,
                .clear_depth = 0,
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
        );
        sdl.bindGPUGraphicsPipeline(pass.draw_pass.?, pass.pipeline);
        sdl.bindGPUFragmentSamplers(pass.draw_pass.?, 0, &.{
            .{ .texture = opacity_cascades, .sampler = pass.sampler },
            .{ .texture = radiance_cache_cascades, .sampler = pass.sampler },
        });
    }

    fn drawObject(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
        object: Scene.Object,
        camera_vp: zm.Mat,
        alpha: f32,
    ) void {
        const vertex_buffers = [_]sdl.c.SDL_GPUBufferBinding{
            .{ .buffer = object.model.vertex_buffer, .offset = 0 },
        };
        sdl.bindGPUVertexBuffers(
            pass.draw_pass.?,
            0,
            &vertex_buffers,
        );
        sdl.bindGPUIndexBuffer(
            pass.draw_pass.?,
            &.{ .buffer = object.model.index_buffer, .offset = 0 },
            sdl.c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
        );
        const model = object.transform(alpha);
        const mvp = zm.mul(model, camera_vp);
        const normal = zm.transpose(zm.inverse(model));
        sdl.pushGPUVertexUniformData(command_buffer, 0, &VertexUBO{
            .mvp_matrix = zm.matToArr(mvp),
            .normal_matrix = zm.matToArr(normal),
            .model_matrix = zm.matToArr(model),
        }, @sizeOf(VertexUBO));
        sdl.pushGPUFragmentUniformData(command_buffer, 0, &FragmentUBO{
            .diffuse = object.diffuse,
            .emissive = object.emissive,
            .roughness = object.roughness,
        }, @sizeOf(FragmentUBO));
        sdl.drawGPUIndexedPrimitives(pass.draw_pass.?, object.model.n_indices, 1, 0, 0, 0);
    }

    fn end(pass: *DrawPass, command_buffer: *sdl.GPUCommandBuffer) void {
        defer sdl.popGPUDebugGroup(command_buffer);

        sdl.endGPURenderPass(pass.draw_pass.?);
        pass.draw_pass = null;
    }
};

const PresentPass = struct {
    const Vertex = struct {
        position: [3]f32,
        texcoords: [2]f32,
    };

    const full_screen_quad = [_]Vertex{
        .{ .position = .{ -1, 1, 0 }, .texcoords = .{ 0, 0 } },
        .{ .position = .{ 1, 1, 0 }, .texcoords = .{ 1, 0 } },
        .{ .position = .{ 1, -1, 0 }, .texcoords = .{ 1, 1 } },
        .{ .position = .{ -1, 1, 0 }, .texcoords = .{ 0, 0 } },
        .{ .position = .{ 1, -1, 0 }, .texcoords = .{ 1, 1 } },
        .{ .position = .{ -1, -1, 0 }, .texcoords = .{ 0, 1 } },
    };

    device: *sdl.GPUDevice,
    pipeline: *sdl.GPUGraphicsPipeline,
    vertex_buffer: *sdl.GPUBuffer,
    sampler: *sdl.GPUSampler,

    fn init(
        gpa: std.mem.Allocator,
        device: *sdl.GPUDevice,
        window: *sdl.Window,
    ) !PresentPass {
        const vertex_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/present.vert.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUShader(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_VERTEX,
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 0,
            });
        };
        defer sdl.releaseGPUShader(device, vertex_shader);

        const fragment_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/present.frag.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUShader(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_FRAGMENT,
                .num_samplers = 1,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 0,
            });
        };
        defer sdl.releaseGPUShader(device, fragment_shader);

        const vertex_buffer_descriptions = [_]sdl.GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = @sizeOf(Vertex),
            .input_rate = sdl.c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        const vertex_attributes = [_]sdl.GPUVertexAttribute{ .{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .location = 0,
            .offset = @offsetOf(Vertex, "position"),
        }, .{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .location = 1,
            .offset = @offsetOf(Vertex, "texcoords"),
        } };
        const color_target_descriptions = [_]sdl.GPUColorTargetDescription{.{
            .format = sdl.getGPUSwapchainTextureFormat(device, window),
            .blend_state = .{},
        }};
        const pipeline_create_info = sdl.GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &vertex_buffer_descriptions[0],
                .num_vertex_buffers = vertex_buffer_descriptions.len,
                .vertex_attributes = &vertex_attributes[0],
                .num_vertex_attributes = vertex_attributes.len,
            },
            .primitive_type = sdl.c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .rasterizer_state = .{},
            .multisample_state = .{},
            .depth_stencil_state = .{},
            .target_info = .{
                .color_target_descriptions = &color_target_descriptions[0],
                .num_color_targets = color_target_descriptions.len,
            },
        };
        const pipeline = try sdl.createGPUGraphicsPipeline(device, &pipeline_create_info);
        errdefer sdl.releaseGPUGraphicsPipeline(device, pipeline);

        const sizeof_vertices: u32 = @intCast(full_screen_quad.len * @sizeOf(Vertex));
        const vertex_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = sizeof_vertices,
        });
        errdefer sdl.releaseGPUBuffer(device, vertex_buffer);
        const transfer_buffer = try sdl.createGPUTransferBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = sizeof_vertices,
        });
        defer sdl.releaseGPUTransferBuffer(device, transfer_buffer);
        const command_buffer = try sdl.acquireGPUCommandBuffer(device);
        const bytes: [*]u8 = @alignCast(@ptrCast(
            try sdl.mapGPUTransferBuffer(device, transfer_buffer, true),
        ));
        @memcpy(@as([*]Vertex, @alignCast(@ptrCast(bytes))), &full_screen_quad);
        sdl.unmapGPUTransferBuffer(device, transfer_buffer);
        const copy_pass = try sdl.beginGPUCopyPass(command_buffer);
        sdl.uploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, &.{
            .buffer = vertex_buffer,
            .offset = 0,
            .size = sizeof_vertices,
        }, false);
        sdl.endGPUCopyPass(copy_pass);
        try sdl.submitGPUCommandBuffer(command_buffer);

        const sampler = try sdl.createGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        });
        errdefer sdl.releaseGPUSampler(device, sampler);

        return .{
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .sampler = sampler,
        };
    }

    fn deinit(pass: *PresentPass) void {
        sdl.releaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUBuffer(pass.device, pass.vertex_buffer);
        sdl.releaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn run(
        pass: *PresentPass,
        window: *sdl.Window,
        command_buffer: *sdl.GPUCommandBuffer,
        backbuffer: *sdl.GPUTexture,
    ) !void {
        var swapchain_texture: ?*sdl.GPUTexture = null;
        var swapchain_width: u32 = 0;
        var swapchain_height: u32 = 0;
        try sdl.waitAndAcquireGPUSwapchainTexture(
            command_buffer,
            window,
            &swapchain_texture,
            &swapchain_width,
            &swapchain_height,
        );
        if (swapchain_texture == null) {
            log.debug("Failed to acquire swapchain texture", .{});
            return;
        }

        const color_target_infos = [_]sdl.GPUColorTargetInfo{
            .{ .texture = swapchain_texture, .load_op = sdl.c.SDL_GPU_LOADOP_DONT_CARE },
        };
        const render_pass = try sdl.beginGPURenderPass(
            command_buffer,
            &color_target_infos,
            null,
        );
        sdl.bindGPUGraphicsPipeline(render_pass, pass.pipeline);
        const vertex_buffers = [_]sdl.GPUBufferBinding{
            .{ .buffer = pass.vertex_buffer, .offset = 0 },
        };
        sdl.bindGPUVertexBuffers(render_pass, 0, &vertex_buffers);
        const sampler_bindings = [_]sdl.GPUTextureSamplerBinding{
            .{ .texture = backbuffer, .sampler = pass.sampler },
        };
        sdl.bindGPUFragmentSamplers(render_pass, 0, &sampler_bindings);
        sdl.drawGPUPrimitives(render_pass, 6, 1, 0, 0);
        sdl.endGPURenderPass(render_pass);
    }
};

const DebugPass = struct {
    const Vertex = struct {
        position: [3]f32,
    };

    const VertexUBO = extern struct {
        inverse_view_matrix: [16]f32 align(16),
        inverse_projection_matrix: [16]f32 align(16),
    };

    const full_screen_quad = [_]Vertex{
        .{ .position = .{ -1, 1, 0 } },
        .{ .position = .{ 1, 1, 0 } },
        .{ .position = .{ 1, -1, 0 } },
        .{ .position = .{ -1, 1, 0 } },
        .{ .position = .{ 1, -1, 0 } },
        .{ .position = .{ -1, -1, 0 } },
    };

    device: *sdl.GPUDevice,
    pipeline: *sdl.GPUGraphicsPipeline,
    vertex_buffer: *sdl.GPUBuffer,
    sampler: *sdl.GPUSampler,
    color_target: *sdl.GPUTexture,

    mode: u32 = 0,

    fn init(
        gpa: std.mem.Allocator,
        device: *sdl.GPUDevice,
    ) !DebugPass {
        const vertex_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/debug.vert.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUShader(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_VERTEX,
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 1,
            });
        };
        defer sdl.releaseGPUShader(device, vertex_shader);

        const fragment_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/debug.frag.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
            defer gpa.free(bytes);

            break :blk try sdl.createGPUShader(device, &.{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_FRAGMENT,
                .num_samplers = 2,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 1,
            });
        };
        defer sdl.releaseGPUShader(device, fragment_shader);

        const vertex_buffer_descriptions = [_]sdl.GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = @sizeOf(Vertex),
            .input_rate = sdl.c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        const vertex_attributes = [_]sdl.GPUVertexAttribute{.{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .location = 0,
            .offset = @offsetOf(Vertex, "position"),
        }};
        const color_target_descriptions = [_]sdl.GPUColorTargetDescription{.{
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .blend_state = .{},
        }};
        const pipeline_create_info = sdl.GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &vertex_buffer_descriptions[0],
                .num_vertex_buffers = vertex_buffer_descriptions.len,
                .vertex_attributes = &vertex_attributes[0],
                .num_vertex_attributes = vertex_attributes.len,
            },
            .primitive_type = sdl.c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .rasterizer_state = .{},
            .multisample_state = .{},
            .depth_stencil_state = .{},
            .target_info = .{
                .color_target_descriptions = &color_target_descriptions[0],
                .num_color_targets = color_target_descriptions.len,
            },
        };
        const pipeline = try sdl.createGPUGraphicsPipeline(device, &pipeline_create_info);
        errdefer sdl.releaseGPUGraphicsPipeline(device, pipeline);

        const sizeof_vertices: u32 = @intCast(full_screen_quad.len * @sizeOf(Vertex));
        const vertex_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = sizeof_vertices,
        });
        errdefer sdl.releaseGPUBuffer(device, vertex_buffer);
        const transfer_buffer = try sdl.createGPUTransferBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = sizeof_vertices,
        });
        defer sdl.releaseGPUTransferBuffer(device, transfer_buffer);
        const command_buffer = try sdl.acquireGPUCommandBuffer(device);
        const bytes: [*]u8 = @alignCast(@ptrCast(
            try sdl.mapGPUTransferBuffer(device, transfer_buffer, true),
        ));
        @memcpy(@as([*]Vertex, @alignCast(@ptrCast(bytes))), &full_screen_quad);
        sdl.unmapGPUTransferBuffer(device, transfer_buffer);
        const copy_pass = try sdl.beginGPUCopyPass(command_buffer);
        sdl.uploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, &.{
            .buffer = vertex_buffer,
            .offset = 0,
            .size = sizeof_vertices,
        }, false);
        sdl.endGPUCopyPass(copy_pass);
        try sdl.submitGPUCommandBuffer(command_buffer);

        const sampler = try sdl.createGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        });
        errdefer sdl.releaseGPUSampler(device, sampler);

        const color_target = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = window_width / 3,
            .height = window_height / 3,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, color_target);

        return .{
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .sampler = sampler,
            .color_target = color_target,
        };
    }

    fn deinit(pass: *DebugPass) void {
        sdl.releaseGPUTexture(pass.device, pass.color_target);
        sdl.releaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUBuffer(pass.device, pass.vertex_buffer);
        sdl.releaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn run(
        pass: *DebugPass,
        command_buffer: *sdl.GPUCommandBuffer,
        opacity_cascades: *sdl.GPUTexture,
        radiance_cache_cascades: *sdl.GPUTexture,
        camera_v: zm.Mat,
        camera_p: zm.Mat,
    ) !void {
        const color_target_infos = [_]sdl.GPUColorTargetInfo{.{
            .texture = pass.color_target,
            .load_op = sdl.c.SDL_GPU_LOADOP_DONT_CARE,
            .cycle = true,
        }};
        const render_pass = try sdl.beginGPURenderPass(
            command_buffer,
            &color_target_infos,
            null,
        );
        sdl.bindGPUGraphicsPipeline(render_pass, pass.pipeline);
        const vertex_buffers = [_]sdl.GPUBufferBinding{
            .{ .buffer = pass.vertex_buffer, .offset = 0 },
        };
        sdl.bindGPUVertexBuffers(render_pass, 0, &vertex_buffers);
        const sampler_bindings = [_]sdl.GPUTextureSamplerBinding{
            .{ .texture = opacity_cascades, .sampler = pass.sampler },
            .{ .texture = radiance_cache_cascades, .sampler = pass.sampler },
        };
        sdl.bindGPUFragmentSamplers(render_pass, 0, &sampler_bindings);
        sdl.c.SDL_PushGPUVertexUniformData(
            command_buffer,
            0,
            &VertexUBO{
                .inverse_view_matrix = zm.matToArr(zm.inverse(camera_v)),
                .inverse_projection_matrix = zm.matToArr(zm.inverse(camera_p)),
            },
            @sizeOf(VertexUBO),
        );
        sdl.c.SDL_PushGPUFragmentUniformData(
            command_buffer,
            0,
            &pass.mode,
            @sizeOf(u32),
        );
        sdl.drawGPUPrimitives(render_pass, 6, 1, 0, 0);
        sdl.endGPURenderPass(render_pass);
    }
};

const Camera = struct {
    pos: zm.Vec,
    yaw: f32,
    pitch: f32,

    prev_pos: zm.Vec,
    prev_yaw: f32,
    prev_pitch: f32,

    const up = zm.f32x4(0.0, 1.0, 0.0, 0.0);
    const mouse_sensitivity = 0.3;
    const move_speed = 10;

    fn update(camera: *Camera, input: *Input) void {
        // mouse-look camera
        camera.prev_pos = camera.pos;
        camera.prev_yaw = camera.yaw;
        camera.prev_pitch = camera.pitch;

        camera.yaw += input.mouse_delta[0] * mouse_sensitivity * tick;
        camera.pitch -= input.mouse_delta[1] * mouse_sensitivity * tick;
        camera.pitch = std.math.clamp(camera.pitch, -0.49 * std.math.pi, 0.49 * std.math.pi);

        const forward = zm.f32x4(
            @cos(camera.yaw),
            0.0,
            @sin(camera.yaw),
            0.0,
        ) * zm.f32x4s(move_speed * tick);

        const right = zm.f32x4(
            @cos(camera.yaw + 0.5 * std.math.pi),
            0.0,
            @sin(camera.yaw + 0.5 * std.math.pi),
            0.0,
        ) * zm.f32x4s(move_speed * tick);

        if (input.peek(.forward).held) camera.pos += forward;
        if (input.peek(.backward).held) camera.pos -= forward;
        if (input.peek(.right).held) camera.pos += right;
        if (input.peek(.left).held) camera.pos -= right;
        if (input.peek(.up).held) camera.pos += up * zm.f32x4s(move_speed * tick);
        if (input.peek(.down).held) camera.pos -= up * zm.f32x4s(move_speed * tick);
    }

    fn v(camera: Camera, alpha: f32) zm.Mat {
        const pos = zm.lerp(camera.prev_pos, camera.pos, alpha);
        const yaw = (1 - alpha) * camera.prev_yaw + alpha * camera.yaw;
        const pitch = (1 - alpha) * camera.prev_pitch + alpha * camera.pitch;

        const facing = zm.normalize3(zm.f32x4(
            @cos(pitch) * @cos(yaw),
            @sin(pitch),
            @cos(pitch) * @sin(yaw),
            0.0,
        ));

        return zm.lookAtRh(pos, pos + facing, up);
    }

    fn p(camera: Camera, alpha: f32) zm.Mat {
        _ = camera;
        _ = alpha;
        return perspectiveFovRhInv(std.math.degreesToRadians(54), 16.0 / 9.0, 0.1, 1e5);
    }

    fn vp(camera: Camera, alpha: f32) zm.Mat {
        return zm.mul(
            camera.v(alpha),
            camera.p(alpha),
        );
    }
};

pub fn perspectiveFovRhInv(fovy: f32, aspect: f32, near: f32, far: f32) zm.Mat {
    const scfov = zm.sincos(0.5 * fovy);

    std.debug.assert(near > 0.0 and far > 0.0);
    std.debug.assert(!std.math.approxEqAbs(f32, scfov[0], 0.0, 0.001));
    std.debug.assert(!std.math.approxEqAbs(f32, far, near, 0.001));
    std.debug.assert(!std.math.approxEqAbs(f32, aspect, 0.0, 0.01));

    const h = scfov[1] / scfov[0];
    const w = h / aspect;
    const r = far / (near - far);
    return .{
        zm.f32x4(w, 0.0, 0.0, 0.0),
        zm.f32x4(0.0, h, 0.0, 0.0),
        zm.f32x4(0.0, 0.0, -r - 1.0, -1.0),
        zm.f32x4(0.0, 0.0, -r * near, 0.0),
    };
}

fn trigger() !void {
    if (@import("builtin").os.tag != .linux) return;

    var dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer dir.close();
    var file = try dir.createFile("trigger", .{ .truncate = true });
    defer file.close();
}

const random_u32_bits: [32][128]u32 = .{
    .{ 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000 },
    .{ 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004 },
    .{ 0x00800004, 0x00100004, 0x00002010, 0x00002400, 0x000000a0, 0x00018000, 0x00100010, 0x000000a0, 0x00000220, 0x00100010, 0x02000100, 0x00000220, 0x00018000, 0x00004002, 0x00000082, 0x00004002, 0x00800002, 0x00000220, 0x02000100, 0x40000400, 0x02000100, 0x00408000, 0x00800004, 0x00002010, 0x00408000, 0x00800002, 0x00004002, 0x40000400, 0x00100010, 0x000000a0, 0x000000a0, 0x00800002, 0x00002400, 0x00004002, 0x00002400, 0x00100010, 0x00800004, 0x00800004, 0x00800004, 0x00408000, 0x000000a0, 0x00002010, 0x00000082, 0x02000100, 0x00002400, 0x00100004, 0x00000082, 0x00018000, 0x00002400, 0x00800004, 0x40000400, 0x00202000, 0x00800002, 0x00800002, 0x00002010, 0x00800004, 0x000000a0, 0x00002400, 0x00002010, 0x40000400, 0x00800002, 0x00018000, 0x00002010, 0x00004002, 0x00000082, 0x02000100, 0x00018000, 0x000000a0, 0x00100004, 0x00408000, 0x00018000, 0x00002010, 0x40000400, 0x02000100, 0x00084000, 0x00084000, 0x40000400, 0x00018000, 0x00004002, 0x00018000, 0x00084000, 0x00100010, 0x02000100, 0x00800004, 0x00000082, 0x00000082, 0x00004002, 0x00018000, 0x00408000, 0x40000400, 0x00408000, 0x00408000, 0x00100010, 0x00100010, 0x00800004, 0x00084000, 0x00002400, 0x00002400, 0x00800004, 0x000000a0, 0x00202000, 0x02000100, 0x00100010, 0x00000220, 0x00202000, 0x00002400, 0x00800004, 0x000000a0, 0x02000100, 0x000000a0, 0x00800004, 0x00002400, 0x00002010, 0x00100010, 0x00002010, 0x00004002, 0x00100010, 0x40000400, 0x000000a0, 0x00004002, 0x00000082, 0x00800002, 0x40000400, 0x02000100, 0x00000220, 0x00100004, 0x00800002, 0x00100010 },
    .{ 0x20001400, 0x000000a1, 0x00003020, 0x20060000, 0x00022001, 0x82000040, 0x80800400, 0x00080104, 0x00405000, 0x00801001, 0x00300010, 0x10400400, 0x00048008, 0x31000000, 0x20001010, 0x10088000, 0x81800000, 0x01004800, 0x00800801, 0x08480000, 0x00228000, 0x000a0100, 0x00022020, 0x84200000, 0x00020440, 0x00340000, 0x10480000, 0x00005800, 0x04000120, 0x01200008, 0x00100802, 0x90100000, 0x00040006, 0x44000004, 0x00800044, 0x00140040, 0x10000140, 0x00210020, 0x00002408, 0x00009100, 0x00082004, 0x00080060, 0x00000184, 0x80500000, 0x10440000, 0x10000014, 0x00100410, 0x00000700, 0x02001200, 0x00084100, 0x04002100, 0x00009800, 0x00004180, 0x04010001, 0x20030000, 0x00c00020, 0x08000140, 0x02800080, 0x02002200, 0x0c001000, 0x40001010, 0x00404800, 0x02002002, 0x02800100, 0x01005000, 0x01480000, 0x01000060, 0x00008402, 0x40000014, 0x10010800, 0x10000240, 0x01210000, 0x01002100, 0x41000080, 0x00404001, 0x00018008, 0x20408000, 0x00080050, 0x00140010, 0x80100001, 0x40000180, 0x04001080, 0x20024000, 0x00808400, 0x00041040, 0x40200004, 0x00040081, 0x00430000, 0x00000c01, 0x00000032, 0x10100020, 0x20000820, 0x60800000, 0x00810020, 0x00008021, 0x04020100, 0x08210000, 0x20080010, 0x00408008, 0x0000100c, 0x04a00000, 0x00000150, 0x01004010, 0x40000012, 0x0a000002, 0x08008200, 0x10008008, 0x40200040, 0x04010020, 0x80008080, 0x04800002, 0x44001000, 0x00008048, 0x00108020, 0x60000004, 0x40009000, 0x08404000, 0x00040204, 0x40400800, 0x00100402, 0x00008408, 0x00010402, 0x80400040, 0x22000020, 0x04800400, 0x0400000c, 0x00002140, 0x00002081 },
    .{ 0x04081400, 0x10009004, 0x24009000, 0x48080002, 0x00800212, 0x08020028, 0x04260000, 0x02000c02, 0x02400003, 0x40040500, 0x06004040, 0x004a0100, 0x00882010, 0x40002404, 0x00803001, 0x06004001, 0x00808280, 0x80023000, 0x200c0008, 0x00844001, 0x00520100, 0x00200608, 0x00040842, 0x06020004, 0x12200008, 0x0000210a, 0x1a000040, 0x00083400, 0x80040900, 0x00208102, 0x00208022, 0x10082002, 0x001020a0, 0x08800012, 0x82400008, 0x10620000, 0x04083000, 0x0200a400, 0x20804020, 0x00100250, 0x00402240, 0x84002002, 0x00090018, 0x10000061, 0x000104c0, 0x02808080, 0x04021008, 0x40040280, 0x00009880, 0x00030050, 0x000020c1, 0x10900010, 0x00029080, 0x04604000, 0xc2000008, 0x22020008, 0x13000080, 0x0b000080, 0x10000e00, 0x84100008, 0x48400004, 0x02020101, 0x08004208, 0x08000821, 0x00420440, 0x00004482, 0x21002100, 0x80842000, 0x40402800, 0x01020210, 0x00200114, 0x00000a88, 0x00081102, 0x08080084, 0x00850100, 0x00028021, 0x28000082, 0x01081800, 0x02081008, 0x00044082, 0x00802420, 0x04004208, 0x02101200, 0x02008300, 0x0a080080, 0x88008001, 0x00010442, 0x40040012, 0x00884040, 0x00048003, 0x0000011c, 0x00104030, 0xa0120000, 0x88000240, 0x40000441, 0x40020081, 0x00003110, 0x08404001, 0x0c0c0000, 0x00845000, 0x08002041, 0x00020031, 0x00980800, 0x00001112, 0x28100400, 0x02100202, 0x2000100c, 0x81080001, 0x08402040, 0x08400030, 0x09000900, 0x20800808, 0x10011400, 0x81000006, 0x01050800, 0x01802001, 0x040a0400, 0x21000804, 0x04808400, 0x4a000040, 0x010d0000, 0x04004810, 0x000a00a0, 0x00058200, 0x0000005c, 0x10018002, 0xc4000001, 0x00181100 },
    .{ 0x0a300008, 0x08024440, 0x21020280, 0xc0420400, 0x01000491, 0x00600814, 0x00088284, 0x40801082, 0x48012020, 0x04600108, 0x20444800, 0x08180440, 0x40110600, 0x000282a0, 0x20260004, 0x0104a008, 0x10402210, 0x02014088, 0x00210484, 0x44804010, 0x08200380, 0x80012022, 0x0c804100, 0x80041a00, 0x00180620, 0x00208504, 0x20800244, 0x41000405, 0x50041010, 0x20411080, 0x00008889, 0x41101400, 0x01449000, 0xc0009040, 0x88a00020, 0x42002408, 0x10100019, 0x02403001, 0x20c20400, 0x10112020, 0x60080006, 0x28042800, 0x60c00400, 0x00a08012, 0x20140480, 0x22800110, 0x01418200, 0x02410088, 0x84040011, 0x00052021, 0x40200122, 0x81044100, 0x01009c00, 0x2100a008, 0x50082100, 0x70010004, 0x0c004030, 0xc0100880, 0x80005011, 0xa0022001, 0x000410c8, 0x90210080, 0x48040a00, 0x43000088, 0x46024000, 0x02804024, 0x60002801, 0x88002802, 0x94000050, 0x0a104010, 0x84108008, 0x14420010, 0x40800901, 0x02010124, 0x01004190, 0x30202004, 0x20450020, 0x00200624, 0x10001430, 0x01209400, 0x04406800, 0xc1008001, 0x02900102, 0x00940081, 0x24800201, 0x20102300, 0x0e008004, 0x80040502, 0x22000812, 0x00010524, 0x00120c20, 0x28024001, 0x09801400, 0x002d4000, 0x08818400, 0x80044204, 0x10068080, 0x00608820, 0x02601080, 0x18200808, 0x04101060, 0x01104082, 0x02180104, 0x60180400, 0x0040c480, 0x210a2000, 0x8e001000, 0x00800c90, 0x0048010c, 0x49400100, 0x44401400, 0xa0800300, 0xc0400802, 0x40228200, 0x40cc0000, 0x04092080, 0x0000010f, 0x00614001, 0x40102120, 0x41800101, 0x02208880, 0x00820121, 0x08811200, 0x48600800, 0x00154010, 0x10027000, 0x08104404, 0x22880100 },
    .{ 0xa2022001, 0x00200632, 0x04224108, 0x10040312, 0x01032404, 0x00826110, 0x24020442, 0x10054110, 0x8014a080, 0x01a06800, 0x01000c0e, 0x020102a2, 0x80008072, 0x00aa4100, 0x8880a400, 0x034004c0, 0x1c000211, 0x19000142, 0x0090440a, 0x01076000, 0x25800810, 0x46908000, 0x00226044, 0x10804206, 0x05401014, 0x88004260, 0x04008225, 0x8a058000, 0x084c00a0, 0x8c820001, 0x09000390, 0x26012080, 0x19002011, 0x18000ac0, 0x90810101, 0x0001032c, 0x200092c0, 0x20300803, 0x04009409, 0x81406002, 0x24118010, 0x40430480, 0x04810098, 0x06141080, 0x28a02001, 0x01400234, 0x90120802, 0x280a8004, 0x04160041, 0x01540021, 0xf2080000, 0x0a140401, 0x09500104, 0x81045100, 0x0060c202, 0x10808086, 0x04804301, 0x2000a422, 0x010a3010, 0x100908c0, 0x0020c409, 0x04101510, 0x03a00300, 0x40201092, 0x02089044, 0x34800840, 0x50204011, 0x0012c050, 0x80c20104, 0x02180822, 0x08090610, 0x00980510, 0x82808408, 0x402a8400, 0x01544040, 0x04206220, 0x02004309, 0x804c1020, 0x04128a00, 0xc0014108, 0x6000808c, 0x0a808500, 0x001400c9, 0x000a2421, 0x018c0401, 0x08011290, 0x04817000, 0x31020030, 0x00006a09, 0x40420d00, 0x41040301, 0x09824010, 0x10082803, 0x82c42000, 0xa2800802, 0x01004642, 0x00020b05, 0x012420c0, 0x4008c042, 0x81001301, 0x4c040240, 0x08584004, 0xc0300060, 0x880120c0, 0x09003048, 0x020a2401, 0x0015100c, 0x18240402, 0x12210280, 0xd8000084, 0xc00a0600, 0x88308400, 0x0c048041, 0x50014018, 0x45020003, 0x82480024, 0x04211050, 0x00708120, 0x44091002, 0x08014032, 0x00501288, 0x80808019, 0x90488040, 0x00210123, 0x00411111, 0x84821020, 0x08810803, 0x0102e100 },
    .{ 0x51800211, 0x1080d009, 0x0208089a, 0x814c8100, 0x300c8006, 0xc0001486, 0x42c0100a, 0x44100a90, 0x602a0801, 0x208010ac, 0x92940020, 0x42406420, 0x10010545, 0x31408500, 0x1d008440, 0x1a014014, 0x12180211, 0xc2028404, 0x3ce00000, 0x82124140, 0x4080809a, 0x80c240a0, 0x40110107, 0x1202a014, 0x40028660, 0x40940160, 0x08185880, 0x05004922, 0x49001a40, 0x280d8010, 0x01491840, 0x00182c14, 0x3008800d, 0x082140e0, 0x004160c4, 0x41808409, 0x44021089, 0x08454802, 0x88908201, 0x08018348, 0x81016440, 0x4a022120, 0x80001478, 0x4804c00c, 0x404090c2, 0x38342000, 0x85201050, 0x00f20820, 0x208208c4, 0x0034c028, 0x10041816, 0x45004380, 0x44c09100, 0x00403192, 0x880240e0, 0xc0024380, 0x04930840, 0x60108141, 0x58040680, 0x01105121, 0x0c802806, 0x08040cc8, 0x80002615, 0x44c0c001, 0xf0088020, 0x0a1420a0, 0x40a01203, 0x0c860108, 0x70204208, 0x008060cc, 0x38100460, 0x02094320, 0x05020454, 0x38102300, 0x1c009208, 0x0110b006, 0x800284d0, 0x06904022, 0xd8000848, 0x80013016, 0x20406501, 0x02d00121, 0x068a5000, 0x054a2800, 0x0844a018, 0x04192022, 0x89040128, 0x78004404, 0x40023114, 0x1010404b, 0x80682011, 0x0400128e, 0x01110b80, 0x13041030, 0x481c8080, 0x0d001540, 0xa8a10200, 0x28010229, 0x15018180, 0x45020828, 0x14808920, 0x810c20a0, 0x0020c590, 0x4c282010, 0x0a062300, 0x00088994, 0xe0180600, 0x42001134, 0x0001e0c4, 0x10a100d0, 0x53008402, 0x04030642, 0x0b240009, 0x40183808, 0x80526400, 0x92403800, 0x09888810, 0x4002900e, 0x18280026, 0x81181081, 0x90504021, 0x022080e4, 0x0414810c, 0x40018324, 0x029a8200, 0x09004305, 0x00221834, 0x80032308 },
    .{ 0x400c1a42, 0x60800a51, 0x118104a8, 0x40846244, 0x42400398, 0x0030f204, 0x94001462, 0x20206305, 0x0d113800, 0x40c84085, 0x62100740, 0x91700030, 0x4290012a, 0x42034a80, 0x08030cc8, 0x6002c112, 0x708a4001, 0x00014aa6, 0x384d0080, 0xcb080c00, 0x80801a86, 0x15900190, 0x1a2d8000, 0x11910805, 0x09408584, 0x00863412, 0x1820224c, 0x46032820, 0x6a340010, 0x402b8802, 0x4004403d, 0x38081142, 0x30991008, 0x20520930, 0x02a04831, 0xb08a6000, 0xa5208024, 0xa0108322, 0x86464400, 0x4a40a500, 0x0222a4c0, 0x0c82c210, 0x02c04053, 0x411c0c01, 0xc9884400, 0xa000031d, 0x70360002, 0x444011c8, 0x88606090, 0x0144d480, 0x5c060420, 0x20600712, 0xb0703000, 0x8010d0c1, 0x04320911, 0x4818c00a, 0xc20a8402, 0xc80058a0, 0xbc004808, 0x280080dc, 0x1148c180, 0x94200852, 0xd0203240, 0x40412243, 0x004b2211, 0x0302c405, 0x488402c8, 0x60524048, 0x4404018b, 0x0b244240, 0x00180c35, 0x8c810842, 0x12046484, 0x3100a302, 0x87240041, 0x46884005, 0x4280128a, 0x902106a0, 0xa4012a80, 0x14281c01, 0x29400514, 0x18a08860, 0x1618c100, 0x0a031205, 0x24340281, 0x14042984, 0x30052418, 0x2c8440a0, 0x0c1aa002, 0x01441027, 0x0380502a, 0x08002a53, 0x31900405, 0x84600154, 0x0182c130, 0x1c2a0440, 0x8a300910, 0x01885160, 0x44c50120, 0x80065c40, 0x819010d0, 0x504008d4, 0x0144824a, 0xa0010c2a, 0x058980c0, 0x40a28190, 0x110e2006, 0x14421244, 0x10171402, 0x94001449, 0x03702009, 0xc44a2080, 0x01112243, 0x30884940, 0xa2070014, 0x00410758, 0x83850804, 0x4e900022, 0x0480360a, 0x22b0c004, 0x90031061, 0x20185112, 0x084c5410, 0x80348441, 0x4c04c808, 0x51002611, 0x89300124, 0x2c6000c8 },
    .{ 0x208445a4, 0x27c04021, 0xa5810c01, 0xc6050580, 0x05822a44, 0x57442004, 0x020583a2, 0x02e3080a, 0x20e84422, 0x04a48d02, 0x49800b21, 0x00b21036, 0x0112013e, 0x5d0280a0, 0x84026912, 0x50c22484, 0x1c20d082, 0x2042da10, 0x1da00114, 0x18b05801, 0x4a800a1c, 0x40445438, 0x4488ca20, 0x8524040e, 0x401041dc, 0x031a0524, 0x44210c54, 0x0308704c, 0x4610a608, 0x81414039, 0x4a00e821, 0xb2221408, 0x805a0486, 0x304c0107, 0x08a470a0, 0x30049158, 0x81a018e0, 0x11041cc1, 0x8081d842, 0xb1980022, 0x04f10448, 0x96104182, 0x0341d801, 0x928420c8, 0x190a880a, 0xc0112521, 0x03508341, 0xb0062086, 0x8842c442, 0x81323120, 0x90103530, 0xac063400, 0x80309324, 0xc4280115, 0x30211129, 0x3814c018, 0x40289066, 0x8440c0d8, 0x4ea00908, 0x483b0220, 0x92288031, 0x0b0810b2, 0x106806a8, 0x8b180128, 0x14488145, 0x60110863, 0x58048c24, 0x55042016, 0x09529408, 0x27880112, 0x262082a4, 0x84506602, 0xc8146220, 0xc8961001, 0x15404056, 0x820c10b4, 0x49114403, 0x7a200288, 0xc4122421, 0x40300a74, 0x03b90401, 0x38206848, 0x22196802, 0x0244980e, 0x6360d000, 0x114821a2, 0xc2804831, 0x0208609e, 0x20007079, 0xaa610a00, 0x4010dd01, 0x48b08460, 0x809d0850, 0x0a4048b2, 0x850c6408, 0x81700246, 0x064019c8, 0x22ac9400, 0x24064446, 0x48102a51, 0x05084a23, 0x8d00a0a4, 0xa01f8001, 0x0a127060, 0x061c8824, 0x19b00806, 0x0c642488, 0x0502c08b, 0x8aa07004, 0x08858941, 0xa5204504, 0x19120426, 0x49106250, 0x8036c500, 0x04648c09, 0x908412c4, 0x00cd4106, 0x008324c5, 0xd9210810, 0x201d6028, 0x18703404, 0x07048690, 0x08e11805, 0x05113103, 0x30a10c60, 0x10416314, 0xc9121048, 0x0129820e },
    .{ 0x5b406044, 0x0342aa84, 0xe018b840, 0x0e260903, 0x8a8049e0, 0x80981714, 0x684318a0, 0x00c76910, 0xc6888282, 0xea102016, 0x90226065, 0x0140255e, 0x00da8a11, 0x408d018b, 0xc5862a00, 0xb34a4100, 0x03f80188, 0x0023268d, 0xa0819381, 0x91438320, 0x80825b0c, 0x555401a0, 0x581a1c10, 0x06012a71, 0x38514206, 0x2a605822, 0xc0a4205a, 0x2108d485, 0x750880a8, 0x82181706, 0x100d9b80, 0x1140094f, 0x00064ad3, 0x04810ed8, 0x01148f18, 0x4a03140e, 0x821440f2, 0xd48241a0, 0x82a13450, 0x24ca2380, 0x4160c843, 0x50da0a10, 0x868584a0, 0x84a2b088, 0x22125245, 0x2d2610a0, 0x6ac80884, 0x1f044a80, 0x0802cc56, 0xc006c10b, 0x0f824124, 0x2b19200a, 0x1dc52008, 0x94402c83, 0x47001aa8, 0x49540342, 0x0d340261, 0xe1130112, 0x045828c3, 0x1a601982, 0xc1305920, 0x8121ad20, 0x208017b8, 0xa2c04146, 0x46a30424, 0xc6a90202, 0x25940710, 0xa601c508, 0x38614888, 0x98d0003a, 0x83c50118, 0x90680f02, 0x384c18c0, 0x8d250504, 0x56082229, 0x80121a3a, 0x8e0d8240, 0x16071016, 0x94a44a40, 0x4894a484, 0x2ca001e4, 0x4095068a, 0x460d1122, 0x22c0a01b, 0xa0924b80, 0x1290134c, 0x39108a50, 0x0628c093, 0x8186aa01, 0x63240528, 0x1c0aa241, 0x1a483091, 0x4802ea12, 0x0d444055, 0x015c1318, 0x2cc2042c, 0x0e300b44, 0xbb204500, 0xd4412111, 0x72808324, 0x1c24c01a, 0x13811a50, 0xc280183a, 0xcf081801, 0x8852b801, 0x4846b201, 0x1240586a, 0x8869011c, 0x64130451, 0x25f0000d, 0x82019c51, 0x5a103103, 0x05180c33, 0x318c5420, 0x5a1a2410, 0x4dc02068, 0x00bcc842, 0x028a8856, 0x41a2c0c2, 0x48302cc1, 0xaa490188, 0x481c70c0, 0x60c41426, 0x88702449, 0x88d81144, 0x79480184, 0x29a6080a, 0x28364184 },
    .{ 0x300132d9, 0x3225800f, 0x43a55480, 0x0250352d, 0x78561300, 0x71055481, 0x1889350c, 0x8e984510, 0x06956221, 0x29055550, 0xed220228, 0x49202d46, 0x07341b08, 0x500694e8, 0x8248c929, 0x2c2a5244, 0x27499a00, 0xc3721104, 0xc2709920, 0x41c163c0, 0x448c4456, 0x52430643, 0x88b90072, 0xc9080d70, 0x6006826e, 0x5581b030, 0x2a881638, 0x47b28900, 0x0212ea29, 0xcc405407, 0x2c8b9804, 0x00846b8b, 0x0a1c9a0c, 0xd013840e, 0x848e5842, 0x10c5e380, 0xe8404d05, 0x40163994, 0xea058092, 0xc128889c, 0x198d2422, 0x75d05800, 0x49282c58, 0xd1226818, 0x2a8068a3, 0x32462506, 0x0647a015, 0xb4862441, 0x018bd405, 0x10d62138, 0x67484481, 0x44a92047, 0x5090d12c, 0x040925d9, 0x0a1940da, 0xf4058405, 0x67458c00, 0x402b8654, 0xe4072015, 0x4aa13121, 0xc9e60880, 0x42ac6803, 0xa7055090, 0x20a3f044, 0x84190749, 0x22163072, 0x48144656, 0xc5819221, 0x064d201b, 0x1266680c, 0x0533112c, 0x4311a948, 0x2611403d, 0x98d90142, 0x4a0d4289, 0x018181dd, 0x36261013, 0x18016e0e, 0x4c4a0433, 0x2963081a, 0x191326a0, 0x5646084a, 0x4d1c04a1, 0x16442aa2, 0x58961803, 0x26e0209a, 0x2644841b, 0x1a02ba21, 0xcd015083, 0x1a151194, 0x5ac09034, 0xdb02240c, 0x38438243, 0x13f08248, 0xa1865310, 0x618c2588, 0x44651a14, 0x2710069c, 0x70000cbe, 0x9186482a, 0x13482b82, 0x222b2c50, 0x8429b920, 0xd4220e12, 0x07061856, 0xd0e09418, 0x5a495012, 0x82841c78, 0x850baa02, 0x02b29831, 0x92d40858, 0x44d10236, 0x5c388250, 0x554a0258, 0x202a7905, 0x305b2160, 0x092451c3, 0x04d82272, 0x6c02903c, 0x2023bb10, 0x74481129, 0x096a4621, 0x30e98488, 0x3004d949, 0x01c223e2, 0x41c2a05c, 0x3cb02502, 0x5d3a4400 },
    .{ 0x5268d803, 0xa5322503, 0x240cb370, 0x980e48b2, 0x20c27784, 0x8dd4a00c, 0x4193305c, 0x15881396, 0x73581940, 0x3405d885, 0x0aa8623a, 0x70365045, 0x46030f1a, 0x29996428, 0xc8c170a2, 0x78c2c302, 0x10a12f31, 0xc5060d19, 0x0f2e0a14, 0x44a17245, 0xc2442f09, 0x4c525b01, 0x3a804237, 0x04a16af0, 0xa5164096, 0x93368284, 0xa84c9898, 0x000afe1c, 0xc3506a12, 0xd1092da0, 0xe8167401, 0xf15b1800, 0xf144120e, 0x0d21e162, 0x68e5802c, 0xca2040be, 0x826430cb, 0x81049787, 0x6ee50210, 0xc4b40c45, 0x03bf200c, 0x0450f4aa, 0x2202d92d, 0x73231284, 0x40c1c3e4, 0x1178702a, 0x0e0338b1, 0x4138fb00, 0x71c04455, 0xa4aa8069, 0x916e8414, 0x0e58a41a, 0x19346485, 0x09545e60, 0x092206f3, 0xd05b4a04, 0x61951c48, 0x1202f0e3, 0x67040f03, 0x46283a43, 0xe0b40929, 0x43a0403f, 0x8d08119b, 0x41413a6c, 0x010745ad, 0x6c52098c, 0x2a2826e8, 0xe0b2284c, 0xcb8260d0, 0x006160f7, 0x8111daa8, 0x6b0a1344, 0xa8392053, 0xcab30029, 0xcca0cb02, 0x06dc0269, 0x17915442, 0x1c08951d, 0xcd5020d8, 0x083984ce, 0x846b18a2, 0x01e14378, 0x4d0c41c5, 0x257451a0, 0x34047619, 0x426184dc, 0x056076c1, 0x48840be6, 0x11de4304, 0x818626b1, 0xa88f3500, 0x80cc0d5c, 0xd0747012, 0x88387829, 0x55a30283, 0xe809c4c2, 0x43412569, 0x1a142b62, 0x8c305b42, 0xd2b61101, 0x5101454f, 0x11ae41c1, 0x6140ee81, 0x132ec241, 0xd2070a23, 0x51f06098, 0x4899e086, 0x8591301b, 0x02c932aa, 0x60c40c9e, 0x843588a9, 0x28006b76, 0xc8214f42, 0x2a064cb1, 0xc0586cc1, 0x8c83b260, 0xb1892612, 0x6021c6e4, 0x2308213f, 0xf24c4181, 0x7491c822, 0xc1135c18, 0x690c12d4, 0x64685603, 0xb228ab10, 0x78770009, 0xb1099138, 0x035a9330 },
    .{ 0x882829af, 0x09b54a29, 0x138d4196, 0x93172129, 0x99132874, 0x63662445, 0x74150e54, 0xc56c0a25, 0x974f00e0, 0x8947f101, 0x0019f3e8, 0xa301ac9a, 0xa30ea191, 0x59aa5860, 0x0d2ba1c2, 0x15342751, 0x95885724, 0xc41061f5, 0xc5474489, 0x90268d87, 0x9a75a140, 0x66e06445, 0x8c9175a0, 0xa8eca604, 0x209e54e2, 0x25261175, 0xca6b0c84, 0x49a86338, 0xa88b1e44, 0x1fa108b4, 0x016bbe40, 0x4243b3d0, 0x08dc2639, 0x619a18c5, 0xbc50803b, 0x506e0553, 0x5f910851, 0x0683f321, 0x10838b5e, 0xe2d18264, 0xf4716084, 0x09ab4ab0, 0x51c3382a, 0x090fa362, 0x41ce1a2c, 0x03b91392, 0x9b929260, 0x478126a3, 0x22a7840f, 0x03768474, 0xd04a0373, 0x5117a4a8, 0x153606e2, 0x20335e70, 0xa369a812, 0x0bc1078b, 0xc8096e64, 0x7c1a0b82, 0x1d2462e4, 0x8a08b22f, 0xb0171970, 0x02cd183d, 0xf0821176, 0xe3705023, 0x8606c556, 0x521ae138, 0xd0a358d0, 0x3a24e1e0, 0x1129ce91, 0x7e20a194, 0x8c01de8c, 0x21cd82ac, 0x83a2489e, 0x8a35508d, 0x6a088d96, 0x060197d6, 0x617f1210, 0xa528e491, 0x658bc0c4, 0x8d86c294, 0x0889f453, 0x8a25c722, 0x33398d08, 0x36e4208d, 0x75218493, 0x1f00b227, 0x8d4d7801, 0x80433ab3, 0x236744c2, 0x13111a67, 0x3e4c304a, 0xde166c00, 0xa1237816, 0x1ac68b0c, 0x43c5d141, 0x6856c548, 0x0710742f, 0x85716948, 0xd2968e01, 0xe830136c, 0x682f205c, 0x15515493, 0xa7f04814, 0xb43c024e, 0xa8e3424c, 0x538398a1, 0x15619c68, 0x55d2410d, 0x91174c98, 0x81ea9648, 0x09b006f9, 0x40edb083, 0x75164390, 0xe4d68405, 0x092ed990, 0x1e548a2c, 0x1c4a9cc1, 0xafd20803, 0xae509505, 0x2508c7c6, 0xc1899f80, 0xcd013728, 0xc8ea1825, 0x90782743, 0x2c503e92, 0x49592b42, 0x272b3481, 0x71ac12a4 },
    .{ 0x1671d560, 0x3c50e827, 0xb054866d, 0x0e84f31c, 0x3c2e4351, 0x41172df0, 0x0c14b4fa, 0xb130cf28, 0x2e88b0f1, 0x601f1716, 0x607b2235, 0x7190f152, 0xc12471b6, 0x3130e9a3, 0x0bc7ae80, 0x90a6652b, 0x574a4e11, 0x61dd8710, 0xf828a1c3, 0xa221e94b, 0xba4223d4, 0x836ea0a3, 0xa88e4b1c, 0xc2fc6206, 0x3151b453, 0x8b592ec0, 0xb0c4b686, 0xcfc09268, 0x5b025b25, 0xc122c5ab, 0xe1e9904a, 0x007ec4b3, 0x25ada0e4, 0x87b1d221, 0x6183469b, 0xc28647ca, 0xd0e9a055, 0xcb3a8a14, 0x2e546172, 0x7458ae42, 0x8a6db10a, 0xb793d001, 0x416396ac, 0xa6880be5, 0x5f1204ab, 0x54ced20a, 0xe63054b8, 0xe26ae700, 0x920fb099, 0xc9040fe9, 0x62649c9a, 0x4473ce44, 0x23159e58, 0x08b368f2, 0x38953ca4, 0xd491a09d, 0x4cb3026e, 0x089a7c66, 0x54f62603, 0x423d32d1, 0xb086f036, 0x764a0378, 0xd988348b, 0x1b978982, 0x00859d5f, 0x217c4b86, 0x8f69c260, 0x50345717, 0x5199cad0, 0x32a29a65, 0xa177d088, 0xc7083b23, 0xa28571d4, 0xd39e2a20, 0xa2d67094, 0xef8806a4, 0xa27ac246, 0x20dc8f83, 0x072350f5, 0xa7834ca2, 0x1c72cc52, 0x888df522, 0x40bed50c, 0xd181c46d, 0x638616d1, 0x288535ba, 0xa34d2ec0, 0xcd199e01, 0x058ad3b4, 0x445fc48a, 0x94e121b3, 0x956442ba, 0x8ee1c541, 0x43cc7d80, 0x563da031, 0x0d253798, 0xc05a39d8, 0xb340a3d1, 0xcc3544d2, 0xe482cb68, 0x1814e67c, 0x84f34174, 0x61e83e24, 0x436939c4, 0x15198f07, 0x025d3cd4, 0x91deb00c, 0x48705c3b, 0x03c4e92e, 0x72312e4a, 0x119e83e8, 0x9bb06231, 0x52ac32c6, 0x8033ce65, 0x07cc833c, 0x1f581853, 0x5444555b, 0x855b28b8, 0x03b0d1dc, 0x693e9c01, 0x41aad8d4, 0xe510a695, 0x334d40b6, 0x9f046d22, 0x2b8ca878, 0x68a4e0d3, 0xd388688e, 0x4a42c4e7 },
    .{ 0xe4892573, 0x3d4630f4, 0x24ca29dd, 0x672e21a5, 0x0da49d71, 0x2cbb4338, 0xfbc811c4, 0x4c98f5d0, 0xd208fa96, 0x8e68d9c1, 0x4a0b99ae, 0xe05bfa01, 0xf550c0b6, 0xee2d2407, 0x6fc10b92, 0x8469e656, 0xd0e28bd4, 0x7443c0be, 0x904ae55b, 0xa143c9e5, 0x49d2683e, 0xccea85c2, 0xad84b543, 0xe81cb546, 0xa808ebd3, 0x2f3380cd, 0x1305df38, 0x53aa12f2, 0x4079a47b, 0x761aae81, 0x670abc52, 0x64193ada, 0xb2db3310, 0x63855dc1, 0x6a6e8e82, 0xce853855, 0xc386cc6a, 0x18966c37, 0xdd5c8628, 0x55a492ec, 0x6a5d3614, 0x709d988b, 0x63525a5a, 0x88f07b52, 0xa8cfb122, 0x0465bd59, 0x38f0e4d1, 0xa632781d, 0x0bbb8e03, 0x0a71c735, 0x5b8453ac, 0x0b64be43, 0x5f622117, 0x857c5546, 0x6f230ea2, 0x387511b3, 0x5246d2d3, 0x98578e07, 0x219788db, 0x34495e4e, 0x815716da, 0x1d98bc1c, 0x22636774, 0x1ddb5091, 0xa5b4822f, 0x24c9707d, 0x7c2c12d5, 0x58ee216a, 0xabd14b41, 0xca5d1478, 0x51365a1d, 0x0e237e0b, 0x461e1b27, 0x493f5066, 0x75865970, 0xa9c14aec, 0x36e0a96a, 0x995048fd, 0xe7c5a809, 0x8aa95acc, 0xe57056a8, 0x7d870c32, 0x17a1417d, 0x4a5457c3, 0x98d5ce12, 0x5b55d015, 0xd3a9c311, 0x354553d2, 0x2e8245be, 0xc22ba273, 0x3909c73c, 0x5e2e1316, 0xf0037e46, 0x443739ca, 0x60a84b77, 0x55964571, 0x5bc0e6a1, 0xfc458534, 0xeda94948, 0x4b227c39, 0x4d4585ba, 0x8be2f940, 0xb009bea9, 0x950d2f2c, 0xdc451ae1, 0x5c5cc98a, 0xa8868ecd, 0x34d16b86, 0x175b2e82, 0x1483379e, 0x0a6e3cd2, 0x455751ac, 0x00a72bbe, 0x83f1530e, 0x94bcb470, 0x142e31fc, 0x179032fa, 0xf3293285, 0xd8e921d2, 0x26cf81c5, 0x5a0d6e43, 0x5c88ec39, 0x920d3d74, 0xf910bc29, 0x5568389d, 0x0539ba8e, 0x83bab268, 0x959b5251 },
    .{ 0xf5709724, 0x30cae4b7, 0x0e0dcd73, 0x2af388ba, 0x73d07478, 0xefea9081, 0x62546f1b, 0x2ee618a7, 0x1fe2cca1, 0x6e4dae24, 0x4aee256a, 0x2137ab63, 0x3f3a1a64, 0xcaa253da, 0xcb975845, 0x7dc5a909, 0xefa422f0, 0xda19f582, 0x7c184f2d, 0xa41be647, 0x2554573e, 0x5c9177c4, 0x5be6034e, 0x85df41e1, 0x7cd3384c, 0xa81915df, 0x6ce0347b, 0x1e8e186f, 0xa106b6de, 0x55c7da21, 0x79472b07, 0x9f399914, 0xae08b9ea, 0x92f73941, 0x01ef4ba9, 0xa53f46a1, 0x783ab417, 0x160db8de, 0xb98a37a4, 0x2596785d, 0x079d2d71, 0xcc9b72c1, 0x5f74059a, 0xf33cab01, 0x9df42343, 0x94acbe07, 0x062df8b9, 0x27606bf2, 0x8875ae39, 0x1c32f7d0, 0xba2c899d, 0x57085ef2, 0x5d4c927a, 0x30fa31ce, 0x4aa474f3, 0xb9711cb1, 0x93c42b6b, 0xab63c938, 0x7ed72405, 0xdaaa02cf, 0xf47989b0, 0x730256af, 0xc3d1c3cc, 0x37474867, 0x0cfca4ae, 0x724b8f86, 0xe1f104ed, 0x19996dd8, 0x44b6e387, 0xa600fe3d, 0x3b2b2c96, 0xf22c6399, 0x5cbab0b4, 0x1de12bd4, 0x33255ee2, 0x592b6e1a, 0x568b8e3a, 0x792665a5, 0x5c539cf0, 0x6da8f055, 0x1e63e6a1, 0x59591b99, 0x185e82f7, 0xd403ea2f, 0x5efd5050, 0x2ee8c3d4, 0x9837a8ba, 0x8dd715e0, 0x645e93d2, 0xc3243b7a, 0x74ed8d12, 0xfb900ec6, 0xa660de4d, 0x38addc32, 0xb8a56e25, 0xa8b25d96, 0x33cab466, 0x72ea6b81, 0xa52eb03b, 0xe509674b, 0x2216b3fa, 0x8690ed2f, 0x47d8e43c, 0x15625ed9, 0xb68e2972, 0x4bc65627, 0x579503c7, 0x80e95e3d, 0x18bc9d96, 0x43d903fc, 0x688617bd, 0x4d2ed568, 0x8d5f1709, 0x41fb0b4b, 0x333f1037, 0x7e9452c3, 0x5994e327, 0x475d64d1, 0x2be4465e, 0xeae4a84e, 0x01feb1c9, 0xc960537d, 0x323b07ae, 0x1ace48d7, 0x49a99d2e, 0x179e6351, 0xf69d081b, 0xaa691cd9 },
    .{ 0xd741d6c5, 0x1a68fab3, 0x0e31f4f5, 0x245fe8e5, 0xd95d8335, 0x29f6a38e, 0x875aeb29, 0x985e59e3, 0x1fb560a7, 0xf0c475e5, 0x32f77d08, 0xf3e28715, 0xf6c35ae0, 0x1cee2ae9, 0x841f376b, 0x8dec623b, 0x22df5ccc, 0x3c3d7c68, 0x68b4a7d9, 0x19a5d7e4, 0x5f4f3984, 0x027daf0f, 0x36b0d5ad, 0xdb0aec1d, 0x579560b7, 0x16b8655f, 0xd0a4deba, 0x5dc16e39, 0x9db2ca4b, 0x149dfe2c, 0x1a7dd968, 0x6aad36cc, 0x6b17283f, 0x9f88e2ce, 0xd6e049fa, 0xa8eb06b7, 0xd8a25f33, 0x6bf5a096, 0x87b855b5, 0x5e0fcc87, 0x13f764e1, 0x28c374bf, 0xfc58e718, 0x576634b5, 0x4d5cbce1, 0x0f1e71cd, 0xb774290f, 0x20eef2a7, 0x34b7c5a6, 0x33a389bb, 0xecee829c, 0xdfbe1680, 0xf6911a75, 0xbb4117ad, 0x259961ef, 0x77d42f60, 0x2553b65e, 0xcc348efa, 0x88f7dcb0, 0x5551f61d, 0x63ae8967, 0x70755ab6, 0xc32d359d, 0xcf9a70ac, 0xbca2997c, 0x637a174b, 0xf71238ce, 0x494cff0e, 0x3def0c52, 0xf30f626a, 0x5e2581fe, 0x70eac7c5, 0x69dc191f, 0xe9dcc5a4, 0x4723f3f0, 0x6b6c3a78, 0x2bcbb0e3, 0xdda71b05, 0x36786b1e, 0xba483abd, 0xd52e8f92, 0x149f8b37, 0x5907a9be, 0xd641c55f, 0x438e1df9, 0xdba5b419, 0x0b31ce77, 0xf4eb6903, 0x49b6e6ca, 0xae31c5da, 0xf4cae64a, 0xc67f89a2, 0xc3825efa, 0xbb8b9394, 0x76561eb8, 0x560dff88, 0xea1aa3ce, 0xadbd0933, 0x2f8b938e, 0x9b73485b, 0x6db929e4, 0x56cc4ecb, 0x3cc7ec61, 0xca6f8563, 0x3fa5c893, 0x6d56f6a0, 0xfd181e2e, 0x59ce12af, 0xba61652f, 0xd20f572b, 0x6764ed91, 0x1f191af5, 0xf2a333aa, 0xa54e5a7a, 0xbc2ee6a4, 0xdb4ca5c5, 0x2a1ef933, 0x5c57dc0d, 0x3f72d078, 0x8de1df12, 0x7de403ab, 0x84eebf28, 0x7c5616f8, 0x7eb91a31, 0x7579a670, 0xb6ece2c2, 0x7d21d83b, 0xafe3dc20 },
    .{ 0xaf56de14, 0xe2c5636f, 0x5d4fda91, 0xc76c2e4f, 0x8a6bd2dd, 0xa5ee84f9, 0xbc77f2c0, 0xfb5cbd04, 0x19b9e74b, 0x27dc336e, 0x62d8b5b7, 0xd8e77439, 0xa4bc6f71, 0x234ebe75, 0x139f65cb, 0x5ecf05e9, 0xcad9d179, 0x26e5fd92, 0x65fd1791, 0xbecad19a, 0xffe2049e, 0x250efccf, 0x9ea47765, 0x344bdd6b, 0x3a07f7a5, 0x966a2cef, 0x79851ebb, 0x75b92f32, 0xf32d10fb, 0x8a99d6f3, 0x996c5fc6, 0x1666db6d, 0xbef893a4, 0x9d90e8fe, 0x38eb2d79, 0x798b75d8, 0xfcf3a50c, 0x001ffefc, 0x2f047ddb, 0xc79ce333, 0xb45fa99a, 0x5eff041d, 0x745b5cea, 0x7fc256c9, 0x634fad4b, 0xc5cfe929, 0xf6c6cb4c, 0xae478b76, 0x7f34258f, 0xadbb65c2, 0xd2e5aa5b, 0x951db2d7, 0xdf76e038, 0xce33896f, 0x80bacdfe, 0x3bc8a5e7, 0x4ec5fc2b, 0x0f39f0f5, 0x6d64ecab, 0x9f9985ec, 0xb0fac39b, 0x5f473f12, 0xe999a2db, 0xe9c7e346, 0x726d8bf1, 0x676c1d73, 0x543fb8b9, 0x18bbb9ad, 0xf575f0c8, 0x4dbb35d4, 0xced8db58, 0x650779bb, 0xa8f173b3, 0x0ccfdb63, 0x284ebf5e, 0x26ef4ba3, 0x7f450b79, 0x3f370a57, 0xb46e9f51, 0xcd3d96e1, 0xf6b4491f, 0x58b3df92, 0x60b3b677, 0x9ce04bf7, 0xc9175f27, 0x2d8f391f, 0x2ecb8eda, 0x2b41aef7, 0xe33e1cc7, 0xd4daeb0e, 0x36bde10f, 0xb970ec97, 0xda7e8c5c, 0xa4da53e7, 0xdf733838, 0xe99ee09b, 0xf94a9c5d, 0x8a92fe5e, 0x4db867ba, 0x2735ee1e, 0xd8ea31be, 0xee2c7359, 0xd3b8f90b, 0xf7480b7d, 0xab387f62, 0x8eaebba2, 0xa8f7fe02, 0xa6de46e6, 0x3bcbd709, 0x78b389fc, 0x3dd63c63, 0x12b7bfa8, 0x71427adf, 0xb565c3d9, 0xeb97ae21, 0xb271fcc3, 0x27d47277, 0x712aecd7, 0x73a9f496, 0xd274937e, 0x17c0e9ef, 0x3fa5c723, 0x3d0e9d9b, 0x2de834ef, 0x3aee8dcc, 0x7d78631b, 0x1b916dbe, 0xad2a8be7 },
    .{ 0x2c7ab4bf, 0x2dc47f75, 0x1abe31fd, 0xff8c3665, 0x7d3d125f, 0xe9f862bb, 0xf8653757, 0xcf7f16c8, 0x0d6bf379, 0xea571fcc, 0xceae915f, 0xe4f77196, 0xf2a18ff9, 0x2c57ded3, 0xeeedf121, 0x9eddb82b, 0x95777745, 0x7bb0df89, 0xce7dfb02, 0x87a6ff2c, 0x9e23b6f6, 0x2ded43be, 0x4737c4bf, 0xeab2593f, 0xd7ea29e3, 0x7fa76b24, 0xc4f7f26c, 0x9c71bdce, 0x1f7b761c, 0x7fa291ee, 0xefb785c8, 0x75fd7c48, 0xa49ddcf6, 0x5b3cb66d, 0xe6c93b6e, 0xb69476af, 0xef534373, 0x8f91ee97, 0x7775b689, 0x39555eee, 0x99e95fac, 0xb3cff8a8, 0xeaf33bc4, 0x3747df2a, 0x7a6faa72, 0x06ea73df, 0x9c4779af, 0xeb2ba755, 0x3f60feac, 0xa575f555, 0xbe8d1d79, 0x3be9c2ee, 0xb0d6bf69, 0x59e4bafa, 0xab174e3f, 0x2ef6aad3, 0x8dc6e7da, 0xbe5b5959, 0x2c6b77ad, 0xac857bed, 0xbfb9a964, 0xfaae5c35, 0x1c4f3f2f, 0xe7167b3c, 0xdd33ad56, 0x7f934baa, 0xee874aaf, 0x7ccbbd25, 0xa79e993d, 0x6d65dba5, 0x5b8faf68, 0xfb1836bd, 0x43a67d3f, 0xc9d97d0f, 0xef92798d, 0x1df1de74, 0x77a3bb45, 0x7bff3112, 0x0ed2eedd, 0x26959f7b, 0x9eaf4976, 0x95dfa2ab, 0xfba5bca1, 0x8ddb55d5, 0x4bfc649f, 0x574f1f96, 0x96f87697, 0x2cedb8e7, 0x6343bfa7, 0x9f8d9a5d, 0x9766bf94, 0xb5bd4dc6, 0x9e639f27, 0xbacf8a97, 0xd971dcd6, 0xa7b654bd, 0x79f4e8e5, 0x5bdef390, 0x2dd9d5b3, 0xbd48dce7, 0xe396af8d, 0x3ddfd078, 0x770aeb75, 0xd1f33f45, 0x6f5a25b7, 0x51efe743, 0xd8fbd31c, 0x7d39722f, 0x8e9fdb92, 0xd2c2fdd3, 0xb0f715fc, 0x7ca4c3ef, 0xab0ddcbb, 0xf2d34dea, 0xb6bd4b36, 0xbf73d889, 0xc26ef6b3, 0xb58aefc6, 0x78875beb, 0x77b7e81a, 0x5969bd3d, 0xa247dfcd, 0x47777c8d, 0xf1577f28, 0xfd44cf2b, 0x8f5d794d, 0xd1ea745f, 0xa1b2f7e3 },
    .{ 0xc745edd7, 0xd6d3774d, 0xc9ca7bbe, 0xe8dff10f, 0xb575ab1f, 0xca9d6b3f, 0x7cab17de, 0x7bc471fd, 0x3dc7f783, 0xcec1a7ef, 0xa3d973f5, 0x6fcdbb1a, 0xb4aa9edf, 0xfea9e31d, 0xaac53feb, 0x3c3a7ef9, 0xf3f69f81, 0x7fb91ed4, 0xca5eb5ed, 0x734b7e67, 0xe6db8f5c, 0x556a7fb9, 0x9a2dfbf4, 0x6bf36d4e, 0xd9d33b6b, 0xebaccf3c, 0xe9e4ff19, 0xcdb7ea53, 0xebcbe669, 0xbf53b9c9, 0x73ed435f, 0x5e7af68e, 0x9afe7e51, 0xb547e6b7, 0xe3e75e96, 0xc2bdfd59, 0xaeced357, 0xc8b9dbb7, 0x5b3efe92, 0xee7518f7, 0x6eb29ded, 0x19c77f6d, 0x8f3ec9fc, 0x0f734fe7, 0x7a997bab, 0x34f3bcbe, 0xbe0efe0f, 0x77cadf34, 0xff8f81f8, 0x61bceefa, 0xdf6b1be1, 0x4f6cacfd, 0x36ee555f, 0xaa3f6f78, 0xf629b4df, 0xb78f9cb3, 0xf35af43e, 0xe37de06f, 0x33abfaa7, 0xbfb093f9, 0x35b7975b, 0xfd6ddd0c, 0xad2e7e3e, 0xe9265eef, 0xe6babce3, 0xcb0b6efe, 0xd35d0f6f, 0x769aeda7, 0xbc9fde51, 0xe6d3d4b7, 0x7a3fcc2f, 0x9f6e992f, 0xbe455fd6, 0xfbdcccc3, 0x69f5e70f, 0xfab1c4ef, 0x5cede793, 0xc9c555ff, 0x617ae5df, 0xf34af9dc, 0x5ee7a47d, 0x9fb4fa2b, 0xf995dce3, 0xd657ea3b, 0xa9fde3e1, 0xa7afe0dd, 0x9de5ee6a, 0xede961bd, 0x3b3fb467, 0xf17b978b, 0xa55b57db, 0x3ebbfca4, 0x599e76f5, 0xd6d665f5, 0x676aaf57, 0xc634fbdd, 0xaef496eb, 0x5a25f777, 0xe293ef73, 0xbba9fe34, 0x3aeb7f64, 0x939ffb4c, 0x47d9fcab, 0x4b57f5f2, 0xc9e4aebf, 0x1f5f8ec7, 0xf813d7f5, 0x71e2fbf2, 0x79dd66d3, 0xc7cbe3f2, 0x345fad7d, 0xd8df2eb5, 0x6f3339f6, 0xf3f31f38, 0x6b37ced3, 0x8fdbcb59, 0xed165f9b, 0xededfa14, 0xfade8eb2, 0x76af4d79, 0x2f2f3bd5, 0x71b3e5bd, 0xf5bbe1a6, 0x7bbf9c1a, 0x66f7b8ea, 0xefa63c6e, 0x6f923e5f, 0xfedd6bc0 },
    .{ 0xcd5ffd85, 0x69fb6abb, 0x6dcbee6b, 0x1ef33e7e, 0x5af6f1eb, 0xbf7f6073, 0x68f9f53f, 0x778f5db5, 0x5af6f6d9, 0xeed7d27c, 0xf7d5d9e1, 0x70fbf5e5, 0xa95dddfc, 0xebdce68f, 0xdff9cd98, 0x7fd9ae56, 0xe06dddfb, 0x89b7b7fa, 0x7c847fbf, 0xf9caf36e, 0xf5a95daf, 0xb57ff42e, 0x5b7ae5f5, 0x77ce37d6, 0xf965de3b, 0xe5b3fe69, 0x4779bee7, 0x338d7cff, 0xed356dd7, 0xf9ddc75a, 0xbda34fbe, 0x6df41f9f, 0xa91d7f77, 0x4c5fefe9, 0xdbef1b65, 0x7747df4e, 0xe7addf62, 0x8f5e57fa, 0xbfd4b5ae, 0xff93f689, 0xf7efb845, 0xfa36fde2, 0xf34ccd7f, 0xefbdb6c1, 0xf9d56dea, 0x7fb53cf8, 0xbd4d39fb, 0xa5fc9b7b, 0x1ddfddb2, 0xf72c4dbf, 0xfcd2b35f, 0x9f2f66fc, 0x7bd19bf9, 0x7fb35fd0, 0xb2fde6b5, 0x5bbe3bf1, 0xef3bf03b, 0xdf2fb993, 0xdb3fc667, 0x6fcfe726, 0x45adffcd, 0xb6577ea7, 0x9e8fbed3, 0xbcad5eaf, 0xfb6d9d8b, 0x8b7df771, 0xf5cedcd5, 0xb373eccf, 0xcfeb653e, 0x976e5fb5, 0xbef17bd2, 0xf0d1fb5f, 0xef5a99cf, 0xff5ec8d5, 0x63b57abf, 0x81f3dfee, 0x9feb71e5, 0xbb3b787d, 0x79ee9f5c, 0x75e5f997, 0x16f7f1eb, 0xfba66abb, 0xab6c37fd, 0x7f9d98dd, 0xbdb79c8f, 0x5f4ee3f3, 0x6f78ff0e, 0xeb9e5add, 0xffab5d0b, 0xafaec27f, 0x4eedfd63, 0x3d9e3db7, 0x45f72faf, 0xeff30cf6, 0x735fcceb, 0x7c5bbc9f, 0x16f60fff, 0x3ed7ff12, 0x754f5d9f, 0x7dbff498, 0x3af2fcee, 0xd256fd3f, 0xfa56deb5, 0xbee58df5, 0xa7e71ee7, 0xef5c3f4e, 0xfb8b5a5f, 0xf9193f7d, 0x5daeceed, 0x26bab7ef, 0xbfffc704, 0x1dbdaebd, 0x6eccadfd, 0x3fe74d97, 0xf6dbfe05, 0xe17dfb4d, 0xfeed4a7c, 0xedf945ed, 0xcbdcff49, 0xc7fa8e9f, 0xa7966dfd, 0xbad3bade, 0x6135fe7f, 0xbff4a33b, 0xa3cfaebb, 0x97b3d63f, 0xe9a6e7d7, 0x67fb7c8b },
    .{ 0x7f9fde31, 0xf3e7bda9, 0xe8b3bfcf, 0xdaa7edd7, 0xd9dbb779, 0xd525faff, 0x38ffcf75, 0x7f9b2eee, 0xfe77e78a, 0xdbfd7972, 0x6fe9dd1f, 0xffed1b6c, 0xcecbf2fb, 0x3efd3ecd, 0x96e6aeff, 0x79df7d39, 0x2f6dfa7b, 0x4ffe36eb, 0xedde3d5d, 0xfdfadc3a, 0x7ecbd55f, 0x1f2f59ff, 0xfbcb7277, 0x7d86fd9f, 0x5f85fd5f, 0x7ef6dae9, 0xfe66ddec, 0xa9f3ad7f, 0x8efbf9ab, 0xa73fd17f, 0xfd3d2be7, 0xafde81ff, 0x36ffd6b6, 0x97e3f7ab, 0xf1f7bae9, 0xebde9d7a, 0xdad7caf7, 0xff17edb2, 0xfad5f55d, 0xce87df9f, 0xcfff20fe, 0x1ecf3fdb, 0xbcbd6efc, 0xcd577bbe, 0x7f379af6, 0xd7efba71, 0x3f9c7efa, 0x3fdf2abd, 0xf6bef1ea, 0xf3cebe1f, 0x7fadcd6e, 0xf34f6fb3, 0x9d6cfded, 0x97f7f3c3, 0xeddf6da6, 0xe6cd7f7c, 0x59a6ff7d, 0xb4abb7fd, 0xdf58f73e, 0x5ca7ebf7, 0x99fc6fbe, 0xbf2e6fe6, 0xb3aeecfd, 0x7ed5ebc7, 0x9cdfe7ec, 0x7fdf2ba9, 0xc3efbde9, 0xd7d7733b, 0xe5bf778b, 0x2f97eef3, 0xbc7695ff, 0x8bfdf778, 0xbf7f499b, 0xe7ddfc9c, 0x3fd5f9bc, 0x7d767be9, 0xfb2d1ffc, 0xd85f7ff4, 0xe6dbb8df, 0x52ff3f76, 0xbffdf541, 0x63e7bdde, 0xdb6f7a67, 0x97fee1fc, 0xdffde217, 0x5cfdfeb4, 0xb87ebef9, 0xefa5f95b, 0xf575d6fc, 0xfdbd38f3, 0x1fae17ff, 0x9ff35f63, 0xfcd96dde, 0xeb7e7a6d, 0xdc7e7ead, 0xd275ef9f, 0xafbff782, 0x66ef99fb, 0xebf6da57, 0x7bf7f9d0, 0xc3f74cff, 0xb29fbafe, 0xfc6f4bb7, 0x5f72f72f, 0xcfbb69ed, 0x5b7a3b7f, 0xd7e37ceb, 0xddc2bfb7, 0x7f3dfc78, 0xbcc65bff, 0xda7db37e, 0xdbdb755b, 0xcecfc97f, 0xe267dfe7, 0xc6ff6f5c, 0xbdbeb5e6, 0xfacfc7e3, 0x4d7b9dfb, 0xff9e8d7a, 0xc73b5e7f, 0xeda8e7ef, 0x1b73fe6f, 0x7f07ebf3, 0x2dabdfbb, 0xf8bb8fd7, 0xbd2fc7ed, 0x72b7fbb5, 0xaff2f27e },
    .{ 0xdd45bfbf, 0xfff7bc70, 0xdbdb5adf, 0xe576f7be, 0x9bf67fcd, 0x89ebf7ef, 0x7775f3ee, 0xf3de7f69, 0xffd9e7ac, 0xe7dff52d, 0xdbdbef69, 0xfc6dfebc, 0xb73e7e5f, 0xfefb6937, 0x5fe7babb, 0xfcdfbce6, 0xfdf96db6, 0xf6faf7e2, 0xfbd3f47d, 0xa5fff759, 0x3bb39eff, 0x1fb1f77f, 0x4fed73bf, 0xd6c6dffb, 0xbd6f67bd, 0x7f9bf4db, 0x9bdf76e7, 0x6bfffe16, 0xd5ef3bbe, 0xfdfcbcce, 0xaff1dbf6, 0xaef5fbd3, 0xbedafceb, 0x6fd78fe7, 0xed47ffce, 0xbe3faee7, 0x1dfc7dbf, 0xaee5ffbc, 0xde7e773e, 0xf5ef4cef, 0xc6edaffd, 0xfef7db29, 0x5ff9fd4e, 0x4bfdf76e, 0x9ed5f6fb, 0xe67bf7f1, 0xffe9d69d, 0x5b9bff3d, 0xdf4dfe73, 0xff6fe3b8, 0xeb9fd7ad, 0xd7fef7a4, 0x7dde8ff6, 0xfd3e6b7d, 0xa6fff86f, 0xefebdeac, 0x8fdede3f, 0x6e3eff6b, 0x7367d7fb, 0xd77eedea, 0x9efdfa97, 0xfdd79df2, 0xbff66bbc, 0x557d6fbf, 0xdbfb1efc, 0xffabbfe0, 0xfeb7b57c, 0xf55f6bf6, 0xcdfdbdcd, 0xeadcfebd, 0xe95f9fe7, 0xfb2f79d7, 0xdf3ffc59, 0xfd5abed7, 0x2777fff4, 0xef9f1f9b, 0xd7deb8fb, 0xedaf5bf3, 0xcbf2fefc, 0xf78e7f4f, 0xffb5eb99, 0xd7fead4f, 0x9dbabff9, 0xdb9edeaf, 0x9f9fe71f, 0xef7b63fc, 0x59defbcf, 0xdfedc9f9, 0xcd2fdfed, 0xffccbf74, 0xbf8e95ff, 0x1b3bfebf, 0xdfaf79f4, 0xdfadce3f, 0xfeee9ef2, 0xfe7efaa9, 0x6ccfe7fb, 0xadf3df2f, 0x9fd6da7f, 0xeed6d9fe, 0x36e6ff7e, 0x33f7f9d7, 0xed7f17ed, 0xfffc2cfc, 0x9fcd767f, 0xff7bd8d9, 0x7f79ab9f, 0xffed1e6d, 0xff0d77be, 0xf3ddef59, 0xbfcd7de5, 0x3e7d6ff5, 0x79dbdbdd, 0x4dfe67fd, 0xaefaffe1, 0xf3f63cfd, 0xbb5a7ff9, 0x5aefea7f, 0xfb77c7ce, 0xfe5f98fe, 0xf276ff3b, 0xf27fd7cb, 0xf63eddcf, 0x7afbe5fa, 0xdff9f785, 0x637febdb, 0xffb52fea, 0xcdebd8ff },
    .{ 0x5fcd5fbf, 0xf3fae7b7, 0xd65f7d7f, 0xafedbfb6, 0xfd5fcf37, 0x76ffeafc, 0xf3ffc6af, 0xfffd2bf8, 0xe9eeedfd, 0x7bdef5ee, 0xf67db5df, 0xbffc3cfb, 0x9f7fd7b6, 0xbb0eefff, 0x3cf2fffd, 0xf75d3fde, 0x77fffb07, 0xd237dfff, 0xebaf7aef, 0x77fdf795, 0x9fede7de, 0xfff83cfd, 0xfd7fc3e7, 0xe3fb6fee, 0x77bf7b8f, 0x7ef9f9db, 0x6ffaeeeb, 0xbafff5ba, 0x3fcdddfd, 0xdfdaf2fe, 0xbb66fd7f, 0xff7f84ef, 0xd6f7d7b7, 0x7fef1fec, 0xd5e73eff, 0x3fbff5cb, 0x37fddeeb, 0xf776bd7b, 0xcedf67df, 0xf7ebe1ef, 0x6cbf7bdf, 0xbeb6dfdb, 0xfeeb7b3e, 0xfffb51ee, 0xe377fbcf, 0xcfffbfc1, 0xbb8fff7a, 0x2efefd5f, 0x9f6f9fde, 0xff4e6fee, 0xffcd75dd, 0x63ff72ff, 0xeff53fd3, 0xef6ddfb3, 0xf3eeaedf, 0x77bb9bfe, 0xd5faaff7, 0xb54ffdf7, 0xc7feef5e, 0xbe7ed7e7, 0xf69f77eb, 0xdfef9d8f, 0xddf57fae, 0x0b3ffffe, 0x9ff796f7, 0xdf69fcfe, 0xfe7d7f0f, 0x7f57fbab, 0x7fb7bb9d, 0x6ff3fda7, 0xeffeb5d3, 0xf4fddfd3, 0x6b9ff3fb, 0xf7dfb0fd, 0x9dfbddee, 0xe3fdbfb6, 0x9efe9ff6, 0x7febbeba, 0x2edbeffe, 0xfe359f7f, 0xf2f76ff5, 0xf037bfff, 0x2cff9eff, 0x69efff6b, 0xcfbfdebc, 0xf6feaaef, 0x7c7ff7ad, 0x6fbf377d, 0xfbdadb9f, 0xd7fe4f7b, 0xebbf2ff3, 0xd95fbddf, 0xed8ff7bb, 0xbb5fcef7, 0xdf1fbcf7, 0x68dfebff, 0x77bfdbad, 0xff79e9be, 0xd9ed77df, 0xdfd6deaf, 0xd73bbf7d, 0xfb69bff9, 0xffdeb98f, 0x6b6bffd7, 0xebebfdbc, 0xe3f7ebfa, 0xcffd4fbe, 0xefddb9fa, 0xe7bb6fed, 0xd3bf99ff, 0xfed7dfb4, 0x3f79bf7e, 0x7f7877fb, 0xdbe7f5db, 0xefbefb72, 0xc76bfd7f, 0xad3df3ff, 0xe5debeef, 0xeb4fb7fe, 0xd9df77f9, 0xff34ed7f, 0xfefeb3f4, 0xefabcebf, 0xdef7fa6b, 0x772fceff, 0x34f7fcff, 0xfd773ddb, 0xfbba6fed },
    .{ 0x3abff77f, 0x7bffc7fa, 0xfecff3cf, 0xfeefdb6d, 0x5bbfbff5, 0xfffcb2fb, 0xdf8fef6f, 0xddfd9f6f, 0xcefbedf7, 0xebe6fefd, 0x9fdffade, 0xfdb77beb, 0xf7f7dc7b, 0xf4ff1fef, 0xfbf54ff7, 0xfddf1bfb, 0xd7dfaff9, 0x7bcffafb, 0xbb7befaf, 0xdcfbffe9, 0xdeefd9f7, 0xcf77f2ff, 0xfc79ff7d, 0xb9ff6b7f, 0xff6fbe4f, 0xfe67f7de, 0xbd3ffedb, 0xbffad7fc, 0xdf5bff79, 0xafeb7f7d, 0xebfdefb5, 0xfbded7e7, 0xf9ffe99f, 0x1fdfcffd, 0x36bdfeff, 0xcfcff7ee, 0xdbbdfeeb, 0xfdddfddc, 0xbddfbeeb, 0xfee5befe, 0xfdbbdcf7, 0xffca7def, 0xefffb477, 0xe97f77fd, 0x57bffd77, 0xb9bdfefd, 0xfe7eefd3, 0x57dbffbb, 0xd717feff, 0x8b7dffbf, 0xbf57fff4, 0xef7d77cf, 0xfeadabff, 0x55defffe, 0xb7fbebeb, 0xff7f476f, 0xb6efafdf, 0xf7bb7bbe, 0xcdbffbee, 0x9bbff77b, 0x7fdfeeb6, 0x9ffff76a, 0x77efe7e7, 0xf3befdfa, 0xfe57fbbd, 0xb7fc7fbe, 0xebfb79f7, 0x9dffcfdd, 0xe6f6fbbf, 0xd7dfdbe7, 0xd4fffcf7, 0xcbf67fbf, 0x3bbe6fff, 0xef2deffe, 0xcfdbff37, 0xdfe7ecef, 0x8cfbff7f, 0xaffdf37e, 0xfeed6def, 0xf9f7dfec, 0xcff7d7b7, 0xefbfbd67, 0xcf7fdef3, 0x6ef73ffe, 0xaffbbdbd, 0xededaf7f, 0xef8bfff6, 0xf7fddeea, 0xfee5777f, 0xfbc75dff, 0xce5fe7ff, 0xf96fdbf7, 0xb7faffe5, 0xa7effdf3, 0x7feefbb9, 0xb77f76bf, 0x7eb5bff7, 0xdffdcbde, 0xfef6577f, 0xccff7efe, 0xfd5ff9f5, 0x6ffffd8e, 0x3febf77b, 0x7eff37eb, 0xfeaffb73, 0x7f5ebbdf, 0x9fddbbef, 0xfefc97fb, 0xff37f737, 0xbbdfb7f3, 0xffdcfb57, 0x73fffc7d, 0x7bffbd5b, 0xe6dfd3ff, 0xfdb77bcf, 0xfddbff78, 0x7d5fdfe7, 0x77bdfbf3, 0xeeddd77f, 0xdd9fff9b, 0xbd3dfe7f, 0xbf59f7f7, 0xf2b9feff, 0xffb8fbcf, 0xfdbedddd, 0xb7fefc7d, 0x9bbf3bff, 0xe3ffbbb7 },
    .{ 0xdcefffe7, 0xbfdd5eff, 0xeffcfff2, 0xfffe9edd, 0xf6cfefdf, 0xfaf7defb, 0x7fff0dff, 0xfaeddffb, 0xff6db3ff, 0xfffaef5d, 0x7ff67faf, 0xb6ffb5ff, 0xfdbfdb7b, 0xfdfc77bf, 0x9dffef7b, 0x7f7dffdc, 0xffbfec9f, 0xbf7fbf73, 0xfdefdfea, 0x3ffbfd7b, 0xd9ffefeb, 0xfefbff3a, 0xff7ebebd, 0xfd7e3f7f, 0xfbefff53, 0xcded7fff, 0x7f77fff1, 0xbf7dffad, 0xff7f8bbf, 0xddf9effe, 0x37fbfedf, 0xabdffdfd, 0xf7fff957, 0xf6ffebdb, 0xef7f77f6, 0xffcfaefb, 0x7ff72fbf, 0xff7ff95b, 0x7ff7a6ff, 0xdffff4d7, 0xfafefedb, 0xffcffcaf, 0x3ffdffc7, 0xff1ebdff, 0xeff9debf, 0x5ffebfdd, 0xfcd7bf7f, 0x75bfeeff, 0xeff5efbe, 0xffecff79, 0xfbffaa7f, 0x7eedfff5, 0xadfdffcf, 0xfefdfbd6, 0xfd7d6fdf, 0xdedffe7b, 0xbefe3eff, 0xfdfbeeee, 0xfee3effe, 0x67fefbfd, 0xeef7f9ef, 0xdf7f6d7f, 0xffd747ff, 0xef3bbf7f, 0x4effffdb, 0xb7fdbff5, 0xcfdffa7f, 0x56f7ffdf, 0xfdee7ebf, 0x77ffdfea, 0xfeefdef6, 0xfef5ff6d, 0xddfdff7a, 0xf6fff2df, 0xdeaf7f7f, 0xfbffedd5, 0xdb3fff77, 0x7ebf5ff7, 0x97efffbe, 0xd7fbb77f, 0x79ffee7f, 0x7ffbb5ef, 0xfffd7cf9, 0xfdff73f5, 0xfff7f9e9, 0xfff6fdce, 0xfbd7bebf, 0xaefffecf, 0xfe7bf7ed, 0x7feebdbf, 0xbb37ffbf, 0xb9ff77f7, 0xcffbf7be, 0xb4ffdffe, 0xfbdfdd3f, 0xedfe9fdf, 0xdfddfb7d, 0xfe5effbd, 0xffefd66f, 0xeefe6fef, 0xffd77cdf, 0xb1fbfbff, 0xdfef77f5, 0xffdb3e7f, 0xdd777fdf, 0x6f9dfdff, 0x3fefff5d, 0xdfcbbff7, 0xdfbff73d, 0x7cfdeff7, 0xb3fffdaf, 0xdf6f7fbb, 0x3fd7f77f, 0xff7fdf5c, 0xeffefead, 0xedfdffb9, 0xfccbffef, 0xfbf74fbf, 0xf6fdbfee, 0xfbadfcff, 0xbffff9ae, 0xdaff7cff, 0xfffe6be7, 0xf977bdff, 0xb6f37fff, 0x7fe7fa7f, 0x6faffdbf, 0xfef7b9fb },
    .{ 0xedff7dbf, 0xbdbfefbf, 0xfffdb7cf, 0xe7fff8ff, 0xf3ff77fe, 0xdf7f9fdf, 0x35bfffff, 0xeffaffee, 0x5efeefff, 0xfffbfb7a, 0x6faffdff, 0x9dfe7fff, 0xf3d7fffd, 0xff8fbbff, 0xffbfffcc, 0x9d7fffbf, 0xf7f77fcf, 0xff6ffbd7, 0xefbff3fd, 0xff4fbffd, 0xfdeb5fff, 0xf35ffffe, 0xefeeafff, 0xbfef8fff, 0xf67f7eff, 0xff7ccfff, 0xfa7fff7d, 0x9fbfeffb, 0xfefcfdfd, 0xfb7ebffb, 0xbf6fefef, 0x5fd6ffff, 0xf7ffbfbc, 0xfbf9f7df, 0xfffbef37, 0xffbffdc7, 0xffbdff9d, 0xebfdfffc, 0xfffdf57b, 0xfaf75fff, 0xeffa77ff, 0xfff3ef6f, 0xbfef9f7f, 0x67ffffb7, 0xfff7bcfe, 0xe7f7efef, 0xffffeb5b, 0xabffffeb, 0xf7d7f7bf, 0xff77bdf7, 0x7f5fffdd, 0xf9f7ef7f, 0xdffbbedf, 0xfe3ffd7f, 0xebffff9d, 0xfafb9fff, 0xefedffcf, 0x7efbdffb, 0xf6b7fffe, 0xfaffdaff, 0xf5fffdde, 0x7effefd7, 0xffee7b7f, 0xfef7bff6, 0xcfffbf3f, 0xff9bff77, 0xfb9ffbbf, 0xfeefdeef, 0xffbffef4, 0xd7fdfeef, 0x6efffebf, 0xfbefffae, 0xffdf7f6d, 0xfffcffda, 0xcdebffff, 0xffff2ffc, 0xf3efbfef, 0xff7e7f77, 0xfffbf5d7, 0xff9fbfed, 0xdfbf37ff, 0xfefafdbf, 0x77dffe7f, 0xfebeef7f, 0xfebfdefd, 0x9dfff7fd, 0xffbbceff, 0x7efd7fbf, 0x3fbffebf, 0xabfcffff, 0xfffabfe7, 0xfeefbefe, 0xff7dbedf, 0xfbfdef6f, 0xbef5feff, 0xb7ffefed, 0xbbfcf7ff, 0xbff377ff, 0xbff7bbdf, 0x7fe7feef, 0xff73effd, 0x7fefdf7d, 0xf7fff4fd, 0xbf7bdeff, 0xfdb9ffef, 0xebdfcfff, 0xffefd777, 0xfbcfdbff, 0x9fff3f7f, 0xe6fdffbf, 0xbdff5ffe, 0xe7ffdddf, 0xf7fff7bc, 0xdcfffbef, 0xffff9dd7, 0xf7fe97ff, 0xefeffcfb, 0xffefea7f, 0xff7f7b7e, 0xff7bf9fe, 0x7ddff5ff, 0x5fffeff5, 0x77f7ffee, 0xff3fd9ff, 0xfffcfdeb, 0xdeedffbf, 0xffdd7fee, 0xfbddfdbf },
    .{ 0xffbbfbfd, 0xefff79ff, 0xf3effffd, 0xfeff77fd, 0xfddefff7, 0x7bfefff7, 0xdff79fff, 0x7ffeefdf, 0xeffedffb, 0xffbeff7d, 0xf6dfffef, 0x7fffe7f7, 0x1fefffff, 0xefebffbf, 0xff9bfbff, 0xf7ff7eef, 0xfbbebfff, 0xf7cbffff, 0xbfeffddf, 0xf97fffef, 0xfdb3ffff, 0xff7ffb5f, 0xfffffbda, 0xf5fdbfff, 0xffdfd7fe, 0xf3ffbffe, 0xffbfff6b, 0xf95fffff, 0xf7ffff5d, 0xfbbffdbf, 0xeffeebff, 0xfd7fedff, 0x7ffffcfd, 0xfffd7f7b, 0xddfffbbf, 0xbef6ffff, 0xbddfdfff, 0xfeddfdff, 0xdfef7ffb, 0x7fffcfbf, 0xffed3fff, 0x6f7ffffd, 0xbedffffe, 0xfff5ff7e, 0xeffdffaf, 0xdfd7fffb, 0xf5fff7f7, 0x5ffdfbff, 0xfffb7efe, 0xbfedfbff, 0xf97ffbff, 0xb7fdff7f, 0xffedff7b, 0xfff7f9bf, 0x5dffdfff, 0x7ffe9fff, 0x6ffefff7, 0xbf6fffbf, 0xeffff7f3, 0xffb9ffdf, 0x7fdf7fdf, 0x7ffddeff, 0xddefffdf, 0xffff74ff, 0x7ff6ffbf, 0xbbff7ffd, 0xf7fff7bd, 0xfdffdff5, 0xfddffb7f, 0xffff7ebb, 0xfe7f7f7f, 0xfecff7ff, 0xfbdffdef, 0xfd7ffebf, 0x7bffddff, 0xfeefff3f, 0xbfcff7ff, 0xdfdfedff, 0x7ef7f7ff, 0xfeffeff3, 0xffbfefbd, 0xfffbff3d, 0xffbedffe, 0xf9fffbf7, 0xbffbfbdf, 0xfbffb9ff, 0xbefffefe, 0xffdfff5e, 0xeefbff7f, 0xf7bf7bff, 0xffebefef, 0xfdd7ffef, 0xfed7ffbf, 0xfff77efe, 0x6ffffb7f, 0xff6fff5f, 0xbfbf7eff, 0xeffffcfb, 0xbfd7efff, 0xbfbffd7f, 0xfcbffbff, 0xffefffad, 0xfdeeefff, 0xffff3bbf, 0x36ffffff, 0xeeffe7ff, 0xf6fefdff, 0xfcfffebf, 0xfefffef3, 0xfeebffdf, 0x3fffbffd, 0xfdfbeffe, 0xefedf7ff, 0x9fbfffdf, 0x7fefbdff, 0x5fffffcf, 0xdf7fbbff, 0xfefffeed, 0xfbfbfd7f, 0xdfeeefff, 0xfffbebfb, 0xafff9fff, 0xf77f5fff, 0xdffeffcf, 0x6ffffeef, 0x7fffefcf, 0xfeffb5ff, 0xf777f7ff },
    .{ 0xefbf7fff, 0xffffff5d, 0xdffefdff, 0xfff9f7ff, 0xefdeffff, 0xfffecfff, 0xfdfff7fe, 0xfff77f7f, 0xfffeffde, 0xfffdbfef, 0xfffcfdff, 0xbffeffef, 0xeffff7bf, 0xbfff6fff, 0xfffef7fe, 0xff7eff7f, 0xffff7efd, 0xfff6ffdf, 0xfbfefffb, 0xdbfffffd, 0x5ffbffff, 0xfff7ffde, 0x7dffff7f, 0x7ff7fbff, 0xfbafffff, 0xfffbdffd, 0x7dfeffff, 0xfffd7eff, 0xf7bffffe, 0x7efffffb, 0xf3ffffdf, 0xfbfbffef, 0xefff7dff, 0xffbf77ff, 0xffdfdfbf, 0xfdf3ffff, 0x7ff7f7ff, 0xffeff7bf, 0xdfffcfff, 0xeddfffff, 0xffdfdffb, 0xffbbff7f, 0xffeff77f, 0xbffffebf, 0xfbfebfff, 0xf7fedfff, 0xffdffbbf, 0xbffaffff, 0xdffffbfe, 0xffffdfe7, 0xf7dfffdf, 0xff6fffdf, 0xfbfefffd, 0xfbdbffff, 0xffff5ff7, 0xffffdefb, 0xffbfffe7, 0xdfffeff7, 0xfffff7fa, 0xffefeff7, 0xdbfdffff, 0xf7ffffee, 0xdfffff77, 0xffff79ff, 0xffbffe7f, 0xffff7efb, 0xffdfffdd, 0xbfff7ffb, 0xdfdfffdf, 0xfffcefff, 0xfffdb7ff, 0xaffffffe, 0xff7fffaf, 0xdfffdffe, 0xffd7fffb, 0xfffeeffb, 0x7ff9ffff, 0xff7f6fff, 0xff7ff77f, 0xfbfff7fd, 0xdffffbfb, 0xfffdcfff, 0xffffbdfb, 0xfdffdfbf, 0xfff7bbff, 0x5fff7fff, 0xff7df7ff, 0xffffbbbf, 0xffdffbfd, 0xf7fffff5, 0xfe7fefff, 0xbfffffbe, 0xfcfffbff, 0xffefbfbf, 0xfdff7bff, 0xffe3ffff, 0x7effdfff, 0x7ffbfeff, 0xefff7ffe, 0xfdffffe7, 0xfeff7ffd, 0xfffffbf9, 0x3fffffbf, 0xff7f7ffe, 0xaffeffff, 0xfff7fe7f, 0xf7fddfff, 0xffbfeffd, 0xfefffff6, 0xf7febfff, 0xeffbfeff, 0xefffdffd, 0xbfffbfdf, 0xfd7ffffd, 0xff7ffd7f, 0x77ffdfff, 0xffdfffbe, 0xf7f7ffbf, 0xffdfb7ff, 0xfffdffcf, 0xfdfffaff, 0xff7ffbdf, 0xdbffffbf, 0xdbfffdff, 0xf6fbffff, 0xfffffb7b, 0xffedffdf, 0xf5fffffe },
    .{ 0xffffdffd, 0xffffdffd, 0xffffdffd, 0xfffffefd, 0xffffbfdf, 0xfffffefd, 0xffcfffff, 0xffcfffff, 0xfffffbef, 0xfffffbef, 0xffcfffff, 0xffbffffe, 0xbfffbfff, 0xeffffdff, 0xfffff7bf, 0xfffffd7f, 0xfffff6ff, 0xffffdffb, 0xfffff6ff, 0x7ffeffff, 0xfffff6ff, 0xff7f7fff, 0xfeefffff, 0xeffffdff, 0x7ffeffff, 0xfffff6ff, 0xffbffffe, 0xfffffd7f, 0xbfffbfff, 0xfff7fffd, 0xffffbfdf, 0xeffffdff, 0xffffbfdf, 0xffffbfdf, 0xfff7fffd, 0xbfffbfff, 0xfffffefd, 0xeffffdff, 0xbfffbfff, 0xfffff7bf, 0xffffdffd, 0xfeefffff, 0xeffffdff, 0xffbffffe, 0xffcfffff, 0xfffff7bf, 0xfff7fffd, 0xfffffbef, 0xffcfffff, 0xffcfffff, 0xfffffefd, 0xfff7fffd, 0xfffffd7f, 0xbfffbfff, 0xffcfffff, 0xfffffd7f, 0xffbffffe, 0xffffdffd, 0xfeefffff, 0xffcfffff, 0xfeefffff, 0xfffff7bf, 0x7ffeffff, 0xfffff6ff, 0xffffdffd, 0xffffdffb, 0xfffff6ff, 0xffffbfdf, 0xeffffdff, 0xfffffbef, 0xfffff6ff, 0xbfffbfff, 0xffffdffd, 0xffffdffb, 0x7ffeffff, 0xff7f7fff, 0xfffff7bf, 0xfffff6ff, 0xbfffbfff, 0xffbffffe, 0xfffffefd, 0x7ffeffff, 0xffbffffe, 0xfeefffff, 0xfffffbef, 0xfff7fffd, 0xfeefffff, 0xfffff6ff, 0xfffffbef, 0xfffffd7f, 0xfeefffff, 0xfffffd7f, 0x7ffeffff, 0x7ffeffff, 0xfeefffff, 0xfffffd7f, 0xbfffbfff, 0xfffff6ff, 0xeffffdff, 0xeffffdff, 0xffffdffb, 0xfffffefd, 0xffcfffff, 0xfffffd7f, 0x7ffeffff, 0xfffffd7f, 0xffffdffd, 0xffffdffd, 0xffbffffe, 0x7ffeffff, 0xfff7fffd, 0xfffff7bf, 0xfffffd7f, 0xfff7fffd, 0xfffffbef, 0xfffff7bf, 0xffbffffe, 0xfffffefd, 0xbfffbfff, 0xbfffbfff, 0xffcfffff, 0xfffffd7f, 0x7ffeffff, 0xfffff7bf, 0xfff7fffd, 0xfffff7bf, 0xfffff6ff, 0xff7f7fff },
    .{ 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff },
    .{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff },
};
