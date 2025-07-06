const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Input = @import("input.zig");
const Scene = @import("scene.zig");

const MAX_ANCHORS = 8;

const log = std.log;
const perf_counter = @import("perfcounter.zig");

pub const ticks_per_second = 83;
pub const tick: f32 = 1.0 / @as(f32, @floatFromInt(ticks_per_second));
pub const tick_ns: u64 = 1_000_000_000 / ticks_per_second;
pub const max_tick_ns: u64 = 250_000_000;

const window_width = 1920;
const window_height = 1080;

const shadowmap_width = 1024;
const shadowmap_height = 1024;

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
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_LSHIFT }, .sprint);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_TAB }, .toggle_debug_view);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_GRAVE }, .toggle_voxels_follow_camera);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_Q }, .prev_debug_view);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_E }, .next_debug_view);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_F1 }, .trigger_capture);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_0 }, .next_scene);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_9 }, .prev_scene);
    defer input.deinit();

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

    var voxelize_pass = try VoxelizePass.init(gpa, device);
    defer voxelize_pass.deinit();
    var debug_pass = try DebugPass.init(gpa, device);
    defer debug_pass.deinit();
    var draw_pass = try DrawPass.init(gpa, device);
    defer draw_pass.deinit();
    var present_pass = try PresentPass.init(gpa, device, window);
    defer present_pass.deinit();

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
        // if (perf_print_timer.read() > 900_000_000 and frame_timer.read() > 20_000_000) {
        //     try trigger();
        // }

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
            if (input.peek(.toggle_debug_view).pressed) debug_mode = !debug_mode;
            if (input.peek(.trigger_capture).pressed) try trigger();
            if (input.peek(.prev_debug_view).pressed) {
                debug_pass.debug_view = (debug_pass.debug_view + 1) % 2;
            }
            if (input.peek(.next_debug_view).pressed) {
                debug_pass.debug_view = (debug_pass.debug_view + 1) % 2;
            }

            for (scene.motions.items) |*motion| motion.update(tick);

            input.decay();
            lag -= tick_ns;
            time += 1.0 / @as(f64, @floatFromInt(ticks_per_second));
        }

        const alpha = @as(f32, @floatFromInt(lag)) / @as(f32, @floatFromInt(tick_ns));

        const command_buffer = try sdl.acquireGPUCommandBuffer(device);

        const camera_matrix = camera.vp(alpha);
        const light_matrix = zm.mul(
            zm.lookAtRh(
                zm.f32x4(-1.0, 2.0, 0.5, 1.0),
                zm.f32x4s(0.0),
                zm.f32x4(0.0, 1.0, 0.0, 0.0),
            ),
            zm.orthographicRh(32.0, 32.0, 64.0, -64.0),
        );

        {
            try voxelize_pass.begin(command_buffer, camera.anchor(alpha));
            for (scene.objects.items) |object| voxelize_pass.voxelizeObject(
                command_buffer,
                object,
                alpha,
            );
            try voxelize_pass.end(command_buffer);
        }
        {
            try draw_pass.beginShadowmap(command_buffer);
            for (scene.objects.items) |object| draw_pass.drawObjectShadowmap(
                command_buffer,
                object,
                light_matrix,
                alpha,
            );
            draw_pass.endShadowmap(command_buffer);
        }
        try voxelize_pass.inject(
            command_buffer,
            draw_pass.shadowmap_target,
            .{ shadowmap_width, shadowmap_height },
            light_matrix,
            0.5,
        );
        {
            try draw_pass.beginPrepass(command_buffer);
            for (scene.objects.items) |object| draw_pass.drawObjectPrepass(
                command_buffer,
                object,
                camera_matrix,
                alpha,
            );
            draw_pass.endPrepass(command_buffer);
        }
        {
            try draw_pass.begin(command_buffer);
            for (scene.objects.items) |object| draw_pass.drawObject(
                command_buffer,
                object,
                camera_matrix,
                light_matrix,
                alpha,
            );
            draw_pass.end(command_buffer);
        }
        if (debug_mode) try debug_pass.run(
            command_buffer,
            voxelize_pass.anchors,
            voxelize_pass.opacity_cascades[voxelize_pass.ix_new_slot],
            voxelize_pass.diffuse_cascades[voxelize_pass.ix_new_slot],
            camera.v(alpha),
            camera.p(alpha),
        );
        {
            try present_pass.run(
                window,
                command_buffer,
                if (debug_mode) debug_pass.color_target else draw_pass.color_target,
            );
        }

        try sdl.submitGPUCommandBuffer(command_buffer);

        first_frame = false;
    }
}

const PrefixSumPass = struct {
    device: *sdl.GPUDevice,
    pipeline: *sdl.GPUComputePipeline,
    workspace: *sdl.GPUBuffer,

    pub fn init(gpa: std.mem.Allocator, device: *sdl.GPUDevice, max_counts: u32) !PrefixSumPass {
        const pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/prefix.comp.spv",
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
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 2,
                .num_uniform_buffers = 1,
                .threadcount_x = 1,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, pipeline);

        const max_counts_u64: u64 = @intCast(max_counts);
        var workspace_size: u64 = 0;
        workspace_size += (max_counts_u64 + 255) / 256;
        workspace_size += (max_counts_u64 + 65535) / 65536;
        workspace_size += (max_counts_u64 + 16777215) / 16777216;
        workspace_size += (max_counts_u64 + 4294967295) / 4294967296;

        const workspace = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = @as(u32, @intCast(workspace_size)) * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, workspace);

        return .{
            .device = device,
            .pipeline = pipeline,
            .workspace = workspace,
        };
    }

    pub fn deinit(pass: *PrefixSumPass) void {
        sdl.releaseGPUBuffer(pass.device, pass.workspace);
        sdl.releaseGPUComputePipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    pub fn run(
        pass: *PrefixSumPass,
        command_buffer: *sdl.GPUCommandBuffer,
        counts: *sdl.GPUBuffer,
        n_counts: u32,
    ) !void {
        sdl.pushGPUDebugGroup(command_buffer, "prefix_sum");

        const initial_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{
                .{ .buffer = counts },
                .{ .buffer = pass.workspace, .cycle = true },
            },
        );
        sdl.bindGPUComputePipeline(initial_pass, pass.pipeline);
        sdl.pushGPUComputeUniformData(command_buffer, 0, &[3]u32{
            0,
            n_counts,
            0,
        }, @sizeOf([3]u32));
        sdl.dispatchGPUCompute(initial_pass, (n_counts + 255) / 256, 1, 1);
        sdl.endGPUComputePass(initial_pass);

        var n: u32 = (n_counts + 255) / 256;
        var offset: u32 = 0;
        var ns: [4]u32 = undefined;
        var offsets: [4]u32 = undefined;
        var m: u32 = 0;
        while (n > 1) {
            const internal_pass = try sdl.beginGPUComputePass(
                command_buffer,
                &.{},
                &.{
                    .{ .buffer = counts },
                    .{ .buffer = pass.workspace },
                },
            );
            sdl.bindGPUComputePipeline(internal_pass, pass.pipeline);
            sdl.pushGPUComputeUniformData(command_buffer, 0, &[3]u32{
                1,
                n,
                offset,
            }, @sizeOf([3]u32));
            sdl.dispatchGPUCompute(internal_pass, (n + 255) / 256, 1, 1);
            sdl.endGPUComputePass(internal_pass);

            ns[m] = n;
            offsets[m] = offset;
            m += 1;

            offset += n;
            n = (n + 255) / 256;
        }

        while (m > 1) {
            n = ns[m - 2];
            offset = offsets[m - 2];

            const internal_pass = try sdl.beginGPUComputePass(
                command_buffer,
                &.{},
                &.{
                    .{ .buffer = counts },
                    .{ .buffer = pass.workspace },
                },
            );
            sdl.bindGPUComputePipeline(internal_pass, pass.pipeline);
            sdl.pushGPUComputeUniformData(command_buffer, 0, &[3]u32{
                2,
                n,
                offset,
            }, @sizeOf([3]u32));
            sdl.dispatchGPUCompute(internal_pass, (n + 255) / 256, 1, 1);
            sdl.endGPUComputePass(internal_pass);

            ns[m] = n;
            offsets[m] = offset;
            m -= 1;
        }

        if (m > 0) {
            const final_pass = try sdl.beginGPUComputePass(
                command_buffer,
                &.{},
                &.{
                    .{ .buffer = counts },
                    .{ .buffer = pass.workspace },
                },
            );
            sdl.bindGPUComputePipeline(final_pass, pass.pipeline);
            sdl.pushGPUComputeUniformData(command_buffer, 0, &[3]u32{
                3,
                n_counts,
                0,
            }, @sizeOf([3]u32));
            sdl.dispatchGPUCompute(final_pass, (n_counts + 255) / 256, 1, 1);
            sdl.endGPUComputePass(final_pass);
        }

        sdl.popGPUDebugGroup(command_buffer);
    }
};

const DebugPass = struct {
    const DebugUBO = extern struct {
        inverse_view_matrix: [16]f32 align(16),
        inverse_projection_matrix: [16]f32 align(16),
        debug_view: u32 align(16),
    };
    device: *sdl.GPUDevice,

    pipeline: *sdl.GPUComputePipeline,
    color_target: *sdl.GPUTexture,

    debug_view: u32 = 0,

    fn init(gpa: std.mem.Allocator, device: *sdl.GPUDevice) !DebugPass {
        const debug_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/debug.comp.spv",
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
                .num_readwrite_storage_textures = 1,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 2,
                .threadcount_x = 8,
                .threadcount_y = 8,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, debug_pipeline);

        const color_target = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT, // spherical harmonic
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 640,
            .height = 360,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, color_target);

        return .{
            .device = device,
            .pipeline = debug_pipeline,
            .color_target = color_target,
        };
    }

    fn deinit(pass: *DebugPass) void {
        sdl.releaseGPUTexture(pass.device, pass.color_target);
        sdl.releaseGPUComputePipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn run(
        pass: *DebugPass,
        command_buffer: *sdl.GPUCommandBuffer,
        cascade_anchors: [MAX_ANCHORS][4]f32,
        opacity_cascades: *sdl.GPUBuffer,
        diffuse_cascades: *sdl.GPUBuffer,
        camera_view: zm.Mat,
        camera_projection: zm.Mat,
    ) !void {
        sdl.pushGPUDebugGroup(command_buffer, "debug");
        const debug_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{.{ .texture = pass.color_target, .cycle = true }},
            &.{},
        );
        sdl.bindGPUComputePipeline(debug_pass, pass.pipeline);
        sdl.bindGPUComputeStorageBuffers(debug_pass, 0, &.{
            opacity_cascades,
            diffuse_cascades,
        });
        sdl.pushGPUComputeUniformData(command_buffer, 0, &VoxelizePass.CommonUBO{
            .cascade_size = VoxelizePass.cascade_size,
            .cascade_mask = VoxelizePass.cascade_mask,
            .n_cascades = VoxelizePass.n_cascades,
            .min_voxel_size = VoxelizePass.min_voxel_size,
            .anchors = cascade_anchors,
        }, @sizeOf(VoxelizePass.CommonUBO));
        sdl.pushGPUComputeUniformData(command_buffer, 1, &DebugUBO{
            .inverse_view_matrix = zm.matToArr(zm.inverse(camera_view)),
            .inverse_projection_matrix = zm.matToArr(zm.inverse(camera_projection)),
            .debug_view = pass.debug_view,
        }, @sizeOf(DebugUBO));
        sdl.dispatchGPUCompute(debug_pass, (640 + 7) / 8, (360 + 7) / 8, 1);
        sdl.endGPUComputePass(debug_pass);
        sdl.popGPUDebugGroup(command_buffer);
    }
};

const VoxelizePass = struct {
    const CommonUBO = extern struct {
        cascade_size: [4]u32 align(16),
        cascade_mask: [4]u32 align(16),
        n_cascades: u32 align(16),
        min_voxel_size: f32,
        anchors: [MAX_ANCHORS][4]f32 align(16),
    };
    const ClearUBO = extern struct {
        anchor_moves: [MAX_ANCHORS][4]f32 align(16),
        clear_mask: u32 align(16),
    };
    const VoxelizeUBO = extern struct {
        model_matrix: [16]f32 align(16),
        diffuse: [4]f32 align(16),
        emissive: [4]f32 align(16),

        target_cascade: u32 align(16),
        n_triangles: u32,
        first_index: u32,
        first_vertex: u32,
    };
    const AverageUBO = extern struct {
        anchor_moves: [MAX_ANCHORS][4]f32 align(16),
        half_life: f32 align(16),
    };
    const InjectUBO = extern struct {
        inverse_light_space_matrix: [16]f32 align(16),
        light_intensity: f32,
    };
    const PrefixUBO = extern struct {
        mode: u32,
        pass: u32,
        n_bins: u32,
        offset_in: u32,
        offset_out: u32,
        block_sums_offset: u32,
    };

    // these could be runtime values to allow for e.g. graphics settings
    const min_voxel_size = 0.1618;
    const n_cascades = 8;
    const cascade_size: [4]u32 = .{ 64, 64, 64, 64 * 64 * 64 }; // must be power of two
    const len_cascades = n_cascades * cascade_size[0] * cascade_size[1] * cascade_size[2];
    const cascade_mask: [4]u32 = .{
        cascade_size[0] - 1,
        cascade_size[1] - 1,
        cascade_size[2] - 1,
        cascade_size[0] * cascade_size[1] * cascade_size[2] - 1,
    };
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
    voxelize_pipeline: *sdl.GPUComputePipeline,
    average_pipeline: *sdl.GPUComputePipeline,
    active_pass: ?*sdl.GPUComputePass = null,

    // we're gonna handle it like this
    // opacity targets/diffuse targets hold the latest true info
    // we scroll them as part of the clear step
    // and edge fill with data from the next cascade
    // when we scroll by moving the cascade anchor
    // we simply reproject the previous opacity cascades based on the move
    // and if the move is large and there's no data, reproject from the next cascade instead
    // then we blend the reprojected result with what's in opacity targets

    opacity_targets: [2]*sdl.GPUBuffer,
    diffuse_targets: [2]*sdl.GPUBuffer,

    opacity_cascades: [2]*sdl.GPUBuffer,
    diffuse_cascades: [2]*sdl.GPUBuffer,

    luma_cascades: *sdl.GPUTexture,
    chroma_cascades: *sdl.GPUTexture,

    ix_time_slice: u32 = @intCast(time_slices.len - 1),
    anchors: [MAX_ANCHORS][4]f32 = .{.{ 0.0, 0.0, 0.0, 0.0 }} ** MAX_ANCHORS,
    anchor_moves: [MAX_ANCHORS][4]f32 = .{.{ 0.0, 0.0, 0.0, 0.0 }} ** MAX_ANCHORS,
    ix_old_slot: u32 = 0,
    ix_new_slot: u32 = 1,

    bitmask_texture: *sdl.GPUTexture,
    sampler: *sdl.GPUSampler,

    // we take every four pixels from the shadowmap
    // compute position, and add to count for the voxel
    // then perform a prefix sum of the counts
    // then reprocess the shadowmap, write the normal and intensity to the bins
    // finally, process each bin, adding the light to the voxel

    count_pipeline: *sdl.GPUComputePipeline,
    assign_pipeline: *sdl.GPUComputePipeline,
    inject_pipeline: *sdl.GPUComputePipeline,

    prefix_pass: PrefixSumPass,

    bin_counters: *sdl.GPUBuffer,
    bin_offsets: *sdl.GPUBuffer,
    bins: *sdl.GPUBuffer,

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
                .num_readonly_storage_buffers = 2,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 4,
                .num_uniform_buffers = 2,
                .threadcount_x = 64,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, clear_pipeline);

        const voxelize_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/voxelize.comp.spv",
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
                .num_samplers = 1,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 2,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 2,
                .num_uniform_buffers = 2,
                .threadcount_x = 64,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, voxelize_pipeline);

        const average_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/average.comp.spv",
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
                .num_readonly_storage_buffers = 4,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 2,
                .num_uniform_buffers = 2,
                .threadcount_x = 64,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, average_pipeline);

        const count_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/count.comp.spv",
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
                .num_samplers = 1,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 0,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 1,
                .num_uniform_buffers = 2,
                .threadcount_x = 8,
                .threadcount_y = 8,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, count_pipeline);

        const assign_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/assign.comp.spv",
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
                .num_samplers = 1,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 1,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 2,
                .num_uniform_buffers = 2,
                .threadcount_x = 8,
                .threadcount_y = 8,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, assign_pipeline);

        const inject_pipeline = blk: {
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
                .num_samplers = 0,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 5,
                .num_readwrite_storage_textures = 2,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 1,
                .threadcount_x = 64,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, inject_pipeline);

        var opacity_targets: [2]*sdl.GPUBuffer = undefined;
        opacity_targets[0] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, opacity_targets[0]);
        opacity_targets[1] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, opacity_targets[1]);

        var diffuse_targets: [2]*sdl.GPUBuffer = undefined;
        diffuse_targets[0] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, diffuse_targets[0]);
        diffuse_targets[1] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, diffuse_targets[1]);

        var opacity_cascades: [2]*sdl.GPUBuffer = undefined;
        opacity_cascades[0] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(f32),
        });
        errdefer sdl.releaseGPUBuffer(device, opacity_cascades[0]);
        opacity_cascades[1] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(f32),
        });
        errdefer sdl.releaseGPUBuffer(device, opacity_cascades[1]);

        var diffuse_cascades: [2]*sdl.GPUBuffer = undefined;
        diffuse_cascades[0] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, diffuse_cascades[0]);
        diffuse_cascades[1] = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, diffuse_cascades[1]);

        const bin_counters = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, bin_counters);

        const bin_offsets = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = len_cascades * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, bin_offsets);

        const bins = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = shadowmap_width * shadowmap_height * 2 * @sizeOf(u32),
        });
        errdefer sdl.releaseGPUBuffer(device, bins);

        const luma_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT, // spherical harmonic
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = cascade_size[0] * n_cascades,
            .height = cascade_size[1],
            .layer_count_or_depth = cascade_size[2],
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, luma_cascades);

        const chroma_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = cascade_size[0] * n_cascades,
            .height = cascade_size[1],
            .layer_count_or_depth = cascade_size[2],
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, chroma_cascades);

        const sampler = try sdl.createGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        });
        errdefer sdl.releaseGPUSampler(device, sampler);

        const bitmask_texture = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R32_UINT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 256,
            .height = 33,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, bitmask_texture);
        const transfer_buffer = try sdl.createGPUTransferBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = 33 * 256 * @sizeOf(u32),
        });
        defer sdl.releaseGPUTransferBuffer(device, transfer_buffer);
        const command_buffer = try sdl.acquireGPUCommandBuffer(device);
        const bytes: [*]u8 = @alignCast(@ptrCast(
            try sdl.mapGPUTransferBuffer(device, transfer_buffer, true),
        ));
        @memcpy(@as([*][256]u32, @alignCast(@ptrCast(bytes))), &random_u32_bits);
        sdl.unmapGPUTransferBuffer(device, transfer_buffer);
        const copy_pass = try sdl.beginGPUCopyPass(command_buffer);
        sdl.uploadToGPUTexture(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, &.{
            .texture = bitmask_texture,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = 256,
            .h = 33,
            .d = 1,
        }, false);
        sdl.endGPUCopyPass(copy_pass);
        try sdl.submitGPUCommandBuffer(command_buffer);

        var prefix_pass = try PrefixSumPass.init(gpa, device, len_cascades);
        errdefer prefix_pass.deinit();

        return .{
            .device = device,
            .clear_pipeline = clear_pipeline,
            .voxelize_pipeline = voxelize_pipeline,
            .average_pipeline = average_pipeline,
            .sampler = sampler,
            .opacity_targets = opacity_targets,
            .diffuse_targets = diffuse_targets,
            .opacity_cascades = opacity_cascades,
            .diffuse_cascades = diffuse_cascades,
            .luma_cascades = luma_cascades,
            .chroma_cascades = chroma_cascades,
            .bitmask_texture = bitmask_texture,
            .count_pipeline = count_pipeline,
            .assign_pipeline = assign_pipeline,
            .inject_pipeline = inject_pipeline,
            .prefix_pass = prefix_pass,
            .bin_counters = bin_counters,
            .bin_offsets = bin_offsets,
            .bins = bins,
        };
    }

    fn deinit(pass: *VoxelizePass) void {
        sdl.releaseGPUBuffer(pass.device, pass.bins);
        sdl.releaseGPUBuffer(pass.device, pass.bin_offsets);
        sdl.releaseGPUBuffer(pass.device, pass.bin_counters);
        pass.prefix_pass.deinit();
        sdl.releaseGPUTexture(pass.device, pass.bitmask_texture);
        sdl.releaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUTexture(pass.device, pass.chroma_cascades);
        sdl.releaseGPUTexture(pass.device, pass.luma_cascades);
        for (0..2) |i| {
            sdl.releaseGPUBuffer(pass.device, pass.diffuse_cascades[i]);
            sdl.releaseGPUBuffer(pass.device, pass.opacity_cascades[i]);
            sdl.releaseGPUBuffer(pass.device, pass.diffuse_targets[i]);
            sdl.releaseGPUBuffer(pass.device, pass.opacity_targets[i]);
        }
        sdl.releaseGPUComputePipeline(pass.device, pass.inject_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.assign_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.count_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.average_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.voxelize_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.clear_pipeline);
        pass.* = undefined;
    }

    fn begin(pass: *VoxelizePass, command_buffer: *sdl.GPUCommandBuffer, anchor: [3]f32) !void {
        sdl.pushGPUDebugGroup(command_buffer, "voxelize");

        pass.ix_time_slice = (pass.ix_time_slice + 1) % @as(u32, @intCast(time_slices.len));
        std.mem.swap(u32, &pass.ix_old_slot, &pass.ix_new_slot);
        // TODO update anchors
        // std.debug.print("\n{any}\n", .{anchor});
        for (0..n_cascades) |i| {
            const cascade_voxel_size = min_voxel_size * std.math.pow(f32, 2.0, @floatFromInt(i));
            const old_anchor = pass.anchors[i];
            pass.anchors[i] = .{
                2.0 * cascade_voxel_size * @floor(0.5 * anchor[0] / cascade_voxel_size),
                2.0 * cascade_voxel_size * @floor(0.5 * anchor[1] / cascade_voxel_size),
                2.0 * cascade_voxel_size * @floor(0.5 * anchor[2] / cascade_voxel_size),
                0.0,
            };
            pass.anchor_moves[i] = .{
                pass.anchors[i][0] - old_anchor[0],
                pass.anchors[i][1] - old_anchor[1],
                pass.anchors[i][2] - old_anchor[2],
                0.0,
            };
            // std.debug.print("{}\t{any}\t{any}\n", .{ i, pass.anchors[i], pass.anchor_moves[i] });
        }

        var clear_mask: u32 = 0;
        for (time_slices[pass.ix_time_slice]) |target_cascade| {
            clear_mask |= (@as(u32, 1) << @intCast(target_cascade));
        }

        sdl.pushGPUDebugGroup(command_buffer, "clear");
        const clear_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{
                .{ .buffer = pass.opacity_targets[pass.ix_new_slot], .cycle = true },
                .{ .buffer = pass.diffuse_targets[pass.ix_new_slot], .cycle = true },
                .{ .buffer = pass.bin_counters, .cycle = true },
                .{ .buffer = pass.bin_offsets, .cycle = true },
            },
        );
        sdl.bindGPUComputePipeline(clear_pass, pass.clear_pipeline);
        sdl.bindGPUComputeStorageBuffers(clear_pass, 0, &.{
            pass.opacity_targets[pass.ix_old_slot],
            pass.diffuse_targets[pass.ix_old_slot],
        });
        sdl.pushGPUComputeUniformData(command_buffer, 0, &CommonUBO{
            .cascade_size = cascade_size,
            .cascade_mask = cascade_mask,
            .n_cascades = n_cascades,
            .min_voxel_size = min_voxel_size,
            .anchors = pass.anchors,
        }, @sizeOf(CommonUBO));
        sdl.pushGPUComputeUniformData(command_buffer, 1, &ClearUBO{
            .anchor_moves = pass.anchor_moves,
            .clear_mask = clear_mask,
        }, @sizeOf(ClearUBO));
        sdl.dispatchGPUCompute(clear_pass, (len_cascades + 63) / 64, 1, 1);
        sdl.endGPUComputePass(clear_pass);
        sdl.popGPUDebugGroup(command_buffer);

        pass.active_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{
                .{ .buffer = pass.opacity_targets[pass.ix_new_slot] },
                .{ .buffer = pass.diffuse_targets[pass.ix_new_slot] },
            },
        );
        sdl.bindGPUComputePipeline(pass.active_pass.?, pass.voxelize_pipeline);
        sdl.bindGPUComputeSamplers(pass.active_pass.?, 0, &.{
            .{ .texture = pass.bitmask_texture, .sampler = pass.sampler },
        });
        sdl.pushGPUComputeUniformData(command_buffer, 0, &CommonUBO{
            .cascade_size = cascade_size,
            .cascade_mask = cascade_mask,
            .n_cascades = n_cascades,
            .min_voxel_size = min_voxel_size,
            .anchors = pass.anchors,
        }, @sizeOf(CommonUBO));
    }

    fn voxelizeObject(
        pass: *VoxelizePass,
        command_buffer: *sdl.GPUCommandBuffer,
        object: Scene.Object,
        alpha: f32,
    ) void {
        sdl.bindGPUComputeStorageBuffers(pass.active_pass.?, 0, &.{
            object.model.vertex_buffer,
            object.model.index_buffer,
        });
        const transform = object.transform(alpha);
        const n_triangles: u32 = object.model.n_indices / 3;

        for (time_slices[pass.ix_time_slice]) |target_cascade| {
            sdl.pushGPUComputeUniformData(
                command_buffer,
                1,
                &VoxelizeUBO{
                    .model_matrix = zm.matToArr(transform),
                    .diffuse = object.diffuse,
                    .emissive = object.emissive,
                    .target_cascade = target_cascade,
                    .n_triangles = n_triangles,
                    .first_index = object.model.first_index,
                    .first_vertex = object.model.first_vertex,
                },
                @sizeOf(VoxelizeUBO),
            );
            sdl.dispatchGPUCompute(
                pass.active_pass.?,
                (n_triangles + 63) / 64,
                1,
                1,
            );
        }
    }

    fn end(pass: *VoxelizePass, command_buffer: *sdl.GPUCommandBuffer) !void {
        sdl.endGPUComputePass(pass.active_pass.?);
        pass.active_pass = null;

        sdl.pushGPUDebugGroup(command_buffer, "average");
        const average_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{
                .{ .buffer = pass.opacity_cascades[pass.ix_new_slot], .cycle = true },
                .{ .buffer = pass.diffuse_cascades[pass.ix_new_slot], .cycle = true },
            },
        );
        sdl.bindGPUComputePipeline(average_pass, pass.average_pipeline);
        sdl.bindGPUComputeStorageBuffers(average_pass, 0, &.{
            pass.opacity_targets[pass.ix_new_slot],
            pass.diffuse_targets[pass.ix_new_slot],
            pass.opacity_cascades[pass.ix_old_slot],
            pass.diffuse_cascades[pass.ix_old_slot],
        });
        sdl.pushGPUComputeUniformData(command_buffer, 0, &CommonUBO{
            .cascade_size = cascade_size,
            .cascade_mask = cascade_mask,
            .n_cascades = n_cascades,
            .min_voxel_size = min_voxel_size,
            .anchors = pass.anchors,
        }, @sizeOf(CommonUBO));
        sdl.pushGPUComputeUniformData(command_buffer, 1, &AverageUBO{
            .anchor_moves = pass.anchor_moves,
            .half_life = 1.0, // NOTE think about units?
        }, @sizeOf(AverageUBO));
        sdl.dispatchGPUCompute(average_pass, (len_cascades + 63) / 64, 1, 1);
        sdl.endGPUComputePass(average_pass);
        sdl.popGPUDebugGroup(command_buffer);

        sdl.popGPUDebugGroup(command_buffer);
    }

    fn inject(
        pass: *VoxelizePass,
        command_buffer: *sdl.GPUCommandBuffer,
        shadowmap: *sdl.GPUTexture,
        shadowmap_size: [2]u32,
        light_space_matrix: zm.Mat,
        light_intensity: f32,
    ) !void {
        sdl.pushGPUDebugGroup(command_buffer, "inject");

        const count_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{
                .{ .buffer = pass.bin_offsets },
            },
        );
        sdl.bindGPUComputePipeline(count_pass, pass.count_pipeline);
        sdl.bindGPUComputeSamplers(count_pass, 0, &.{
            .{ .texture = shadowmap, .sampler = pass.sampler },
        });
        sdl.pushGPUComputeUniformData(command_buffer, 0, &CommonUBO{
            .cascade_size = cascade_size,
            .cascade_mask = cascade_mask,
            .n_cascades = n_cascades,
            .min_voxel_size = min_voxel_size,
            .anchors = pass.anchors,
        }, @sizeOf(CommonUBO));
        sdl.pushGPUComputeUniformData(command_buffer, 1, &InjectUBO{
            .inverse_light_space_matrix = zm.matToArr(zm.inverse(light_space_matrix)),
            .light_intensity = light_intensity,
        }, @sizeOf(InjectUBO));
        sdl.dispatchGPUCompute(
            count_pass,
            (shadowmap_size[0] + 7) / 8,
            (shadowmap_size[1] + 7) / 8,
            1,
        );
        sdl.endGPUComputePass(count_pass);

        try pass.prefix_pass.run(command_buffer, pass.bin_offsets, len_cascades);

        const assign_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{
                .{ .buffer = pass.bins, .cycle = true },
                .{ .buffer = pass.bin_counters },
            },
        );
        sdl.bindGPUComputePipeline(assign_pass, pass.assign_pipeline);
        sdl.bindGPUComputeSamplers(assign_pass, 0, &.{
            .{ .texture = shadowmap, .sampler = pass.sampler },
        });
        sdl.bindGPUComputeStorageBuffers(assign_pass, 0, &.{
            pass.bin_offsets,
        });
        sdl.pushGPUComputeUniformData(command_buffer, 0, &CommonUBO{
            .cascade_size = cascade_size,
            .cascade_mask = cascade_mask,
            .n_cascades = n_cascades,
            .min_voxel_size = min_voxel_size,
            .anchors = pass.anchors,
        }, @sizeOf(CommonUBO));
        sdl.pushGPUComputeUniformData(command_buffer, 1, &InjectUBO{
            .inverse_light_space_matrix = zm.matToArr(zm.inverse(light_space_matrix)),
            .light_intensity = light_intensity,
        }, @sizeOf(InjectUBO));
        sdl.dispatchGPUCompute(
            assign_pass,
            (shadowmap_size[0] + 7) / 8,
            (shadowmap_size[1] + 7) / 8,
            1,
        );
        sdl.endGPUComputePass(assign_pass);

        const inject_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{
                .{ .texture = pass.luma_cascades, .cycle = true },
                .{ .texture = pass.chroma_cascades, .cycle = true },
            },
            &.{},
        );
        sdl.bindGPUComputePipeline(inject_pass, pass.inject_pipeline);
        sdl.bindGPUComputeStorageBuffers(assign_pass, 0, &.{
            pass.bin_counters,
            pass.bin_offsets,
            pass.bins,
            pass.opacity_cascades[pass.ix_new_slot],
            pass.diffuse_cascades[pass.ix_new_slot],
        });
        sdl.pushGPUComputeUniformData(command_buffer, 0, &CommonUBO{
            .cascade_size = cascade_size,
            .cascade_mask = cascade_mask,
            .n_cascades = n_cascades,
            .min_voxel_size = min_voxel_size,
            .anchors = pass.anchors,
        }, @sizeOf(CommonUBO));
        sdl.dispatchGPUCompute(inject_pass, (len_cascades + 63) / 64, 1, 1);
        sdl.endGPUComputePass(inject_pass);

        sdl.popGPUDebugGroup(command_buffer);
    }
};

const DrawPass = struct {
    const VertexUBO = extern struct {
        mvp_matrix: [16]f32 align(16),
        normal_matrix: [16]f32 align(16),
        model_matrix: [16]f32 align(16),
        light_space_matrix: [16]f32 align(16),
    };
    const FragmentUBO = extern struct {
        diffuse: [4]f32 align(16),
        emissive: [4]f32 align(16),
        roughness: f32,
    };

    device: *sdl.GPUDevice,
    pipeline: *sdl.GPUGraphicsPipeline,
    prepass_pipeline: *sdl.GPUGraphicsPipeline,
    shadowmap_pipeline: *sdl.GPUGraphicsPipeline,

    active_pass: ?*sdl.GPURenderPass = null,

    color_target: *sdl.GPUTexture,
    depth_target: *sdl.GPUTexture,

    shadowmap_target: *sdl.GPUTexture,

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
                .num_samplers = 1,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 1,
            });
        };
        defer sdl.releaseGPUShader(device, fragment_shader);

        const fragment_shader_prepass = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/prepass.frag.spv",
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
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 0,
            });
        };
        defer sdl.releaseGPUShader(device, fragment_shader_prepass);

        const fragment_shader_shadowmap = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/shadowmap.frag.spv",
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
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 0,
            });
        };
        defer sdl.releaseGPUShader(device, fragment_shader_shadowmap);

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
                .compare_op = sdl.c.SDL_GPU_COMPAREOP_EQUAL,
                .enable_depth_test = true,
                .enable_depth_write = true, // i assume it doesn't matter?
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
        const prepass_pipeline_create_info = sdl.GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader_prepass,
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
                .color_target_descriptions = null,
                .num_color_targets = 0,
                .depth_stencil_format = @intCast(depth_stencil_format),
                .has_depth_stencil_target = true,
            },
        };
        const prepass_pipeline = try sdl.createGPUGraphicsPipeline(
            device,
            &prepass_pipeline_create_info,
        );
        errdefer sdl.releaseGPUGraphicsPipeline(device, prepass_pipeline);
        const shadowmap_pipeline_create_info = sdl.GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader_shadowmap,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &vertex_buffer_descriptions[0],
                .num_vertex_buffers = vertex_buffer_descriptions.len,
                .vertex_attributes = &vertex_attributes[0],
                .num_vertex_attributes = vertex_attributes.len,
            },
            .primitive_type = sdl.c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .rasterizer_state = .{
                .front_face = sdl.c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
                .cull_mode = sdl.c.SDL_GPU_CULLMODE_NONE,
            },
            .multisample_state = .{},
            .depth_stencil_state = .{
                .compare_op = sdl.c.SDL_GPU_COMPAREOP_GREATER,
                .enable_depth_test = true,
                .enable_depth_write = true,
            },
            .target_info = .{
                .color_target_descriptions = null,
                .num_color_targets = 0,
                .depth_stencil_format = @intCast(depth_stencil_format),
                .has_depth_stencil_target = true,
            },
        };
        const shadowmap_pipeline = try sdl.createGPUGraphicsPipeline(
            device,
            &shadowmap_pipeline_create_info,
        );
        errdefer sdl.releaseGPUGraphicsPipeline(device, shadowmap_pipeline);

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

        const shadowmap_target = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = @intCast(depth_stencil_format),
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = shadowmap_width,
            .height = shadowmap_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, shadowmap_target);

        const sampler = try sdl.createGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        });
        errdefer sdl.releaseGPUSampler(device, sampler);

        return .{
            .device = device,
            .pipeline = pipeline,
            .prepass_pipeline = prepass_pipeline,
            .shadowmap_pipeline = shadowmap_pipeline,
            .color_target = color_target,
            .depth_target = depth_target,
            .shadowmap_target = shadowmap_target,
            .sampler = sampler,
        };
    }

    fn deinit(pass: *DrawPass) void {
        sdl.releaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUTexture(pass.device, pass.shadowmap_target);
        sdl.releaseGPUTexture(pass.device, pass.depth_target);
        sdl.releaseGPUTexture(pass.device, pass.color_target);
        sdl.releaseGPUGraphicsPipeline(pass.device, pass.shadowmap_pipeline);
        sdl.releaseGPUGraphicsPipeline(pass.device, pass.prepass_pipeline);
        sdl.releaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn beginPrepass(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
    ) !void {
        std.debug.assert(pass.active_pass == null);
        sdl.pushGPUDebugGroup(command_buffer, "prepass");

        pass.active_pass = try sdl.beginGPURenderPass(
            command_buffer,
            &.{},
            &.{
                .texture = pass.depth_target,
                .clear_depth = 0,
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
        );
        sdl.bindGPUGraphicsPipeline(pass.active_pass.?, pass.prepass_pipeline);
    }

    fn drawObjectPrepass(
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
            pass.active_pass.?,
            0,
            &vertex_buffers,
        );
        sdl.bindGPUIndexBuffer(
            pass.active_pass.?,
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
            .light_space_matrix = zm.matToArr(zm.identity()),
        }, @sizeOf(VertexUBO));
        sdl.drawGPUIndexedPrimitives(
            pass.active_pass.?,
            object.model.n_indices,
            1,
            object.model.first_index,
            @intCast(object.model.first_vertex),
            0,
        );
    }

    fn endPrepass(pass: *DrawPass, command_buffer: *sdl.GPUCommandBuffer) void {
        sdl.endGPURenderPass(pass.active_pass.?);
        pass.active_pass = null;

        sdl.popGPUDebugGroup(command_buffer);
    }

    fn beginShadowmap(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
    ) !void {
        std.debug.assert(pass.active_pass == null);
        sdl.pushGPUDebugGroup(command_buffer, "shadowmap");

        pass.active_pass = try sdl.beginGPURenderPass(
            command_buffer,
            &.{},
            &.{
                .texture = pass.shadowmap_target,
                .clear_depth = 0,
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
        );
        sdl.bindGPUGraphicsPipeline(pass.active_pass.?, pass.shadowmap_pipeline);
    }

    fn drawObjectShadowmap(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
        object: Scene.Object,
        light_space_matrix: zm.Mat,
        alpha: f32,
    ) void {
        const vertex_buffers = [_]sdl.c.SDL_GPUBufferBinding{
            .{ .buffer = object.model.vertex_buffer, .offset = 0 },
        };
        sdl.bindGPUVertexBuffers(
            pass.active_pass.?,
            0,
            &vertex_buffers,
        );
        sdl.bindGPUIndexBuffer(
            pass.active_pass.?,
            &.{ .buffer = object.model.index_buffer, .offset = 0 },
            sdl.c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
        );
        const model = object.transform(alpha);
        const mvp = zm.mul(model, light_space_matrix);
        const normal = zm.transpose(zm.inverse(model));
        sdl.pushGPUVertexUniformData(command_buffer, 0, &VertexUBO{
            .mvp_matrix = zm.matToArr(mvp),
            .normal_matrix = zm.matToArr(normal),
            .model_matrix = zm.matToArr(model),
            .light_space_matrix = zm.matToArr(zm.identity()),
        }, @sizeOf(VertexUBO));
        sdl.drawGPUIndexedPrimitives(
            pass.active_pass.?,
            object.model.n_indices,
            1,
            object.model.first_index,
            @intCast(object.model.first_vertex),
            0,
        );
    }

    fn endShadowmap(pass: *DrawPass, command_buffer: *sdl.GPUCommandBuffer) void {
        sdl.endGPURenderPass(pass.active_pass.?);
        pass.active_pass = null;

        sdl.popGPUDebugGroup(command_buffer);
    }

    fn begin(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
    ) !void {
        std.debug.assert(pass.active_pass == null);
        sdl.pushGPUDebugGroup(command_buffer, "draw");

        const color_target_infos = [_]sdl.GPUColorTargetInfo{
            .{
                .texture = pass.color_target,
                .clear_color = sdl.FColor{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 },
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
        };
        pass.active_pass = try sdl.beginGPURenderPass(
            command_buffer,
            &color_target_infos,
            &.{
                .texture = pass.depth_target,
                .load_op = sdl.c.SDL_GPU_LOADOP_LOAD,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE, // doesn't matter?
            },
        );
        sdl.bindGPUGraphicsPipeline(pass.active_pass.?, pass.pipeline);
        sdl.bindGPUFragmentSamplers(pass.active_pass.?, 0, &.{
            .{ .texture = pass.shadowmap_target, .sampler = pass.sampler },
        });
    }

    fn drawObject(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
        object: Scene.Object,
        camera_vp: zm.Mat,
        light_space_matrix: zm.Mat,
        alpha: f32,
    ) void {
        const vertex_buffers = [_]sdl.c.SDL_GPUBufferBinding{
            .{ .buffer = object.model.vertex_buffer, .offset = 0 },
        };
        sdl.bindGPUVertexBuffers(
            pass.active_pass.?,
            0,
            &vertex_buffers,
        );
        sdl.bindGPUIndexBuffer(
            pass.active_pass.?,
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
            .light_space_matrix = zm.matToArr(light_space_matrix),
        }, @sizeOf(VertexUBO));
        sdl.pushGPUFragmentUniformData(command_buffer, 0, &FragmentUBO{
            .diffuse = object.diffuse,
            .emissive = object.emissive,
            .roughness = object.roughness,
        }, @sizeOf(FragmentUBO));
        sdl.drawGPUIndexedPrimitives(
            pass.active_pass.?,
            object.model.n_indices,
            1,
            object.model.first_index,
            @intCast(object.model.first_vertex),
            0,
        );
    }

    fn end(pass: *DrawPass, command_buffer: *sdl.GPUCommandBuffer) void {
        sdl.endGPURenderPass(pass.active_pass.?);
        pass.active_pass = null;

        sdl.popGPUDebugGroup(command_buffer);
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

const Camera = struct {
    pos: zm.Vec,
    yaw: f32,
    pitch: f32,

    prev_pos: zm.Vec,
    prev_yaw: f32,
    prev_pitch: f32,

    const up = zm.f32x4(0.0, 1.0, 0.0, 0.0);
    const mouse_sensitivity = 0.3;
    const move_speed: f32 = 10.0;

    fn update(camera: *Camera, input: *Input) void {
        // mouse-look camera
        camera.prev_pos = camera.pos;
        camera.prev_yaw = camera.yaw;
        camera.prev_pitch = camera.pitch;

        camera.yaw += input.mouse_delta[0] * mouse_sensitivity * tick;
        camera.pitch -= input.mouse_delta[1] * mouse_sensitivity * tick;
        camera.pitch = std.math.clamp(camera.pitch, -0.49 * std.math.pi, 0.49 * std.math.pi);

        var speed: f32 = move_speed * tick;
        if (input.peek(.sprint).held) speed *= 10.0;

        const forward = zm.f32x4(
            @cos(camera.yaw),
            0.0,
            @sin(camera.yaw),
            0.0,
        ) * zm.f32x4s(speed);

        const right = zm.f32x4(
            @cos(camera.yaw + 0.5 * std.math.pi),
            0.0,
            @sin(camera.yaw + 0.5 * std.math.pi),
            0.0,
        ) * zm.f32x4s(speed);

        if (input.peek(.forward).held) camera.pos += forward;
        if (input.peek(.backward).held) camera.pos -= forward;
        if (input.peek(.right).held) camera.pos += right;
        if (input.peek(.left).held) camera.pos -= right;
        if (input.peek(.up).held) camera.pos += up * zm.f32x4s(speed);
        if (input.peek(.down).held) camera.pos -= up * zm.f32x4s(speed);
    }

    fn anchor(camera: *Camera, alpha: f32) [3]f32 {
        const pos = zm.lerp(camera.prev_pos, camera.pos, alpha);
        return zm.vecToArr3(pos);
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
        return perspectiveFovRhInv(std.math.degreesToRadians(54), 16.0 / 9.0, 0.1);
    }

    fn vp(camera: Camera, alpha: f32) zm.Mat {
        return zm.mul(
            camera.v(alpha),
            camera.p(alpha),
        );
    }
};

pub fn perspectiveFovRhInv(fovy: f32, aspect: f32, near: f32) zm.Mat {
    const scfov = zm.sincos(0.5 * fovy);

    std.debug.assert(near > 0.0);
    std.debug.assert(!std.math.approxEqAbs(f32, scfov[0], 0.0, 0.001));
    std.debug.assert(!std.math.approxEqAbs(f32, aspect, 0.0, 0.01));

    const h = scfov[1] / scfov[0];
    const w = h / aspect;
    return .{
        zm.f32x4(w, 0.0, 0.0, 0.0),
        zm.f32x4(0.0, h, 0.0, 0.0),
        zm.f32x4(0.0, 0.0, 0.0, -1.0),
        zm.f32x4(0.0, 0.0, near, 0.0),
    };
}

fn trigger() !void {
    if (@import("builtin").os.tag != .linux) return;

    var dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer dir.close();
    var file = try dir.createFile("trigger", .{ .truncate = true });
    defer file.close();
}

const random_u32_bits: [33][256]u32 = .{
    .{ 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000 },
    .{ 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004, 0x00000004 },
    .{ 0x00100010, 0x00084000, 0x00800002, 0x00800002, 0x00002010, 0x00000220, 0x00000220, 0x00408000, 0x40000400, 0x000000a0, 0x00800002, 0x00002010, 0x00002400, 0x40000400, 0x02000100, 0x00000220, 0x00084000, 0x00800002, 0x00800002, 0x00002010, 0x40000400, 0x40000400, 0x000000a0, 0x00002010, 0x00004002, 0x00018000, 0x00408000, 0x40000400, 0x40000400, 0x40000400, 0x00800004, 0x00800004, 0x00004002, 0x00100010, 0x000000a0, 0x02000100, 0x00002010, 0x00084000, 0x00002010, 0x00002010, 0x00800004, 0x00408000, 0x00084000, 0x00202000, 0x00000082, 0x02000100, 0x00800002, 0x00084000, 0x00018000, 0x00408000, 0x00018000, 0x00002010, 0x00002010, 0x00202000, 0x00002400, 0x00408000, 0x00800004, 0x00202000, 0x00202000, 0x00100010, 0x02000100, 0x00018000, 0x00000082, 0x00408000, 0x00004002, 0x00004002, 0x00202000, 0x00000220, 0x02000100, 0x00800002, 0x00002400, 0x00408000, 0x00000220, 0x00004002, 0x00000220, 0x00100004, 0x00002010, 0x00002400, 0x00100010, 0x40000400, 0x00002010, 0x00018000, 0x00018000, 0x40000400, 0x00408000, 0x00000220, 0x00408000, 0x00000082, 0x02000100, 0x00408000, 0x00100010, 0x00002400, 0x02000100, 0x00004002, 0x00202000, 0x00002400, 0x00408000, 0x02000100, 0x00002400, 0x00202000, 0x00100010, 0x00002400, 0x00004002, 0x00100010, 0x00100004, 0x00084000, 0x00408000, 0x00800004, 0x000000a0, 0x00100010, 0x00004002, 0x00408000, 0x00800002, 0x00100004, 0x00002400, 0x00002010, 0x00800002, 0x00100010, 0x00408000, 0x02000100, 0x00002010, 0x00018000, 0x00000220, 0x00202000, 0x00004002, 0x00002010, 0x00800004, 0x40000400, 0x00084000, 0x00100010, 0x00408000, 0x00202000, 0x40000400, 0x00100004, 0x000000a0, 0x02000100, 0x00100004, 0x000000a0, 0x00002400, 0x00800004, 0x00800002, 0x000000a0, 0x00002010, 0x00084000, 0x02000100, 0x00004002, 0x00084000, 0x00202000, 0x00800004, 0x00000082, 0x00800004, 0x00018000, 0x00100010, 0x00408000, 0x00004002, 0x00084000, 0x00002400, 0x00800004, 0x00100010, 0x00100004, 0x00408000, 0x00018000, 0x00018000, 0x00002400, 0x00018000, 0x00004002, 0x00002010, 0x00000220, 0x40000400, 0x00408000, 0x00002400, 0x00800004, 0x02000100, 0x00000082, 0x00084000, 0x00000082, 0x00800002, 0x00000220, 0x00408000, 0x02000100, 0x02000100, 0x00018000, 0x40000400, 0x00100010, 0x00100004, 0x000000a0, 0x00100004, 0x00800004, 0x00408000, 0x00000220, 0x00800002, 0x00100010, 0x00100010, 0x00084000, 0x00202000, 0x00002400, 0x00800004, 0x00002400, 0x00202000, 0x00800004, 0x00100004, 0x00408000, 0x00018000, 0x00004002, 0x00018000, 0x00000082, 0x00000220, 0x40000400, 0x000000a0, 0x00000082, 0x00202000, 0x00408000, 0x00084000, 0x00800004, 0x00100004, 0x00000220, 0x00000220, 0x00000082, 0x40000400, 0x00002400, 0x00002010, 0x00004002, 0x00018000, 0x00000220, 0x00100010, 0x00800004, 0x00004002, 0x00202000, 0x00800004, 0x000000a0, 0x00004002, 0x00800004, 0x000000a0, 0x00202000, 0x000000a0, 0x000000a0, 0x00800004, 0x00000082, 0x00408000, 0x00000220, 0x00800004, 0x00800002, 0x00000082, 0x00002010, 0x00002400, 0x00000082, 0x00004002, 0x40000400, 0x00084000, 0x00084000, 0x00800002, 0x00800004, 0x00100004, 0x00408000, 0x00408000, 0x40000400 },
    .{ 0x04010001, 0x04020100, 0x04001080, 0x20000088, 0x04800002, 0x08404000, 0x00801001, 0x00080050, 0x01004800, 0x20030000, 0x00140040, 0x00010402, 0x88001000, 0x40001010, 0x01004800, 0x10000240, 0x02800080, 0x00404800, 0x00c00020, 0x00080104, 0x20000820, 0x20000088, 0x20000088, 0x00404010, 0x40400800, 0x20000048, 0x22000020, 0x22000020, 0x01200008, 0x02000088, 0x40001010, 0x00005800, 0x00040006, 0x00048008, 0x0a000002, 0x00800044, 0x40000014, 0x04001080, 0x20408000, 0x50200000, 0x88008000, 0x10000140, 0x40200004, 0x90100000, 0x40001010, 0x04000120, 0x00404001, 0x01000060, 0x02002002, 0x20000820, 0x000080c0, 0x000a0200, 0x02002200, 0x04010001, 0x20000088, 0x00104002, 0x10002008, 0x80100001, 0x00405000, 0x04002100, 0x82000040, 0x02001200, 0x000a0100, 0x00084100, 0x00000224, 0x0000100c, 0x00000700, 0x00000c01, 0x00020440, 0x00108020, 0x82000040, 0x00210020, 0x0000040a, 0x00008408, 0x50200000, 0x00008021, 0x20080010, 0x00048008, 0x08000140, 0x20000088, 0x10008008, 0x04010001, 0x20001400, 0x00000184, 0x90100000, 0x00801001, 0x80400040, 0x00010402, 0x00100410, 0x60800000, 0x02002002, 0x04020100, 0x000400a0, 0x00080104, 0x0000040a, 0x02002200, 0x00404800, 0x04020100, 0x20000088, 0x40000014, 0x00002408, 0x88001000, 0x08480000, 0x00404001, 0x40009000, 0x40000014, 0x90100000, 0x00801001, 0x00022001, 0x31000000, 0x00408008, 0x00100410, 0x40001010, 0x81800000, 0x00404010, 0x04800400, 0x000a0200, 0x00430000, 0x00022020, 0x00008021, 0x40200004, 0x000000a1, 0x00100410, 0x20024000, 0x20001400, 0x00080104, 0x00810020, 0x00000184, 0x00022020, 0x00080104, 0x20001010, 0x08480000, 0x00040006, 0x10400400, 0x00040006, 0x84200000, 0x41000080, 0x00228000, 0x00080060, 0x000000a1, 0x00005800, 0x02002200, 0x00404800, 0x04800400, 0x40000014, 0x04010001, 0x01002100, 0x00810020, 0x0400000c, 0x00010060, 0x00010060, 0x04000120, 0x00048008, 0x40400800, 0x00008402, 0x01210000, 0x20408000, 0x00000150, 0x00300010, 0x00404010, 0x60800000, 0x00080050, 0x00340000, 0x00405000, 0x01005000, 0x80008080, 0x00140040, 0x88001000, 0x04020100, 0x04010001, 0x00000032, 0x01210000, 0x00430000, 0x10008008, 0x00000c01, 0x20001400, 0x01480000, 0x00280002, 0x00080050, 0x000a0100, 0x00008840, 0x02002002, 0x20030000, 0x02100001, 0x00210020, 0x00000700, 0x80500000, 0x000080c0, 0x01002100, 0x00300010, 0x40400800, 0x20408000, 0x01005000, 0x40200040, 0x10100020, 0x00002140, 0x00018008, 0x80100001, 0x00004180, 0x00404800, 0x00430000, 0x00430000, 0x00210020, 0x00022020, 0x02800080, 0x00280002, 0x00010402, 0x00100410, 0x00022020, 0x00405000, 0x02002200, 0x04000120, 0x82000040, 0x04010020, 0x04001080, 0x00000150, 0x02001200, 0x40000014, 0x60800000, 0x08000140, 0x10400400, 0x00000032, 0x81800000, 0x00340000, 0x00010060, 0x00408080, 0x90100000, 0x88008000, 0x20000820, 0x20000820, 0x31000000, 0x88008000, 0x00018008, 0x000a0200, 0x00100410, 0x04a00000, 0x00228000, 0x000a0100, 0x20060000, 0x01004010, 0x08404000, 0x20000048, 0x88001000, 0x04a00000, 0x10000014, 0x20408000, 0x01210000, 0x02002200, 0x80800400, 0x31000000, 0x04000022, 0x01005000, 0x20000088, 0x00002140, 0x42200000, 0x000080c0 },
    .{ 0x00121004, 0x20000a04, 0x10900010, 0x08102100, 0x22002010, 0x8000a080, 0x04000049, 0x09000900, 0x29000800, 0x00201041, 0x20040140, 0x42004400, 0x48000240, 0x40600008, 0x08002081, 0x02284000, 0x02040408, 0x00400242, 0x01010401, 0x09002200, 0x10808004, 0x00400520, 0x00083400, 0x08080084, 0x0c480000, 0x10200088, 0x80210004, 0x001020a0, 0x04004208, 0x00100441, 0x00a10020, 0x08402800, 0x01400044, 0x10010009, 0x22020008, 0x0e000004, 0x04260000, 0x00850100, 0x00009880, 0x40082004, 0x21240000, 0x00030050, 0x13000080, 0x81000801, 0x04808400, 0x80042040, 0x08805000, 0x06020004, 0x020000a2, 0x020c0100, 0x24002008, 0x00840500, 0x001a0100, 0x28000011, 0x08100410, 0x01050800, 0x01120080, 0x32000200, 0x80020500, 0x02024040, 0x12102000, 0x00310040, 0x08000c02, 0x00081102, 0x0004002c, 0x18002800, 0x04021008, 0x00002805, 0x00000a88, 0x80010408, 0x80480008, 0x00800320, 0x00806008, 0x23400000, 0x08010280, 0x00010414, 0x100c0020, 0x50102000, 0x00504008, 0x20800808, 0x0100010c, 0x10400208, 0x20010012, 0x10000221, 0x00844001, 0x88600000, 0x01400003, 0x86000004, 0x1a008000, 0x03100001, 0x20400090, 0x04001801, 0x10009004, 0x81000006, 0x26000040, 0x0210000a, 0x00242001, 0x00604008, 0x48820000, 0x00402240, 0x00100c04, 0x80100300, 0x42900000, 0xc0000210, 0x80010202, 0x00420090, 0x0a201000, 0x00012240, 0x11003000, 0x40002048, 0x01040102, 0x00420410, 0x42104000, 0x00803001, 0x08080018, 0x80040044, 0x0b000080, 0x0a080080, 0x80022020, 0x10504000, 0x43008000, 0x08102008, 0x00a80008, 0x10010018, 0x40a80000, 0x00104030, 0x18500000, 0x00002212, 0x80040900, 0x000108c0, 0x03028000, 0x80c10000, 0x84002002, 0x04040140, 0x80404200, 0x61000100, 0x080400a0, 0x00a09000, 0x02014200, 0xa0200020, 0x90004080, 0x60080800, 0x00104280, 0x80101040, 0x20002120, 0x08000508, 0x20060020, 0x00800822, 0x20028040, 0x21002100, 0x00224080, 0x2c000100, 0x0002c200, 0x40020081, 0x20020021, 0x00044082, 0x02000c02, 0x40042020, 0x01200900, 0x00001848, 0x04400088, 0x20094000, 0x60080002, 0x81080001, 0x002000a8, 0x08086000, 0x00482080, 0x01000380, 0x40001014, 0x0040a080, 0x00828001, 0x14002080, 0x08104100, 0x00081240, 0x01081800, 0x80200104, 0x48400004, 0x00402180, 0x00141040, 0x02601000, 0x08006400, 0x004a1000, 0x04800081, 0x80001600, 0x00020031, 0x4a000040, 0x24080008, 0x0800020c, 0x20001084, 0x12200008, 0x21100080, 0x20001006, 0x20018080, 0x00031002, 0x09002010, 0x00c01080, 0x0a000120, 0x01400180, 0x02201002, 0x40900020, 0x04004810, 0x00404c00, 0x00010094, 0x38000100, 0x00808140, 0x00420440, 0x66000000, 0x00848800, 0x44011000, 0x08208001, 0x001000c4, 0x18040010, 0x04202100, 0x40000881, 0x10142000, 0x04402080, 0x01000680, 0x80808080, 0x42000030, 0x88008008, 0x84010001, 0x04202010, 0x0004a200, 0x00042042, 0xc0020080, 0x00a40040, 0x88002100, 0x50000009, 0x81001800, 0x03084000, 0x00208022, 0x00204082, 0x40010402, 0x48020400, 0x10002a00, 0x09000440, 0x44000410, 0x01204001, 0x40401040, 0x10401040, 0x44090000, 0x40040280, 0x00404600, 0x19100000, 0x08006010, 0x08008500, 0x10210100, 0x80410002, 0x040a0400, 0x0a040020, 0x20040012, 0x0002d000, 0x00022108, 0x10000061, 0x02800108, 0x00010442 },
    .{ 0x09801400, 0x00038300, 0x94000050, 0x01080700, 0x30210008, 0x02214001, 0x50800300, 0x04128010, 0x00045404, 0x180000b0, 0x4c808000, 0x20831000, 0x01108a00, 0x08208408, 0x40800029, 0x0a100802, 0x02010068, 0x00e20004, 0x40023002, 0x08000262, 0x0c004030, 0x41101400, 0x84420040, 0x48040a00, 0x48002440, 0x60440010, 0x00806804, 0x40400508, 0x00228180, 0x18804200, 0x04401005, 0x00140242, 0x02808050, 0x04600108, 0x28200012, 0x82020108, 0x40481400, 0x80012022, 0x0c088800, 0x00888808, 0x84040011, 0x300a8000, 0x04220050, 0x08182002, 0x12009800, 0x80864000, 0x020c0900, 0x82018100, 0xc1004100, 0x008e8000, 0x00300094, 0x84002005, 0x08180440, 0x15100008, 0x0084002a, 0x06040280, 0x01418200, 0x28802020, 0x50001082, 0x81900100, 0x002c4080, 0x48002009, 0x04408202, 0x10001058, 0x0c840040, 0x28810020, 0x40122400, 0x00101414, 0x00c08402, 0x200020d0, 0x00a0c800, 0x00411820, 0x02000603, 0x08011003, 0x00062011, 0x0181c000, 0x02030820, 0x02820060, 0x00003228, 0x00080826, 0x41004208, 0x2800a800, 0x00308840, 0x0020021c, 0x42c00080, 0x0022010c, 0x20444800, 0x500001c0, 0x05640000, 0x02801440, 0x30000508, 0x20050014, 0x80428080, 0x20801028, 0x12001011, 0x004aa000, 0x0a00001c, 0x43000088, 0x00080146, 0x05a00020, 0x400c0024, 0x00900888, 0x1210c000, 0x00090d00, 0x02080190, 0x10200340, 0x01080c10, 0x04080260, 0x00200624, 0x22000812, 0x01700200, 0x21000442, 0x04304800, 0x0200010e, 0x80200222, 0xc8000408, 0x40013020, 0x02018011, 0x00250401, 0x08004a02, 0x51040008, 0x40124800, 0x00608820, 0xc0880200, 0xc0004014, 0xc0181000, 0x04020089, 0x09848000, 0x00088034, 0x00140182, 0x41101080, 0x20140480, 0x10008c20, 0x20002144, 0x1200002c, 0x04101060, 0x10027000, 0xc4000003, 0x30202004, 0x62005000, 0x00480640, 0x48012020, 0x00024064, 0x01900300, 0x40000298, 0x30200804, 0x1000e010, 0x01202108, 0x03204800, 0x18401080, 0x20000145, 0x401000a1, 0xc0400802, 0x44010204, 0x60002801, 0x20000053, 0x04102044, 0x08042810, 0x90080060, 0x01060201, 0xc1008001, 0x03028400, 0x60014080, 0x003a0010, 0x02208880, 0x20004830, 0x00008889, 0x02580004, 0x24000019, 0x00811180, 0x48202100, 0x21020280, 0x40800901, 0x010100a1, 0x40200122, 0x080a0204, 0x00103402, 0x0821000a, 0x63008000, 0x80008c40, 0x00030881, 0x42210100, 0x08410006, 0x00100911, 0x02142001, 0x00081092, 0x02080181, 0x84041010, 0xa0020840, 0xc8400010, 0x10005900, 0x48011001, 0x20090240, 0x200c2080, 0xc0201002, 0x24800480, 0x00208504, 0x000282a0, 0x00441050, 0x40050402, 0x08092001, 0x1c810000, 0x52000140, 0x20101202, 0x208400a0, 0x08088021, 0x04820101, 0x0a280400, 0x14200801, 0xa4404000, 0x00a0000b, 0x50101001, 0x30500008, 0x01422004, 0x10024240, 0x60200102, 0x02900102, 0x00228042, 0x30090080, 0x00241480, 0x200c4100, 0x41000182, 0x01886000, 0x28024001, 0x022040a0, 0x08811200, 0x40c40800, 0x12002202, 0x01000491, 0x801a4000, 0x04000903, 0x26108000, 0x12001820, 0x40808804, 0x22802008, 0x22040003, 0x00004c18, 0x0c120004, 0x10454000, 0x01025002, 0x00042830, 0xe0000088, 0x10000095, 0x04042048, 0x18200840, 0x28042800, 0x0c405000, 0x0044000b, 0x24800088, 0x00250140, 0x72000080, 0x01009c00, 0x02082048, 0x20300014, 0x000a100a, 0x08818400 },
    .{ 0x02182201, 0x42182020, 0x40510140, 0x02120106, 0x00088a30, 0x8a058000, 0x028080b0, 0x00009b10, 0xc0800421, 0x49018020, 0x18240402, 0x0000807c, 0x02089044, 0x00c08111, 0x44881001, 0x88009408, 0x40008152, 0x02205090, 0x124e0000, 0x00863100, 0x008d0401, 0x004e00a0, 0x20810860, 0x44091002, 0xc4004600, 0x0a140280, 0x01c20900, 0xd0006200, 0x000c8d00, 0xa1142000, 0x0002e408, 0x01123200, 0x2000a422, 0x18240101, 0x0840c022, 0x06140880, 0x34800840, 0x10040312, 0x60024022, 0x82404140, 0x200408a4, 0x81406002, 0x08001903, 0x0140a500, 0x20034220, 0x0101a208, 0x01540021, 0x28a02001, 0x24108210, 0x00840d04, 0x50204011, 0x020a2401, 0x48c80080, 0x100004b8, 0x04290300, 0x200106c0, 0x880120c0, 0x0a04c004, 0x19002011, 0x60220090, 0x02091006, 0x01004642, 0x90800064, 0x80410248, 0x09500104, 0x84005081, 0x01032404, 0x04544080, 0x04910402, 0x44284040, 0x06020188, 0x0020a640, 0x08810803, 0x88002c10, 0x00055011, 0x08414018, 0x20101602, 0x00a88480, 0x70050004, 0x40019500, 0x03830004, 0x84040128, 0x14001c04, 0x02420508, 0x05010230, 0x024021c0, 0xa0122100, 0x58016000, 0x38042800, 0x68000601, 0x82808408, 0x2090800c, 0x0001808d, 0x40089011, 0x041040a4, 0x50014018, 0x11501400, 0x16010048, 0x20400960, 0x0d002042, 0x090c0120, 0x404c8020, 0x00040e50, 0x40060128, 0x20040249, 0x008841c0, 0x02016210, 0x31282000, 0x06054008, 0x12004203, 0x034004c0, 0x04160041, 0x40884810, 0x3000204c, 0x2220a001, 0x00094510, 0x04804301, 0x00560006, 0x0400a488, 0x0e110200, 0x58020048, 0x82090060, 0x41100c40, 0x98000188, 0x01a06800, 0x4a208080, 0x8240040c, 0x0000310e, 0x85000023, 0x04211028, 0x40122180, 0x50809100, 0x19000142, 0x0a808500, 0x31082020, 0x81001301, 0x81085200, 0x12000b80, 0x01864080, 0x09004422, 0x28024041, 0x20001462, 0x90004086, 0x90120802, 0x04012c20, 0x04501021, 0x04640840, 0x0090440a, 0x1a00004c, 0x00440c30, 0x22024840, 0x801000b2, 0x18900840, 0x20300803, 0x11006104, 0x01800454, 0x04414c00, 0x01400234, 0x08109201, 0xa0900024, 0x08483100, 0x13001900, 0x85004009, 0x00990408, 0x20a4000a, 0x10402442, 0x22053000, 0x8000203c, 0x40010c41, 0x01220620, 0x08014032, 0x02881084, 0x16400022, 0x12024060, 0xd2000801, 0x98206000, 0x04880031, 0x46908000, 0x42440880, 0x50000348, 0x1c00a004, 0x15028004, 0x02082610, 0x08410124, 0x8a108002, 0x24100034, 0x18820088, 0x16400280, 0x44024018, 0x15001208, 0x0005b040, 0x1c000211, 0x222a0100, 0x29000806, 0x46022002, 0x21109008, 0x20000dc0, 0x022c2008, 0x04817000, 0x80008072, 0x01030310, 0x18814100, 0xa2400022, 0x111020c0, 0x000c008d, 0x04826008, 0x3000008d, 0x20c01201, 0x8808008a, 0x12031010, 0x10380801, 0x10c01c00, 0x17100200, 0x51101100, 0x2510c000, 0x300a0104, 0x50090440, 0x88010610, 0x804c1020, 0x49440080, 0x31004600, 0xc0014108, 0x12808012, 0x1c010110, 0x0440140a, 0x40014218, 0x10240430, 0x01c0a800, 0x0020c409, 0x22020062, 0x001a3800, 0x90010444, 0x1900020c, 0xc20a0001, 0x50200580, 0x40448410, 0x02088112, 0x02048809, 0x81045100, 0x08038280, 0xa0002301, 0x8c420100, 0x00860083, 0x00210123, 0x81c08010, 0x40244404, 0xb0105000, 0x20284810, 0x01188210, 0x40025a00, 0x48800980, 0x08151008, 0x10014288, 0x800c0824, 0x30090408, 0x002040ac },
    .{ 0x1a441100, 0x4426c000, 0x44021089, 0x08442142, 0x0013402a, 0x8244c800, 0xe2040801, 0x07214040, 0x23042808, 0x90a42008, 0x09012940, 0x10041816, 0x2025e000, 0x0a410430, 0x0204809a, 0x40b88008, 0x1a212100, 0x810a8009, 0x20183006, 0x44151008, 0x0034c028, 0x80526400, 0x6810c400, 0x42a04280, 0x0a1420a0, 0x0ac00850, 0x20000ca6, 0x00289421, 0x6020a401, 0x06904022, 0xa0022700, 0x04007450, 0x108c1022, 0x02808c0c, 0x826a0800, 0x0000d44a, 0x208010ac, 0x8006002b, 0x00278401, 0x04848034, 0x22181c00, 0xa0420441, 0x28001c30, 0x3008800d, 0x0210a109, 0x89040128, 0x00106c24, 0x0380a180, 0x8100c00b, 0x44826080, 0x300200a6, 0x280d8010, 0x080c1070, 0x2c050880, 0x08844604, 0x04046c40, 0x40029068, 0x084c2042, 0x0122028c, 0x00584029, 0x04903804, 0x00528406, 0x40028660, 0x8a10008a, 0x095c0010, 0x0200c434, 0x0c208a02, 0x44011013, 0x04426102, 0x28218410, 0x0000ad05, 0x09214110, 0x4c418080, 0x92940020, 0x002121c8, 0x0410421a, 0x28880488, 0x05500888, 0x20c98200, 0x54040007, 0xc2080284, 0x00163012, 0x00859404, 0x2102110a, 0x42406420, 0x40554100, 0x00d14c00, 0x830c0900, 0x20024254, 0x060c0a10, 0x42400231, 0x48960100, 0x10118083, 0x31440024, 0x400844a8, 0x8052c001, 0xc1820404, 0x02520034, 0x01102720, 0x8a08c400, 0x8900810a, 0x10218228, 0x31408500, 0x1c009208, 0x38100460, 0x10060305, 0x054a2800, 0x05070300, 0x180a0304, 0x14220411, 0x008060cc, 0x40205221, 0x09802809, 0x52009009, 0x44701004, 0x43240a00, 0x66880200, 0x30088881, 0x6c144000, 0x81321080, 0x43800902, 0x48541004, 0x84006086, 0x80700182, 0x0a408070, 0x0a1020a1, 0x20009306, 0x81016440, 0x08144504, 0xcc004402, 0x0220b101, 0xe0200482, 0x08007380, 0xd0890002, 0x20a8c800, 0x21240034, 0x51000c12, 0x8204c021, 0x05444208, 0x61c08100, 0x00150b40, 0x18086a00, 0x008c4e00, 0xc5140040, 0x16014021, 0x18280026, 0x20318404, 0xa2808088, 0x0d800288, 0x001401b2, 0x0c008146, 0x51800211, 0x20410249, 0xa8010023, 0x1a014014, 0x1018a808, 0x04c40025, 0x44100b20, 0x28609100, 0x001540c8, 0x01261210, 0xc0881048, 0x08502430, 0x08083112, 0x0100e092, 0x0a016088, 0x04100a8a, 0x040a2094, 0x92a01100, 0x00416061, 0x002a3014, 0x16005041, 0x45004380, 0x21240501, 0x44361000, 0x08404ca0, 0x0043420c, 0x42180015, 0x20840807, 0x04242484, 0x02280123, 0x440820c4, 0x1080d009, 0x02000a2e, 0x04200e03, 0x08241046, 0xd8000848, 0x45a04008, 0x5000c580, 0x300c8006, 0x200c3808, 0x0008212b, 0x84002168, 0x50186040, 0x02440154, 0x082140e0, 0x24601802, 0x41802e00, 0x60005031, 0x003201a2, 0x00106852, 0x48002d20, 0x20518880, 0x62484100, 0xe0028220, 0x07006900, 0xc2220009, 0x04052085, 0xa2c40004, 0x81d00048, 0x20423210, 0x000c5068, 0x48440070, 0x414002c1, 0x1d008440, 0x41584008, 0xc0080849, 0xc0082890, 0x802c0540, 0x181b0010, 0x38342000, 0x44c0c001, 0x11114005, 0x2400c482, 0x440c0190, 0xc4850100, 0x2c242004, 0x00221834, 0x01a16004, 0x21024540, 0x42c0100a, 0x08c0e080, 0x34004142, 0x001e8084, 0x80013016, 0x50231001, 0x004160c4, 0x9002110c, 0x86088044, 0xa0200621, 0x21013060, 0x10412a08, 0x42184880, 0x0009a122, 0x01429440, 0x1202a014, 0x70200841, 0x05004922, 0x09804504, 0x2004e201, 0x002c0582, 0x44221044, 0x19044220, 0x8c020806, 0x00020ee0, 0x08212109 },
    .{ 0x44c50120, 0x1721000a, 0x13110214, 0x22063810, 0x1a80c024, 0x59900003, 0x020912a1, 0xa04900c4, 0x208801f0, 0xd8210300, 0xd1581000, 0x2d110204, 0x0142830a, 0x82105620, 0x10414826, 0x701084a0, 0xcc4000a2, 0x8415040c, 0x30052418, 0x20402562, 0xe1004484, 0x849c0808, 0x10c49900, 0x6205001a, 0x016002aa, 0x02c04053, 0x2c8440a0, 0x34812005, 0x09c00894, 0x4b040510, 0xe8848040, 0x33408009, 0x08504b04, 0x04095424, 0xcb08000a, 0x498404a0, 0x28650210, 0x4484a042, 0x440a24a0, 0x4030422a, 0x40248883, 0x708a4001, 0x421c8108, 0x164d0008, 0x80544c01, 0x10231502, 0x50494024, 0x18c0022a, 0x60102138, 0x0844402b, 0x39800290, 0x4119800a, 0x8060204e, 0x07800780, 0x2c1a000a, 0x88580405, 0x084d4210, 0x28016340, 0x45008312, 0x04a30181, 0x1110403c, 0x033d2000, 0x600298c0, 0xa000031d, 0x028c2881, 0x84036009, 0x41110622, 0xc22c0808, 0x100d8818, 0x00918225, 0x80518083, 0x28208528, 0xa4012a80, 0x1c244410, 0x40b08428, 0x18144114, 0x4a012806, 0x10171402, 0x89300124, 0x00964890, 0x203a6400, 0xc44a2080, 0x70360002, 0x0a02181c, 0x80604413, 0x00c41a09, 0x4aa001a0, 0x03cc000a, 0x2009a209, 0xa1490110, 0x80c01d02, 0x30148805, 0x80c30222, 0x90050858, 0x23400d40, 0x280800f2, 0x60524048, 0x0600b80c, 0x1c802414, 0x84120d10, 0x2a0805a0, 0x01441027, 0x8c02082a, 0x43650020, 0x80705140, 0x4841a420, 0x8240092a, 0x80119902, 0x46018a01, 0x0140a885, 0x0222a4c0, 0xb08a6000, 0x12a001a4, 0x005c0134, 0xb0050680, 0x80818185, 0x8010d0c1, 0x70600032, 0x01401b14, 0x4c04c808, 0x0310418a, 0xb4049004, 0x94116100, 0x84482c04, 0x4404018b, 0x2ec00110, 0x504008d4, 0x46018124, 0x0094046a, 0x42640184, 0x8b114002, 0x4d000541, 0x43809014, 0x42100562, 0x110e2006, 0x1400304e, 0x526004c0, 0x582202c0, 0x40194380, 0x22409484, 0x28314110, 0x042a4811, 0x42900126, 0x9040a086, 0x2b00e002, 0xc12100a4, 0x08446c04, 0x804a0c82, 0x00f008d0, 0x0562b000, 0xc80058a0, 0x10806524, 0x0819b400, 0x25221408, 0x5c060420, 0xc0004836, 0x28038580, 0x94890600, 0x60892300, 0xa0022298, 0x60544060, 0x3a0a8002, 0x41620484, 0x01c2c140, 0x80366200, 0x40846244, 0x240c0306, 0x1880841a, 0x8a130006, 0x2e221020, 0x11ad0800, 0x20023059, 0x00201ad1, 0x4000f205, 0x085420b0, 0x206012c1, 0x62100740, 0x31008560, 0x5041a404, 0x13124600, 0x18a08860, 0x29009013, 0x800cad00, 0xe0048308, 0x01108323, 0x6c380200, 0x68148300, 0x68043808, 0xc1010642, 0x0c1aa002, 0x4400bc20, 0x1340401c, 0xb4048880, 0x20520930, 0x18084056, 0x00438341, 0x5181a400, 0x6c4a0200, 0x7002001e, 0x14020a4a, 0x00892944, 0x34d01100, 0x82530140, 0x402506c0, 0x20185112, 0x30001ad0, 0x00d44812, 0x06941081, 0x02924940, 0x74121080, 0x1c4a0440, 0x28640406, 0x424c0160, 0xda000112, 0x10381805, 0x82920015, 0x013800a3, 0x1618c100, 0x30881182, 0x2202809c, 0x1820224c, 0x01885160, 0x0c2100f0, 0x66400901, 0x03821205, 0x3030a840, 0x86500510, 0x06c4040a, 0x1e0a0480, 0x2690c800, 0x00014aa6, 0x0112a051, 0x62414104, 0x31008590, 0x15412021, 0xb8020130, 0x4220e210, 0x00309858, 0x86464400, 0x41262240, 0xd6260000, 0xc20a8402, 0x88402829, 0x0aa88104, 0x10885380, 0x29c08108, 0x490300e0, 0x4a803280, 0x6000a823, 0x00342225, 0x4404242a, 0x94200852, 0x0480eb00, 0x882088c1, 0x64841081, 0x50c50081 },
    .{ 0x02c1052a, 0x60443904, 0x1201e128, 0x09a10684, 0x201e1106, 0x20712130, 0x08246c50, 0xa024604a, 0x3a050418, 0x11120613, 0xb4021230, 0xb20801a8, 0x11621241, 0x041c1941, 0x061c8824, 0x73030041, 0x44056105, 0x8248d006, 0x04b121c0, 0x1844c601, 0x00059a8c, 0x00c144aa, 0x14e82003, 0x84570048, 0x04c1c442, 0x13280581, 0x4b014850, 0x4ca40242, 0x22ac9400, 0xa4185280, 0x02312216, 0x33162100, 0x2222c00d, 0x84213482, 0x40303e08, 0x01811d0a, 0x20012f50, 0xa2a64008, 0xcc00d060, 0x111a028c, 0xac841088, 0xa1880816, 0x09508984, 0xa20814c8, 0x3300110d, 0x54c02890, 0x8920a884, 0x03341007, 0x12824234, 0x11049426, 0x142b0818, 0x04c6840c, 0x80052ac2, 0x8b120448, 0x15026414, 0xc09a5400, 0x68444038, 0x27802089, 0x480fc001, 0x82680131, 0x018d0834, 0xb1980022, 0x60d080c4, 0x03831320, 0x710b4020, 0x000472b1, 0x40fc0401, 0xac444022, 0x8842c442, 0x57442004, 0x47003130, 0x3502408a, 0x8070021d, 0x2d074010, 0x84010b4c, 0x200a168a, 0x0f428060, 0x03150138, 0x10250a4a, 0x41600664, 0x93880250, 0x0e128c08, 0x27c04021, 0x40254216, 0x18081923, 0x08055231, 0x81854182, 0x20887290, 0x4010dd01, 0x25002386, 0x824284a1, 0x08464918, 0x24064446, 0x000132da, 0x002a8742, 0x05315003, 0x700c0286, 0x040051ea, 0x000d1073, 0x8b4a0802, 0x46090c24, 0x18703404, 0x01841721, 0x88840c0d, 0x052d0206, 0x70462082, 0x7a210014, 0x10908839, 0x50432406, 0x54c21081, 0xa0b0880a, 0x040412ab, 0x204c0728, 0x262d1008, 0x48102a51, 0x51c8a008, 0x0c5900d0, 0x80908b11, 0xc8146220, 0x49800b21, 0xa0a00e11, 0x1445120a, 0x20a3e800, 0x2b020047, 0x40863038, 0x82023318, 0x48c02419, 0x88848a41, 0x424a204a, 0x50003f08, 0x42d28140, 0x50083087, 0x14321029, 0x605840a8, 0x191029a0, 0x71c00085, 0x022d1016, 0x8180482e, 0x40ac8841, 0x782200a2, 0x01701254, 0x28a2011c, 0x62184052, 0x21238094, 0x1a0108d8, 0x2e204602, 0x0a3a0c20, 0x30211129, 0x90103530, 0x80064629, 0x8218221a, 0x00998491, 0x0c22e006, 0x03b90401, 0x08858941, 0x10220d34, 0x96207010, 0x96480540, 0x820d0c60, 0x005051d1, 0x04a48d02, 0x40c1202d, 0x184028ac, 0x021e2228, 0x18b42042, 0x1744a800, 0x9b040205, 0x04207950, 0x08301459, 0x14488145, 0x40622b20, 0x070091a1, 0xd0060981, 0x04089193, 0x10602392, 0x38449808, 0x19120426, 0x8030098d, 0x408a0c31, 0x50440259, 0x3c015028, 0x114106c2, 0x4183060c, 0x4d0030a8, 0x68c0009a, 0x20805ca1, 0x0260825a, 0x84300592, 0x80523105, 0x02560544, 0x49114403, 0xca4440a0, 0x08252922, 0x004dd480, 0x480a7440, 0x10201f06, 0x14030c26, 0x22135050, 0x86419404, 0x55042016, 0x00a4ed00, 0x0198c085, 0x050d0419, 0x00c854c8, 0x3040b40c, 0x085801c6, 0x24084526, 0x71168002, 0x01285511, 0x47210034, 0xa5204504, 0x080e4216, 0x06045905, 0x800524a6, 0xa2490842, 0x148072c0, 0x09529408, 0x1c108344, 0x28146142, 0x0222a158, 0xc204c029, 0x0172011c, 0x080508ea, 0x012a60a1, 0x81493210, 0x404404c7, 0x1284d401, 0x13410306, 0x304c0107, 0x18264288, 0x41192520, 0x424e4022, 0x6360d000, 0x024c3310, 0x1e081121, 0xd4120e00, 0xac063400, 0xa0284382, 0x81a018e0, 0x11041cc1, 0x05113103, 0x1c538100, 0x52201834, 0x00b15122, 0xc0112521, 0x9a005228, 0x0e0c080e, 0x011a0c94, 0x584440c2, 0x0520e844, 0x26203441, 0x4d1080e0, 0x34491820, 0x0804b087, 0x26011268, 0x8034c02c },
    .{ 0x26024a91, 0x41a2c0c2, 0xb2000572, 0x62026622, 0x8804ac07, 0x81a44921, 0x2174011c, 0x0066a0c3, 0x98d0003a, 0x0f01044b, 0x2c21ad00, 0x048226e4, 0x2c032311, 0x0a8019a3, 0x2496c024, 0x06a240b8, 0x03923114, 0xc301d108, 0xc9810b40, 0xa0806a16, 0x82a1840e, 0x061e1052, 0x012199a2, 0x38441312, 0xc3888023, 0x201d8981, 0x504008f3, 0x093c4302, 0x8e0d8240, 0x12748c10, 0x90251681, 0x8042e207, 0x03f80188, 0x06e60422, 0xb34a4100, 0x13409492, 0x014134b2, 0x2a082394, 0xa6844031, 0x48302cc1, 0x05180c33, 0x2400caa9, 0x354404c4, 0x4a88b011, 0x63240528, 0x2c2a8118, 0x800335e0, 0x414c3064, 0x00260e69, 0x891a8d00, 0xe0890846, 0x820d8055, 0x94402c83, 0x221485e0, 0x70181312, 0x43c12842, 0x60c52211, 0x2a0a6e00, 0x85c61120, 0x9604014d, 0x84200d63, 0x82a50131, 0x41825870, 0x0d444055, 0x91a00195, 0x0d340261, 0x320c820e, 0x81828a15, 0x6d402510, 0x9040d445, 0x45028869, 0x81283305, 0x58887840, 0x49261620, 0x180314d8, 0x2108d485, 0x0a682446, 0x60c41426, 0x027e80c0, 0xf8424280, 0x01148f18, 0x68260642, 0xb809042a, 0xc21c8214, 0x14454138, 0x602014b5, 0x66110306, 0xc0a4205a, 0x6ac80884, 0x071a40c8, 0xa82a2444, 0x018d1232, 0x88d81144, 0x6032012e, 0x8510c3a0, 0x8d141068, 0x0400e7a8, 0x30308d22, 0x33000dc8, 0x88935014, 0x0d50448a, 0x3610006b, 0x16054a0c, 0x8b0b8810, 0x685428c0, 0x445a2182, 0x82616608, 0x22129246, 0x5a580288, 0x1108305e, 0x28364184, 0x5a1a2410, 0x0aa70c10, 0x19035821, 0x481c70c0, 0x82e85500, 0x29a6080a, 0x45030cd0, 0xc1a88034, 0x354d0804, 0x4800b30b, 0x8190f802, 0x840420be, 0x08a8d242, 0xa2234049, 0x800133ac, 0x020b2934, 0x1a0e014c, 0xd00d8184, 0x0140255e, 0x10aa04ca, 0x641828e0, 0x145a2450, 0x0a14a898, 0xd80000fc, 0xb280501c, 0x38514206, 0x20e02545, 0x84c38904, 0x02024ed2, 0x0f804033, 0xe10203d0, 0xd00ad204, 0x03cc5401, 0x18302165, 0x042cc311, 0x90680f02, 0x084bd204, 0x0aa08265, 0x182641d0, 0x2980e103, 0x1ac12824, 0x09ad2810, 0x80825b0c, 0x11519340, 0xc210604b, 0x0565204c, 0x04286278, 0x65101291, 0x88a74801, 0x8340a891, 0x6d240844, 0xe0161092, 0x1cb80244, 0x82a22590, 0x011342f0, 0x88702449, 0x79480184, 0x14a2a228, 0x0d8110e1, 0x40a0d129, 0x72808324, 0x06012a71, 0xa010b911, 0x0b087144, 0x00a93126, 0x12703c10, 0xd00e8c02, 0x8994050a, 0x305420f0, 0x2b19200a, 0x4071402b, 0x22318198, 0x1d015380, 0x818c40a6, 0x1140094f, 0x618041c3, 0x318c5420, 0xe000b511, 0x183b3200, 0x2a064a12, 0x8c86600c, 0x218c2426, 0x61209423, 0xc9054841, 0x08409e0d, 0x0c06064b, 0x60855403, 0x70621302, 0x23100c2d, 0x73060284, 0x86a08503, 0x25940710, 0xc0906a21, 0x09562025, 0x2d2610a0, 0xa1518160, 0x1005a10f, 0x2145803a, 0x10c22c0b, 0x3250090b, 0x45a63080, 0x40ea801c, 0x5a103103, 0x404285d2, 0x01831a23, 0x9540508c, 0x2748100d, 0x80862cc2, 0xd18c0610, 0x1e328009, 0x84cc1824, 0x4181c858, 0x40c011b5, 0xb4105481, 0x08a1a423, 0x0809d40e, 0x312201c6, 0x04932e02, 0x96f84000, 0x00064ad3, 0x11615640, 0x028a8856, 0x180d4c88, 0x700b3003, 0x31448541, 0x1d70a008, 0x1a30284a, 0x0150b119, 0x0031d0b1, 0x0f824124, 0xc6888282, 0x1500d584, 0x30148b22, 0x60a4405a, 0x43046903, 0x1a360025, 0x2018b4a1, 0x4a7a0880, 0x66a09021, 0x8869011c, 0x9000d554, 0x199d0408, 0x0a120b38, 0x12186c44, 0x85003991 },
    .{ 0x55951044, 0xb2b12204, 0x3a2b4480, 0xa9150914, 0x65d01428, 0x71062a09, 0x02563618, 0xcd015083, 0x4a0d4289, 0x26c2a980, 0x98800b4d, 0x8bc28244, 0x471486a0, 0x07341b08, 0x92d40858, 0x70300a72, 0x00cc352a, 0xc6102057, 0xe9288212, 0x29055550, 0x0f40151a, 0x401c3166, 0x84064535, 0x8a9b4120, 0x064d201b, 0x16591043, 0xb5610282, 0x3a941064, 0x5646084a, 0x283c1219, 0xc3721104, 0x56623402, 0x155880a5, 0x601a5cc0, 0x03239c48, 0xa8550324, 0x1266680c, 0x01419af0, 0x433228d0, 0xc8c02d14, 0x20177241, 0x15362144, 0x064426b4, 0x0250352d, 0x50904743, 0x5aa0201d, 0x939060d0, 0x75d05800, 0x2b219848, 0x80c62a92, 0x9028c05e, 0xdc093208, 0x54b46500, 0x83056541, 0x3225800f, 0x720a8223, 0x00e6285a, 0x4a413258, 0x89690289, 0x10c8bc30, 0xdb02240c, 0x8860e950, 0x24036788, 0x3019894c, 0x21326891, 0x00ef4450, 0x4c202955, 0x2ee12009, 0xb0147112, 0x192921a1, 0x89505a50, 0x07606854, 0xd0401a71, 0x404629e4, 0x0d790118, 0x22aa043c, 0xc23890c2, 0x95838444, 0x4811a319, 0x36261013, 0xb01a0aa8, 0x0838328e, 0x68aac140, 0x1d1c300c, 0x44260c1d, 0x600588b9, 0x30e98488, 0xa1c0e842, 0x020c53aa, 0x8d8b2140, 0x0af3a002, 0xcb46a002, 0x52664901, 0x2710069c, 0xb241088d, 0x018bd405, 0x32462506, 0xc10c4f40, 0xc3412708, 0x53402d84, 0x3a706140, 0x88b90072, 0x0220663e, 0xe5134220, 0x1ba04a60, 0x0d051750, 0x10c5e830, 0x422a12e1, 0xd03206a4, 0x1a02ba21, 0x83a49812, 0x16442aa2, 0xca3084d0, 0x9002d14d, 0x6c0c224a, 0x8b020726, 0xe0038668, 0x050a918e, 0x20f03e20, 0x164fc100, 0x06956221, 0xee34c000, 0x632e4202, 0x0242b989, 0x1c0f4540, 0x49320370, 0xc02c182e, 0x58190549, 0x488780cc, 0x1472c803, 0x2c2a5244, 0x82a14e90, 0xee408580, 0x8a6b0805, 0x54254982, 0xc16e8042, 0x2a12f401, 0x4e161205, 0xd5a2200c, 0xc3d20818, 0xb05140d1, 0x62195242, 0x06c46892, 0xcc503121, 0x02b29831, 0x44a194c8, 0x8429b920, 0x22391618, 0x4204e561, 0x14a86216, 0x412fa022, 0x4318c219, 0x18205ee0, 0x43b01123, 0x198d2422, 0x4cf01805, 0x0ca8a530, 0x2530cb02, 0x144434ac, 0x0212ea29, 0x16528816, 0x2644841b, 0x27070c18, 0x0c90c18b, 0x22163072, 0x8886a321, 0x588820f1, 0x4948c509, 0x5a495012, 0x4e440456, 0x0204dcac, 0x0533112c, 0x44a92047, 0x393050c4, 0x617029c0, 0x51104273, 0x61654842, 0x12d6040d, 0xb90061b0, 0x900c8a1e, 0x85076841, 0x9604303c, 0x20f105a8, 0x134c61c0, 0xca2a0530, 0x02241b2e, 0x59e04114, 0x084d0d4c, 0x189ec024, 0xc28a08b1, 0x39206486, 0x004a257a, 0xe4072015, 0x21a954c0, 0x88348855, 0x84680c3c, 0x35c44450, 0x450a8493, 0xb43a1880, 0xe8c101a2, 0x065454b0, 0x4a3c2070, 0x4ac00e26, 0x275028d0, 0x4567001c, 0x2a10a28d, 0x89436442, 0x2100fa0b, 0x8e231441, 0x007dd041, 0xcd898210, 0x181a441d, 0x56349022, 0x25874083, 0x600a233c, 0x9201cd84, 0x12104c3b, 0x238e1211, 0x5581b030, 0x41a322a4, 0x008e1e70, 0x37481054, 0x818a4945, 0x600cd988, 0x418442ae, 0x862981e0, 0x50e082cc, 0x8e985030, 0x828ea442, 0x2a8068a3, 0x041443ea, 0x0491b581, 0x901446a6, 0x693cc008, 0x81606f02, 0x52430643, 0xed220228, 0xa099c228, 0x3105e2a0, 0x481309b2, 0xb524c110, 0x09014753, 0x446e100b, 0x835a8608, 0x92106287, 0x26995108, 0xb830e0c0, 0x98601a98, 0x841da206, 0xc4c68241, 0x2207822b, 0x0a430875, 0x622898e0, 0xa2b18083, 0x4aa13121, 0x244a6017 },
    .{ 0x0164586e, 0x4d920433, 0x1c08951d, 0xc1e3042a, 0x24461959, 0xc8c170a2, 0xc12a7508, 0x382ae700, 0xe809c4c2, 0x71c04455, 0x25340179, 0x02d4cd90, 0x48a51c2c, 0x59a34601, 0xd05b4a04, 0x36028473, 0x204038f7, 0x1898a325, 0x15540cd4, 0xd2070a23, 0x0027db14, 0xaa361188, 0x52c4189a, 0x052a4785, 0x20d51ba0, 0xb2c95014, 0x408f3c48, 0x008f6a4a, 0xc890a4c3, 0x61042f8c, 0x67463102, 0x9904849e, 0x18949658, 0xd2b61101, 0x4493819c, 0x721d4250, 0x46030f1a, 0x102ec748, 0x236c184a, 0x60310937, 0x03bf200c, 0x45d03819, 0x83154315, 0x6021c6e4, 0x80a96163, 0x2e1002f3, 0x1ac02d38, 0x83a0449d, 0x02c932aa, 0x0683055e, 0x3465ac02, 0x2479a320, 0x30a274c1, 0x18a29934, 0x4c525b01, 0x0a92d258, 0x4b8c2503, 0x7a013550, 0x01b7c184, 0x4a00f4c6, 0x874941b0, 0x64685603, 0x860272c9, 0x6ea42190, 0x8dd4a00c, 0x061629d1, 0xe0b2284c, 0x0ab6c481, 0x80192c9b, 0x3548508b, 0x3f1a2009, 0xf20c1851, 0x569a30c0, 0x57426844, 0x470814e9, 0x240cb370, 0xc0586cc1, 0x047c83c1, 0x9d440b81, 0x24c00dc7, 0x0570b245, 0xa34058c9, 0x53254614, 0xa630013d, 0x44b808bc, 0x49b2a118, 0x1d4108dc, 0x216b02b1, 0x132ec241, 0xa41c14c5, 0x64313924, 0x34ac3019, 0x4e49c190, 0x7d821830, 0xa5029516, 0x1e1885d0, 0x88a8628b, 0x8a3d04d0, 0x86639061, 0x67040f03, 0x2aa07542, 0xca4d1211, 0x9a547210, 0x740d4512, 0x2b583a01, 0x25ab4206, 0x27324096, 0x68128b49, 0x3a232521, 0xa328a819, 0x0ec42495, 0x150f1149, 0x12d085d4, 0x37c02861, 0x5150bd20, 0x980ab0a3, 0x02780b93, 0x09d3300b, 0x38821bc1, 0x2881b166, 0xb24c0aa1, 0xc8214f42, 0x0bf44310, 0x9e125068, 0x18506a17, 0x33212c0b, 0x8c619c50, 0x43412569, 0x81e0322d, 0x4164d584, 0x04a16af0, 0x6804be84, 0x2105e8a9, 0x989083a9, 0x4c22caa2, 0x94184ba1, 0x429806ad, 0x84a4cc54, 0xa0e82d81, 0x0892db06, 0x88390b1a, 0x0381f889, 0x2278b848, 0x42700e4b, 0x3ab300c2, 0xaa908076, 0xc1d78a00, 0x41255951, 0xb0005579, 0x22488ee4, 0x430bc0c9, 0xc5a0a4e0, 0xc360b482, 0x0f962043, 0x2202d92d, 0x9308e50a, 0xea50240d, 0xe1604e03, 0x9e632022, 0x4292c513, 0x440831bb, 0xf3e04440, 0xccc40943, 0x99a0b510, 0xa241a626, 0xcca410e2, 0x5ab50085, 0xc9228907, 0x22c6622c, 0x10a12f31, 0x078a119c, 0x10d2b381, 0x2c826326, 0x805e1ec0, 0x81790b0c, 0xcd5020d8, 0x18d858c1, 0x6a714092, 0xca0642a6, 0x1860aacc, 0x85213315, 0x23419436, 0x2114e28d, 0x15a2248d, 0x021ae652, 0x4d05c4a2, 0x4666a444, 0x6140ee81, 0x826430cb, 0x27ce4081, 0x1c458447, 0xadb00590, 0x0e64d045, 0x5389880e, 0x886860b5, 0x465e21a0, 0xc1135c18, 0x92e72005, 0x0b522589, 0x4560155a, 0x8a22984e, 0x07287268, 0x23c66482, 0xc644482d, 0x10cc6217, 0x19c8a388, 0x9988190e, 0xa0bd4e00, 0xc41ac14a, 0x0ab1cc18, 0x404e0d74, 0xd02a66c0, 0x91046633, 0x056076c1, 0x151b5c80, 0x4a28c585, 0x850730e4, 0x99845252, 0x0943099e, 0x6902cac2, 0x99fa1080, 0xd8402f84, 0x8501c9e8, 0xdd02c488, 0x38a41a1a, 0x8c0d292c, 0x021aec45, 0x59319181, 0x1e84416a, 0x10372598, 0xa8ca3032, 0x408c1d96, 0x48c1e509, 0x0c45e066, 0x9081ea25, 0xa23c12c8, 0xa5164096, 0xd0e18186, 0x548350c3, 0xdf10a204, 0xb08cb8a0, 0x1a51a60a, 0x70344349, 0x4ad8a2c0, 0x001df20b, 0x0a979806, 0x07320c1b, 0x4138fb00, 0x4501dc25, 0x17915442, 0x940d4392, 0x2a86cc06, 0xb34a0152, 0x704e114c, 0xca42452c, 0xd4063622 },
    .{ 0xba42a611, 0x7a414895, 0x4882ede0, 0xf62a20a4, 0x36e4208d, 0x0710742f, 0x139888e3, 0x039a0c57, 0x57699420, 0x84bf2c04, 0x9e911027, 0xc1899f80, 0x81631f05, 0xa1234c69, 0x14b87941, 0x47da2811, 0xcd013728, 0x21cd82ac, 0x091a17b4, 0xc615dd00, 0xae29403c, 0xa398901b, 0x1cd24332, 0xe4d68405, 0xd48e2078, 0x45644672, 0x00fe5944, 0x194587d0, 0x2bc68e08, 0x8b4ee011, 0x42830db6, 0x4314eb44, 0x1c980ace, 0x88523c59, 0x9a7c102c, 0x30bc06a6, 0xa4147ca8, 0x54586730, 0x208d5ce2, 0x351494ac, 0x238a4c2d, 0xa843e291, 0x97440d2a, 0xd2968e01, 0x0e26ae82, 0xb2d4a620, 0xc9416171, 0xf4ad4410, 0x462a7b20, 0xcd28c216, 0x5b3500ac, 0x1d10dc49, 0x2705b505, 0x82f424e2, 0xc51261e1, 0x012d655c, 0x624123ab, 0x541242f9, 0xd21407cc, 0x1fa108b4, 0x01b807d9, 0x5c4a6483, 0x09ab4ab0, 0x107d035a, 0x1ac68b0c, 0xc60360b9, 0xd92c4134, 0xa183a307, 0xc3f20ac0, 0x64499689, 0x17546434, 0x9cc11a13, 0x539050ae, 0xcc8d0d24, 0xe9a054b0, 0x3e149914, 0x236744c2, 0xcac2a348, 0xba0428da, 0x571a8432, 0x61c431b8, 0x9a1a6036, 0x529cb484, 0xfd1a4410, 0x250a968d, 0x8a08b22f, 0x4646592a, 0x0af84949, 0x2458cae8, 0x882829af, 0x23247543, 0x209e54e2, 0x38e408ea, 0xa2967062, 0x244c5176, 0xe56e0118, 0x2516c60d, 0x7c1a0b82, 0x12e0d9e0, 0x09b006f9, 0x1417bc28, 0xcab0b209, 0x3887e026, 0x71ac12a4, 0x02be00bb, 0xe06ba888, 0x986229b4, 0xa4e6091a, 0x0b21ad89, 0x658bc0c4, 0x463c11e2, 0x4c4668e2, 0x6c546413, 0x48f91344, 0x2c03463d, 0x0726a712, 0x58ba2298, 0x4081b9d6, 0x0019f3e8, 0x4e554145, 0x82d36e10, 0x1dce4052, 0x31613839, 0xd2ed0540, 0x02597855, 0xbaa16602, 0xd0238935, 0x4c2b29c2, 0x442374c5, 0xa48bf003, 0xd4e0094e, 0xd45131b0, 0x8606c556, 0x08c6e2b2, 0x3184a89d, 0x1184d9d4, 0x4901e5b2, 0x480779a2, 0xe09e8849, 0xab414616, 0x49592b42, 0xaa85c0e8, 0x8e296a28, 0x668a28aa, 0x1d2462e4, 0x75164390, 0x3b4282a9, 0x1180aeb3, 0x0683f321, 0x6d8fb000, 0xa95521c8, 0x53005e39, 0x073ed280, 0x08bb2683, 0xe2d18264, 0x2db53840, 0xa38f9900, 0xa8345a43, 0x40991a6b, 0x2920e52e, 0x472d3421, 0x34a2466c, 0x171aa342, 0x02430d77, 0x06b95314, 0xd1c60466, 0x2498869b, 0x921474ca, 0x89cb02a5, 0x5f910851, 0x256904f2, 0x74150e54, 0x1898bc07, 0x6ed14058, 0x1a6819a6, 0x88335ac4, 0x28750d49, 0x112a4cea, 0x84cb1a2c, 0x65c12896, 0x211c6ec8, 0x1e548a2c, 0xde031505, 0x71837290, 0xc5159522, 0x42039735, 0x8380ad27, 0x06346c8e, 0x84d5321c, 0x6b551049, 0xf03012ec, 0x91d65209, 0x2d5e2034, 0x21a3981b, 0x435b9510, 0x07a1b21c, 0x0d644c59, 0x035dd411, 0xcbb0c488, 0x62abb104, 0xcc534948, 0x91174c98, 0xf138c380, 0x302581f3, 0x4243b3d0, 0x124ce82d, 0x3c1e98a0, 0x0bf44462, 0x9f4860d0, 0xc5474489, 0x4acb00a7, 0xae1252c8, 0x478126a3, 0x732091f0, 0x4421ecc3, 0xc16a2386, 0xcef41801, 0xcb888a43, 0x84c56c26, 0x15515493, 0x3481b919, 0x21c984c7, 0x617ac228, 0x5951184e, 0x45c91e21, 0x86dc0685, 0xa1d0db20, 0xf09db001, 0xad542f00, 0x54e5054c, 0x88c32d49, 0xa0753164, 0x146bea04, 0x0b35e40a, 0x3180339e, 0xdd029074, 0xa2b35222, 0x29955291, 0x31125e70, 0x3aa5a828, 0x56d45085, 0x03386999, 0x1e962948, 0x1e15444e, 0xafd20803, 0x405d95c4, 0x72196470, 0xd113b083, 0x944543d1, 0x2a57d500, 0x3091db81, 0x4d4096c9, 0x8849e1c6, 0xc826528b, 0xcb508855, 0xa34e4219 },
    .{ 0x8a2cab89, 0x9bd0ca24, 0x41b9ba18, 0x94e121b3, 0xde911e02, 0x2f4a8d28, 0x2530dba4, 0x60c15cf8, 0x2a4b4395, 0x2c6c23d1, 0x7cb04cd0, 0x96ae182a, 0x14174bca, 0x7c5d7020, 0x98467474, 0x436415f2, 0x155c94a3, 0xdb09e502, 0x71e0da03, 0xabe400cd, 0x68a4e0d3, 0x59293c64, 0x9427728c, 0x56e305c1, 0xd10fe015, 0x37044d1e, 0x72ec260c, 0x44877685, 0x75134619, 0xc0013efa, 0x6d20db81, 0xaa84a23b, 0x34cba458, 0xda854c13, 0x03ed9d80, 0x23159e58, 0x72f484a8, 0x3941732a, 0xc5495392, 0x41aad8d4, 0x2b8ca878, 0x3b16988c, 0x5a791588, 0xa64cc3d0, 0x68b0de24, 0xce447039, 0x1fa4d640, 0x1ea8e24c, 0x1a92c633, 0x659d105a, 0x94e06d0b, 0xab455588, 0x0975aac8, 0x289f4724, 0xce0e2662, 0x2e862536, 0x224dae38, 0x2711478d, 0xaa4e0966, 0x217c4b86, 0xa428b734, 0x8d632a51, 0x84b8e0ec, 0x384b0477, 0x0ab185f8, 0x2f1b6848, 0x9f046d22, 0x44d3d151, 0x4164f2e1, 0x2e546172, 0x42ac6e07, 0x0dd41e92, 0x4473ce44, 0x0a210fed, 0xe4218a7a, 0xf54c3504, 0x0c14b4fa, 0x9c71a303, 0x86f31306, 0xc5c3312c, 0x4403cf35, 0x395304f4, 0x43cc7d80, 0x1bd4411d, 0x7881d42e, 0x870269e3, 0xd563940a, 0x1fc5c580, 0xc3f47300, 0x54318c1f, 0xeac36501, 0x95712b81, 0x0e7469c8, 0x3c2e4351, 0x8154c3ab, 0xc8249eb2, 0x48e55748, 0xf756a080, 0xf1378007, 0x01a6ed85, 0x601f1716, 0x15b71891, 0x19e29598, 0xd0119a3e, 0x4c95a652, 0x56720c93, 0xe91911ac, 0xb015bd06, 0xe053143d, 0x058ad3b4, 0xb2097e18, 0xa2ce0963, 0xba4223d4, 0xa06623e9, 0x8c06b8b3, 0x136b0cca, 0x121f70c5, 0x0617d435, 0xb82cb894, 0x89ea16c1, 0x51e30387, 0xb44c6e48, 0x42992d3c, 0xb11b5027, 0x369095c9, 0x5444555b, 0x081dbb49, 0xa221e94b, 0x85a9994a, 0x2a21817f, 0x1b978982, 0x119e83e8, 0x2ed16291, 0x99b2252a, 0x6580f51c, 0x00ed50eb, 0x1245ccdc, 0x07cc833c, 0x40b2d457, 0x0277a0ce, 0xc28647ca, 0xf028b44e, 0x1893c633, 0x12ef1138, 0x8a6db10a, 0x4027fb03, 0x4444b16f, 0xa088cabd, 0xa341d781, 0x81eac256, 0x4ce5406b, 0x54a2e4ca, 0xb0711559, 0x41327c9a, 0x69026e99, 0x40767a13, 0x16b45594, 0x8d9e0b90, 0x0c3b06ad, 0xf28068f2, 0x20dc8f83, 0xfac44c21, 0x025d3cd4, 0xa071b83a, 0x017d0877, 0x416396ac, 0x0b34f344, 0xc0a9ec2c, 0x13a4c6c3, 0x0a89334f, 0x326798a2, 0xa11836cb, 0xe31a813a, 0xae69201e, 0x48ea6cc4, 0x624ad1aa, 0x8582eaac, 0xe434819e, 0xbcc252a8, 0x734e4306, 0xd003fe0c, 0x4c455f81, 0x03c99b8c, 0x88316c3d, 0x1671d560, 0x55312f18, 0x23c28ace, 0xc5a93858, 0xcd944ea0, 0x6b01e89a, 0xa8b90a6a, 0xc65c093c, 0x2e4684ce, 0xc7511634, 0xa119c378, 0x3967a206, 0xab20f18c, 0x603c0f66, 0x5c6298a9, 0x971194e1, 0xe510a695, 0x2928527e, 0xd59b1882, 0x956442ba, 0x326ac549, 0x0ed058cd, 0x563da031, 0x72312e4a, 0x9ed1e801, 0x1f450c35, 0xabe70013, 0x61dd8710, 0x00cae99e, 0x54ced20a, 0x2272764a, 0xb086f036, 0xeb043117, 0x813a8f16, 0x3a69ea01, 0xe11b3e04, 0xcc10d6e1, 0xc69ac123, 0xd038f590, 0x30e348d9, 0x0d713a83, 0xb130cf28, 0x1250c3e7, 0x3454734c, 0x01e0cbb9, 0x5b025b25, 0xe2e0aa61, 0xb01a9c93, 0x594e5381, 0xa2d443d4, 0x3a41a96a, 0x91784cc6, 0x60c14bd9, 0x6a016793, 0x6739ac80, 0xcc00ef29, 0xe1c12a1d, 0x8174e293, 0x8385d2ac, 0xe8e0cb44, 0x7255a305, 0xac361a94, 0x38953ca4, 0x4c2d9a32, 0xee49b110, 0x0bc7ae80, 0x4d457c30, 0xc4f34b02, 0x466349b2, 0xd181c46d, 0xae8e01ca, 0xbf265440 },
    .{ 0x6629b14d, 0x01b614ef, 0x2bace0b2, 0x9d856a26, 0x5f8a58e0, 0xb18ba28b, 0x6663323a, 0x30688ded, 0x41fe0671, 0x8c689be8, 0x79704f0c, 0x1d99e4b0, 0xc8d4a68e, 0xd3936407, 0x0a591dad, 0xf168e432, 0xc23b8713, 0x8469e656, 0x5d26c6a1, 0xeb1145aa, 0x0474e667, 0x96c1da2a, 0x2e663750, 0x09d662f4, 0x69ce2629, 0xfaa848d2, 0xad84b543, 0xa71d1195, 0x7e8024b7, 0xa2a2857d, 0x6e424a73, 0xc51d26a6, 0xc1a5647c, 0x664696ac, 0x8ee82475, 0x19e7e908, 0xe05bfa01, 0x5a71f205, 0x5e811eb1, 0xe57056a8, 0xc8bd8721, 0x0539ba8e, 0x0966cab3, 0x4673a43c, 0x59366323, 0x1b73a249, 0x35279529, 0xf28254d5, 0xb1c9c295, 0x0cd3966c, 0x63525a5a, 0x4a6518fa, 0x9e7416d0, 0x751d5321, 0xc22ba273, 0x37b881e4, 0x0b56f330, 0xb928e332, 0xbdb01d84, 0x3ea82cb2, 0x6fa242d4, 0x65b4d311, 0x158f103f, 0x7d0242d7, 0x75771188, 0x5b8453ac, 0xae78621c, 0xac12ec63, 0x1483379e, 0xc11a319f, 0xf550c0b6, 0xc592c372, 0x9a548da9, 0x216c76b8, 0x29464f4e, 0xce853b88, 0x78314f91, 0xdb09864b, 0x7da6a0c2, 0xbc356b08, 0x1d6c4ad1, 0x9cde900d, 0x425f2ac5, 0x0af6033d, 0x0529bd33, 0x2507ec9a, 0x0c79692e, 0x652986cd, 0x906acc37, 0x04b9cf38, 0x272087be, 0x5ab15499, 0x0825e3f5, 0x4ec3b072, 0x4b227c39, 0x2c467933, 0x761aae81, 0x5568389d, 0x0bae5287, 0xc668c1b9, 0xce80eab1, 0x093d38b3, 0x5c183e36, 0x3909c73c, 0x22b442fb, 0xcc255dc1, 0x8aa95acc, 0x26473395, 0xb888ac73, 0xdc451ae1, 0x94bcb470, 0xa2751b58, 0x99710976, 0x319b525c, 0x886aa69d, 0xc2e65a68, 0x5a0d6e43, 0x06ce486f, 0x49cf414d, 0xb853c649, 0xa316929d, 0x8cd6033e, 0x79e043a5, 0x74473326, 0xb7952464, 0xeac24f41, 0x03c87ac7, 0x39a891ba, 0x1d23cb8a, 0x1336ba45, 0x4a19ced8, 0xbb432cd0, 0xbc99026d, 0xd2254d47, 0x0b64be43, 0xc4d9b04d, 0xf3293285, 0x906b4f98, 0x58885dda, 0x817829fa, 0x27d4544d, 0xf8a8385a, 0xb4b2033e, 0x13153d27, 0xc52d4acc, 0x3a161f92, 0x512665e6, 0xe390ea32, 0xb296c705, 0x452c475d, 0x5e2e1316, 0x2d08aaaf, 0x7bd87030, 0x7443c0be, 0xac9b8683, 0x7d218f30, 0xc2dc114f, 0x75865970, 0xe3a2a2d4, 0xa636de80, 0x8b479994, 0x1ddb5091, 0xef889309, 0xa766442e, 0x43654a3e, 0x6a5d3614, 0x1398f163, 0xb2cd4529, 0x5709354d, 0x66988f29, 0x351b4a74, 0x0b0fd929, 0x46369d91, 0x7534294e, 0xe2942de1, 0x694bc12b, 0x323f0ca6, 0x3f62a8c4, 0x22c0ef71, 0x0d4da1cb, 0xbe013267, 0x94149fd2, 0x7b55806c, 0xd3a80bc9, 0x22da4766, 0xf93e4508, 0xd04c4e7c, 0x5981fe88, 0x3df06509, 0xd36a20ad, 0x674472a3, 0x0547ead1, 0xe4e43545, 0xa24bbe82, 0x0f526527, 0x0d3d3866, 0xcc676485, 0xd7980b45, 0xf410ced4, 0x60a57e1c, 0x1c4c57d1, 0x488f334d, 0x20ee7c83, 0xda28474e, 0x7a328792, 0x964e9487, 0x51e703b4, 0x681a0d9f, 0x5b0a135e, 0x2b8bd229, 0x5c88ec39, 0xd508537a, 0x45711ec9, 0x319407d7, 0x427698ce, 0x2566c0af, 0x0b2ed20f, 0xd3fa1094, 0x36e0a96a, 0xf9902f30, 0xd5a648d2, 0x545095ee, 0x71288b9e, 0x1305df38, 0x5a41fe06, 0xb1c23d26, 0x4b60766c, 0xea8589d8, 0x12351be3, 0xe66229e8, 0x6cf8d08a, 0xa343dc4a, 0x58da468d, 0x71e9130e, 0xf858382b, 0x78ead181, 0x36171359, 0x950d2f2c, 0xefc900cc, 0xe0d84a2f, 0x92b2f948, 0x672e21a5, 0x0576ae15, 0x47643f81, 0x4611aacf, 0x0d509bab, 0xc96e5154, 0xcbe0429e, 0x71c064e7, 0x4079a47b, 0x98578e07, 0x4b16d685, 0x5c8e3507, 0xcb2ea24a, 0x15b6c31a, 0xc95844f9 },
    .{ 0xea51fa03, 0x34c7d714, 0xe69e409e, 0xfac79302, 0x0c4bbea5, 0xc88ab92f, 0xeae4a84e, 0x131d78f2, 0x1ada9a96, 0xce517e09, 0x877898ce, 0x1b075dd1, 0x27a99327, 0x6e017d99, 0xd8c69d8a, 0x1e63e6a1, 0x949628ef, 0x409174ff, 0x576621f8, 0xcbb65c05, 0xe4e242f6, 0x32b9e42e, 0x5e53b2a1, 0x75890e97, 0x9837a8ba, 0x43d903fc, 0x8672b83d, 0x5e66dd01, 0xa493cbd8, 0x78e8316b, 0x579503c7, 0x7e2c0bb8, 0xa6ed8744, 0x60ee3b15, 0xb86f12d4, 0xb230f396, 0xb4a8bc99, 0x246b39ea, 0x3e066de4, 0xd312a735, 0x9ae8c6c6, 0x465e1cc7, 0x290f147f, 0x4de9154d, 0x71369ac6, 0x4de31a6c, 0x5449fc8e, 0x9514d3cb, 0xb215af0b, 0x9ae9e207, 0x48ef08be, 0xc06a157f, 0xcf1a825d, 0x2b3a06ee, 0x27e0cd55, 0xce424f35, 0x91fd1d81, 0x793e805d, 0x0e382fba, 0x5a4ebc23, 0x2dd5c934, 0xcc9b72c1, 0x50e93b5a, 0xe134a6cb, 0x292b6bc5, 0x9b86713c, 0xf03b8536, 0x9cd4b1c5, 0x9fa8a178, 0x916165ee, 0x9f1680af, 0xa4080fff, 0x347b02fa, 0x49a99d2e, 0x5caae2c5, 0x99323b27, 0xd58d384d, 0x56ca49f4, 0x27c6e435, 0x26de3385, 0xa75578c8, 0xd164f495, 0x6bacea48, 0xf42e9b18, 0xd6573891, 0x794a6d49, 0x0cfca4ae, 0x836bd037, 0x0af9e782, 0x31530bfc, 0x74eab82a, 0x1de12bd4, 0xcc0f1e4b, 0xde315c23, 0x4529ce75, 0x76947361, 0x294373b3, 0x724b8f86, 0x30cf4f26, 0xa53f46a1, 0x406ed66b, 0xcaa253da, 0xd93a1574, 0x2ad969b2, 0x8665e5b4, 0x5e29b178, 0x1ac13d5d, 0xfc6a21c5, 0xbda7a405, 0x453bc8e9, 0x9db0b165, 0x0fbd7c20, 0x8273b8ba, 0xdfe81909, 0xba486be2, 0x079d9917, 0x8036e5eb, 0xce25b9e0, 0xf33cab01, 0xa227ad69, 0x8c85f666, 0x66cdc931, 0x961ccca7, 0x3fd383c0, 0x0bc56b93, 0x2943f13b, 0x84cfc19e, 0x67929a99, 0xb54d2b64, 0xefa422f0, 0x2d22b7ac, 0x42dfe10e, 0x4d0ba5c7, 0x19996dd8, 0x13ddb344, 0xf22c6399, 0x2750de63, 0x9a27b519, 0xd3dc2a51, 0x444ef3a5, 0xc7a21e39, 0x06d2e9cd, 0x8913e69d, 0x92e5db22, 0x09e69d59, 0x140bb4fe, 0xf498635c, 0x51aca5ad, 0x95147676, 0xba2c899d, 0x4bc65627, 0xd85bcc0e, 0xe0f926b4, 0x55e3a728, 0x59591b99, 0xb6da5807, 0x199e8f25, 0xe3a7312c, 0x1fb0d398, 0x760cea66, 0x4e63686b, 0xf4a8036f, 0xd589c9a3, 0x7dc5a909, 0x79c684f4, 0x40de7ae4, 0xc66538f4, 0xd0c9a47e, 0x94acbe07, 0x3cbda170, 0x286fcc4e, 0xe2254af3, 0xbfa14a0e, 0x542f2d9a, 0x9f604e35, 0xb152dc99, 0xbd6549d0, 0xde2c16c5, 0x5ba58ad4, 0x3ad5548e, 0xe3807b35, 0x2b575b0c, 0x72d50cf8, 0x9956b15c, 0x6d2178d9, 0x532d51dc, 0xdca358f0, 0x155adbc4, 0xfb06688b, 0x69d56839, 0x01ef4ba9, 0x016e547f, 0xd5d89cb0, 0xf842297d, 0x32cf326a, 0x9078bf45, 0xc58b9d16, 0x4c738cab, 0xdc2326cd, 0xd4b9af40, 0x098e4ddb, 0x6d8d6962, 0xe3a4107f, 0x5cbab0b4, 0x5c0caf4e, 0xfae6a980, 0xa600fe3d, 0x35aebc48, 0x4e7e0c65, 0x948527f3, 0xccad3e44, 0x73783436, 0x696444fe, 0x9835ae4d, 0x1a4bcc2f, 0x243acef1, 0x820d7b5b, 0xcc546771, 0xcd571135, 0x4b355c59, 0x3d4438dd, 0xe85e1ec1, 0x193bdd82, 0x758742ae, 0x891d873b, 0xed0c4f07, 0x6016be7a, 0x08df5655, 0x477e8703, 0x051e57ab, 0xedf42095, 0x15e93378, 0x71bdb221, 0xdb845137, 0xc942afc5, 0x2137ab63, 0x1158ea7b, 0xeab89b82, 0x8b5dcca2, 0x27606bf2, 0x5a4c3ee2, 0x2adf08f4, 0xa61e593c, 0x7c184f2d, 0xe4425f65, 0xdde84c58, 0xb8a56e25, 0x84742bbb, 0x38eb4c2e, 0xd5d821ea, 0x0ece36b2, 0x62c1c3fa, 0x5c3cf01d, 0x07d24e5e, 0xd33ada82, 0x303899fe },
    .{ 0xe64d065f, 0x6d56f6a0, 0x5de9e05a, 0xda3cae49, 0xe3aa194f, 0xff9b0582, 0x985e59e3, 0x9e4d394b, 0x8e53e4f1, 0x291de3b9, 0xdb0aec1d, 0x17edf034, 0x3ec3d961, 0x50762df9, 0x17637a8d, 0x5ee66472, 0x47e217b3, 0xe81b6ea9, 0x12e7db51, 0x7b8f8361, 0x843fcba9, 0x08ff2fa1, 0xed465517, 0xc28652ff, 0xb81e579c, 0x9a3b97e0, 0x9e91a5ad, 0xc6fd1271, 0xf1bbd086, 0x83bb84e7, 0x5755b26c, 0x1eabd592, 0xbbedc034, 0x8ec3c5e5, 0x594beab4, 0x8c7e8b53, 0xec2063fb, 0xd4dc133e, 0x668c85f7, 0xf13ae2c6, 0x2fd37823, 0xc9bc7523, 0xa351375d, 0xeae72d05, 0x26d9cf89, 0xee162d78, 0xffe36408, 0xede104d7, 0x51d27b4e, 0x245dfca3, 0x4d95f9c1, 0x577a38b2, 0x350bcf66, 0x8875ee55, 0x3c9572ab, 0x7d418abb, 0x8d37e4b2, 0xeabb5c28, 0x7226e375, 0xfc980776, 0x0fe97b0c, 0x473f1ac6, 0xeb02d07f, 0xd6e049fa, 0x803d9fe3, 0xbf88b670, 0xffa0a968, 0x69bc73c4, 0xbb938aa9, 0x2f425b73, 0xfa9b5c0c, 0xce07ebb0, 0xbc2b719c, 0x96358bd9, 0xc1fbcb82, 0x65bc9c2b, 0xf57032da, 0x6649dc9b, 0xc63dbd90, 0x4d5cbce1, 0xdeb5c807, 0xf0fc1e25, 0xd51dc3d2, 0x52b313db, 0x28f97ca9, 0x71a8db1b, 0x34f2d94e, 0xe6a29f89, 0xdd60cc8f, 0x3ef1d21c, 0xc1725bf2, 0x07faa96a, 0x9e8a38b7, 0xd64adb15, 0x122e5fc7, 0x45e7473c, 0x35bbcba0, 0x4dabcd0e, 0x3b57be20, 0xff046e13, 0xa3c55c73, 0x1a68fab3, 0x0e31f4f5, 0xa634756d, 0x17b2de8a, 0xe81a6f1b, 0x6b17283f, 0x6475b279, 0xe594e3ac, 0xadbd0933, 0xe994e6d8, 0x746eab85, 0xb6ece2c2, 0x1f074eb6, 0x41f6ca9b, 0x8357ad4d, 0xa54e5a7a, 0xf996a652, 0xecbc8b92, 0xd96f0af0, 0xff540aa9, 0x729c2cdb, 0x5d41cd97, 0x3464ef8b, 0x2f762e23, 0xcae2b347, 0xcb0fae1c, 0x17a46df2, 0x29dcd5e4, 0x64ed56ac, 0x07c973e5, 0x3df3ca14, 0x96bd8b92, 0xd4e1ad5a, 0x579560b7, 0x9d0a37f8, 0x3d2aa66d, 0xcede2da0, 0x3ac9e56c, 0x1db09b37, 0xe94868f7, 0x57a07e5a, 0x348f16f3, 0xf30f626a, 0xc0fc7ae8, 0xb29e8fa8, 0x775712c3, 0xf7405f54, 0x635a2bd9, 0xd20f572b, 0x16ef2974, 0x12d9d3ce, 0x9b73485b, 0xa56aa1cf, 0xb8fb0e4c, 0x9761f26a, 0xf0c475e5, 0x3ba8ccec, 0x33973b62, 0xdd8913ce, 0xfc079a9a, 0x37678ba8, 0xc7fe1254, 0x50979ed5, 0xbc6b6c83, 0x73fa3720, 0xe5e21d96, 0xbdf20867, 0xdaf6e058, 0xce2c1d6d, 0x7e18f83c, 0x723beac1, 0xb8ce6c63, 0xe1f22dcc, 0x245fe8e5, 0xe4c270bf, 0x39aa6a5e, 0xdf98a24b, 0x193e55f4, 0xf534ff00, 0xba74cf24, 0x62d36597, 0x0476d33f, 0xf6c35ae0, 0x7d6e3c05, 0x6bf5a096, 0xa87e0a7b, 0x4d1696b7, 0xa35ba4f8, 0xdfe4642a, 0x22df5ccc, 0x27eaa95a, 0xf4ed4a86, 0xd9580f1f, 0x436fd362, 0x5ab0bcf1, 0xcc348efa, 0x56cc4ecb, 0x3263f25e, 0x0bf8ea53, 0x1b81fee4, 0x6fa0b3e4, 0xfeaae8a0, 0x5658fd52, 0x7f151a72, 0xda9b0f64, 0xf4c1f4b2, 0xa826f7c3, 0x755d0676, 0xaee2f0d4, 0x35d7ca98, 0x7d296e4c, 0xe1d15575, 0x7f2b2295, 0x037ec83f, 0x1e5a795a, 0x3760e4f3, 0x729c98ee, 0x087ff964, 0x2adcebc2, 0xbfec9540, 0x5993f41d, 0xb237ba70, 0xd72e4b1c, 0x3af6691c, 0xea1aa3ce, 0xe619a56e, 0x027daf0f, 0x822fd6ec, 0x79970b1b, 0xd0db0cbd, 0xa26e175b, 0x5c8fa11f, 0x99ee6c92, 0x65198ef3, 0xd86adf82, 0xcd638c73, 0x45f57e24, 0x8e3b3b54, 0xd41a3de3, 0x27780fce, 0x3ce6ec07, 0xf13616f4, 0x63e5ac33, 0x886da4f7, 0xc5670bea, 0xefb401ec, 0x1d6e7e82, 0x999b5f24, 0xb2a03f3e, 0xbc2ee6a4, 0xdd374217, 0xec9e236c, 0xae6e2b64, 0xb20cf6e9, 0x6abec89c },
    .{ 0xae478b76, 0x4ba6d5ab, 0xf98d0e75, 0x995bafa1, 0xdde06733, 0x91d74ceb, 0xbd98959e, 0x7d5465f2, 0x0e7dd8f1, 0x3dd63c63, 0xd7ec2c55, 0x387e29eb, 0xbb5db2c2, 0xd7c95c1e, 0x47622bdf, 0xeecad561, 0x3c2ae775, 0x190dfab7, 0x0fb8bcce, 0x1d39e95b, 0x9e9e9ed0, 0xd274937e, 0x76acc66b, 0xae6f4b25, 0xf1545d97, 0xcccaec4f, 0x1e6e5f29, 0xa8f173b3, 0x7ab22be6, 0x2735ebac, 0xe6a69e5c, 0x7db2135e, 0x3a37f271, 0x17e32b37, 0x362ee75a, 0x9f2cec55, 0xfb1ee8a2, 0x9be32db1, 0xb270bb6d, 0xea987e8b, 0x7f65b24a, 0x0673e577, 0x9bef48d8, 0x56fca62b, 0x43a9c7dd, 0x7e3f4cc4, 0x2b79893f, 0x360f9e8f, 0x547e3b56, 0x4eea3eac, 0xb0bc7e36, 0x8a5fbca6, 0x58a666df, 0xb8a2e6b7, 0x3f93ea26, 0x8d5fa39c, 0x6af75932, 0x7fc256c9, 0x6acb9eb1, 0xb32dd68b, 0x18bbb9ad, 0x69e06bb7, 0x4bfce8ca, 0xede5cb84, 0xbe78751c, 0x697a0fd5, 0x5d43bcc7, 0xa718ee67, 0x966a2cef, 0xf73ef050, 0x3f37cd82, 0x9fd66ac4, 0x2caf3c3e, 0x4c9d745f, 0xd2a7d966, 0xb623a6ed, 0x7f34258f, 0x98f68cf3, 0x3f27bb21, 0x63f389e3, 0x354d91ef, 0x0fcbaee2, 0x5bc53db4, 0x54c3ef95, 0x536b0f3b, 0x6f7dd980, 0xc8df6ba8, 0x0b39f795, 0x0ccfdb63, 0xd0ab66af, 0xaab75762, 0xb4df6d14, 0xd9c9ca75, 0xb0d185ff, 0x879a7d53, 0x3eb11d7a, 0xbef893a4, 0xa6f21f4e, 0xee57831e, 0xf6ec3994, 0x2f047ddb, 0xcfe8f107, 0xaca1ecf3, 0x99e1bcf2, 0xeb6c4576, 0x478bfa69, 0x80bacdfe, 0xacfb6c64, 0xf4b65d16, 0x4f61d78b, 0x321fe5e6, 0xc9aea3ab, 0x7d3f8b81, 0xbc9d11e7, 0xdf733838, 0x978e9d66, 0x9bfe5550, 0x2de127f3, 0xc3f35783, 0xcad9d179, 0x2f752774, 0xf3a791c5, 0xb0fac39b, 0xa7fb4447, 0xa8f7fe02, 0x7d856f8a, 0x67fd06e1, 0x7ed983f0, 0xc39cb57a, 0x2f0e8fe3, 0xb2534fda, 0xcabf3872, 0xe9c4bde4, 0xc79ce333, 0xe6a69765, 0x2d8aaebd, 0xd1da5337, 0x15be59ba, 0xed9b4672, 0x38eb2d79, 0xdea74c1e, 0xdf0e627a, 0x76e89db2, 0xadfb885c, 0x4a3a367f, 0x4c6796b7, 0x99fe4e07, 0x58b3df92, 0x9193b5b7, 0xf2758736, 0x5789ed65, 0x18d97b4f, 0x4e7e5b91, 0x5e0e8ef9, 0x6d77ad05, 0x5ecf05e9, 0x6e1b675c, 0x996c5fc6, 0x0f39f0f5, 0x86de1d6d, 0x57d50cf5, 0x54b95ed6, 0xeb388e57, 0x18bd36f5, 0x3aee8dcc, 0xab31f6c9, 0x6641ff2b, 0xd8ea31be, 0x9ea47765, 0x4333c6df, 0xf32d10fb, 0x7fccc592, 0x543fb8b9, 0x47ecf239, 0xf1d0763b, 0x25e674ee, 0x8f618fe9, 0x3363dc6d, 0x5e09faab, 0x8e608ffb, 0x2e7ed319, 0xf39c92ea, 0x0fe57279, 0xbe3ab11e, 0xe6f1f606, 0x58933cfb, 0xc7aa873e, 0xcdd9638d, 0x4971dec7, 0xdb397ae0, 0xd0aa3fec, 0x2dfab685, 0x4bfb252b, 0x5f473f12, 0x75b92f32, 0xf6c6cb4c, 0x8d5eeb61, 0xb8f16e8b, 0xd063d6af, 0x953b71dc, 0x473c55de, 0x8e23dcaf, 0x7a0f97c9, 0x1fc27d6a, 0xa5f2d1b9, 0x958bb373, 0xdadf0f42, 0xb8fda8c5, 0xb2d89cdd, 0x139f65cb, 0x4ebf06b6, 0x5f883da7, 0x0bfcb2f1, 0x383c9cfd, 0x94bfc517, 0x5f2b1fc8, 0x778948ef, 0xb47266e7, 0x5e3f0af1, 0x3382fae7, 0xd4eb24be, 0xd2ed192f, 0xf7480b7d, 0xcdee239a, 0x2be2f9c3, 0xf92ec62e, 0xb1e427de, 0xc335e9e9, 0xcbb4af51, 0xb1dd553c, 0x3f50fea1, 0x0ecd6577, 0xe9c7e346, 0x699739dc, 0xce5cc7c9, 0x9f36f2b0, 0xea76cce2, 0xf995d42b, 0xb3cad33c, 0x16a8d5f7, 0xc3315bbd, 0x7ae61be1, 0x50dfd1d3, 0x0bdebd51, 0x683dab6e, 0x7d4ea8e5, 0xb59742ed, 0x33a98ef5, 0xb71d1f94, 0x09f335de, 0xffa2ea05, 0x650779bb, 0x9e5872f9, 0x46c1d7ed, 0xe1d9f0e6, 0xf5d49875 },
    .{ 0xa7e9a8fa, 0xd46df574, 0xbeaff284, 0x4e79a776, 0xd9bad9c9, 0x9d3319df, 0xb6bd4b36, 0x8a71f57d, 0xf8b9a7d4, 0xd74d755c, 0xbfc2dd4c, 0xfbfa2686, 0xe6c93b6e, 0xeff30cca, 0xd387b9b6, 0x9a1af7bc, 0xe297ff50, 0xeeec5a3c, 0x9abab25f, 0xa2dbfac3, 0xec768abe, 0xcbe0eef1, 0xbb60b9dd, 0xfeb66f40, 0x3af69c6e, 0xa575f555, 0x7c773c2d, 0x6fa722f5, 0xbf6ce147, 0xa5a76fc9, 0x756e722f, 0xf86797b2, 0x0ff5b45b, 0x51f84bbf, 0x2c57ded3, 0xb9fbc8c5, 0x4ba67773, 0x9d36ac5f, 0x7b2ed92d, 0x3f4f72b2, 0x7caaae75, 0xb7d8f4f0, 0x57d79ed0, 0xa75d26cf, 0x79f4e8e5, 0x9e23b6f6, 0x2ded43be, 0xbe98e4f9, 0x5969bd3d, 0xfd1ed29a, 0x7353f574, 0xd2c2fdd3, 0x6347f27e, 0xbee192f3, 0x5cf53ab5, 0xfcca6d6c, 0xb08d5bef, 0x5cc8dcbf, 0xdbdbbc84, 0xa3aefb98, 0x5375a8fe, 0x3a2b87fe, 0xcc4dfd95, 0xeaf33bc4, 0xdde596d1, 0x15edf26d, 0x43a67d3f, 0x15fcbc79, 0xaf529e73, 0xd971dcd6, 0xeeccb45b, 0xfa38c6fc, 0xc655f7c3, 0x59e4bafa, 0x1d59d7b5, 0xb15be4fc, 0xe4b6af78, 0xd3b2fcd4, 0xf6a5f24d, 0xe64ef9d1, 0x375972af, 0x7f1a52f6, 0x9eaf4976, 0xbf83e933, 0x9c1abfda, 0x5a55df55, 0xd8d4d3bb, 0x6967ed4d, 0xda9cefc1, 0x5c3a6e7e, 0x75fd7c48, 0xb77c4fc4, 0x97fce623, 0xc9d97d0f, 0x6c7cafac, 0x08799fdf, 0xa0bad6f7, 0x6b3bf728, 0xc3ebb267, 0xe70b6ef8, 0xd1ea745f, 0xb7f20ae7, 0xe4f6b6e1, 0xbf1fc2a3, 0xf5c2b2d7, 0x3747df2a, 0x6f5a25b7, 0x65eafe38, 0x4bfc649f, 0x2417afdf, 0xdba2a9fa, 0xbbf8cb54, 0xf33f1ce1, 0xf77d6468, 0x6cfca727, 0x57d6bbd0, 0x13be9c9f, 0xcbb44777, 0xff435d19, 0xf146bfa5, 0xc63f15ed, 0xbf3bb341, 0xabf0a8fe, 0x5e1e3ccf, 0x7ecaf136, 0xff6116ec, 0xd9fa345e, 0x5e318fb7, 0xf167570f, 0x1473dff1, 0x9e957ce3, 0x83c4eddf, 0x417bdfc9, 0x21fbbc6b, 0x0dbd1777, 0xfcc278e7, 0x5d15f7a6, 0xc3fb3783, 0xe479f378, 0x5ed5bb1a, 0x7a6faa72, 0x3be43c3f, 0xff8c3665, 0x87b24dbf, 0x363a3f79, 0x3de34b57, 0x6343bfa7, 0xe923f78d, 0xfe36b272, 0xf8653757, 0xdfce053d, 0x8eff8cac, 0x8f9c6ea7, 0x5b9b62db, 0x9fcbcb32, 0xbb463d5e, 0x1ba70efd, 0xcd71f1d5, 0xbed8a9f1, 0xdee1bc74, 0x6649977f, 0x3d79e2b9, 0xcbf5196e, 0x5f7039f9, 0x81799ebf, 0xbf73d889, 0xec7ca6f4, 0xded5274d, 0xbf6e451b, 0xfb6d31e2, 0x25f7f968, 0x49bdc39f, 0xb83dba8f, 0x98afdea3, 0x4b7e359d, 0x4bfa759a, 0x397b87cb, 0xece2bcb9, 0xff6d4265, 0xf4663ed6, 0x385bee4f, 0xfd63c34b, 0x7ca4c3ef, 0xff180fe5, 0x37dae3a9, 0xecd5996b, 0x9fbc9535, 0xf2f7d065, 0xf0abfe0d, 0xb0f715fc, 0x91a8bf77, 0x6fa7dc2c, 0xf13abe74, 0x88fbb74b, 0x6785f576, 0x6f26f789, 0xd787ab3c, 0x16e7bf8a, 0x3d54b3dd, 0xc26ef6b3, 0xf92bd2d6, 0xa5d1fac7, 0x8d1fcfc3, 0xdcd6dcd4, 0xba5e672e, 0x2dfe85da, 0x8ddb55d5, 0x4bfa9eca, 0x6f94bb35, 0xf43adf07, 0x0776ff31, 0x4cf5f8e3, 0x1d413ff7, 0xb37e8d4e, 0xee675578, 0x7cd5d8e9, 0xc8bb976d, 0xa3ef6d70, 0x6c27ee67, 0x0e7d79a7, 0xed72a74e, 0xcf1ed593, 0xe0af98bf, 0xd7ea29e3, 0x93da7763, 0x77a93787, 0x9ad3f17a, 0x7527b76a, 0xd97cb1ad, 0xc2c55dfb, 0xbe796ae1, 0xcad9796d, 0x26959f7b, 0x6fa963ba, 0xa1b2f7e3, 0xf54575b9, 0xeeedf121, 0x68b6f477, 0x14b7bf3a, 0xfe52af34, 0x9e639f27, 0x585f7673, 0x47777c8d, 0xeeb64fd0, 0x9d7dc53c, 0xf2ddb1d8, 0x4e77c86f, 0x56af9d3a, 0x92e67b7a, 0xe38dae79, 0xff84f8aa, 0x7bb0df89, 0xbe5b5959, 0x92bcf78e, 0x37cbe2d9, 0xd33c75d5 },
    .{ 0xf4893df7, 0xede961bd, 0x5d53baf3, 0x3c57ffd0, 0xd677687d, 0x779af2b6, 0xf66b4bbc, 0xc7cbe3f2, 0x9d7dc6da, 0xededfa14, 0x6f65d3e9, 0xd7cbbb23, 0x2e6e7f6a, 0xf577b26a, 0x91d33f5f, 0xbace8fe9, 0x988bbff6, 0x71b3e5bd, 0x6fc87e3d, 0x56ff1db1, 0xdb6ab1fa, 0x7f9c3b27, 0xa94ff62f, 0x5e7af68e, 0xf2eb1f1b, 0xb3fcd34d, 0x9e8aff4b, 0xcf62bdcd, 0xf19bf9d2, 0xa93a74ff, 0xe69df9e2, 0x3fc2f8bd, 0x73ed435f, 0x2dfc5f2e, 0x0debbcdb, 0xeedde6c4, 0xeca8f75b, 0xce4ffd98, 0x39db7ed8, 0xd65f6a97, 0x72d6b4df, 0xd1dee2e7, 0x639b9dbb, 0xdeac973b, 0xac7dd27d, 0xfe92c3af, 0x1793defa, 0x72ffb954, 0xd15efd3a, 0xc9c555ff, 0xfb13a59f, 0x6c6fcfd8, 0xbcc5795f, 0x19cf6d7e, 0x7c8cbf67, 0xb83dff4c, 0x4f39ef1b, 0x395cf677, 0x0bf4dbbe, 0xdc2fcef8, 0x0b7fd6cd, 0x6bc9fb1d, 0xe3e75e96, 0xf4399f5d, 0xa17bdb73, 0xf6173af9, 0x99bcfba5, 0xbc9fde51, 0x78fb7d0e, 0x76772de5, 0xdbd9b49d, 0xdfb2573a, 0xad7963e7, 0xdad4dc9f, 0xb59fec35, 0xf56bd4d3, 0x8ef655bb, 0xe17e5df1, 0xdfbcacd8, 0xf1997acf, 0x7cb6717e, 0x6af3be8e, 0x583dabef, 0xc8d8b7fe, 0xb6aab9dd, 0xfd4155fd, 0x676aaf57, 0xe69b8d3f, 0xfe78dd0d, 0x05efef93, 0xfde52ef0, 0x315beedb, 0x01fcefeb, 0x7bc471fd, 0x99db9bb9, 0xbefa46c7, 0x69f975e3, 0xc6c67fea, 0xaf93e9cb, 0xf53ecbc5, 0xacebab5b, 0xd6afea36, 0x0f2bb9fd, 0xfade8eb2, 0xff32d353, 0x3635feda, 0xfaa336af, 0x6f5ab477, 0x39cd0fbf, 0x5e79ee5a, 0xb7f830df, 0x476de6bd, 0xe759d87b, 0x92b7eea7, 0xdbcdb276, 0x22fae9ef, 0x5ae73ab7, 0xef8c5bec, 0xb8e6fd39, 0x7787b4bb, 0xf6a1ff4c, 0xfcfb7894, 0xcae9e2df, 0xbe455fd6, 0xfc4b90ff, 0x5bacb7b5, 0xb3b1dfcc, 0x8fdbcb59, 0xf51addb3, 0xe37de06f, 0xe1c5f74f, 0xff1d2f13, 0x27bfb33c, 0xaeced357, 0xd1cf69ed, 0x735fd1cd, 0xf02b99ff, 0x8f58d77e, 0xeaebbc2d, 0x2edcafd3, 0xb1eb8af7, 0xf3f69f81, 0x65d51bf7, 0xf8c7b63d, 0xfb82de3d, 0x4b7f374d, 0xdbeaa9f1, 0x673247ff, 0x97bfd2c6, 0xcca1bfee, 0x351d7f73, 0xc9e4aebf, 0xff07ad5a, 0x34f3bcbe, 0x7fc8bdf0, 0xeedba4ce, 0x693f57c7, 0xfd39c2eb, 0xf88f36be, 0xd69ee92f, 0xa755f5cb, 0xdea67db8, 0xf629b4df, 0x5ee7a47d, 0xe236ffd2, 0xe3dfb0da, 0x927e9fb6, 0xfc9fab15, 0xf2a8ecfd, 0xa673fd63, 0xad05ff4f, 0xf9cf7782, 0x6572bfcb, 0x7fd06e3e, 0x53dc63fd, 0xb9ed67c9, 0x799cb7d3, 0xfb57db12, 0x56be6dba, 0xde5d793a, 0x477b9d3e, 0xc9fa3bae, 0xed165f9b, 0xd9de26af, 0x2db7ea8f, 0xdd744fbc, 0xff8f81f8, 0xa9fde3e1, 0xc77bc6ae, 0x6bfc35f2, 0x4cf63f6b, 0xbe0efe0f, 0x9d15deb7, 0x19f3bbe3, 0xb3d6e7a5, 0x3ded78d6, 0xd7b8ba9b, 0x5b3efe92, 0x6e91cff9, 0xfdcac997, 0x4f063f7f, 0xf732bec3, 0x9de5ee6a, 0xef3c92f3, 0x43adedeb, 0xeefeb846, 0xbc56e9cf, 0xb8f74dae, 0x345fad7d, 0x3abedcea, 0x65f4e6d7, 0xfb3748f5, 0xdeced0d7, 0xe715b1df, 0xc2bdfd59, 0x9fe5ca7a, 0x2e19fbf3, 0x6d9f24fb, 0x1d6ddbd3, 0x66f7b8ea, 0xb2bb7cce, 0xefa63c6e, 0xbe0be5db, 0xede796c3, 0xb4aa9edf, 0xcebe95e6, 0xfed5b519, 0x40efbdaf, 0x7751bced, 0xbfeda199, 0x99b5c77b, 0xe1ebed93, 0xbc775b4b, 0xaa75ddad, 0x73daf693, 0x429aeffe, 0x56bed76a, 0xdf6b1be1, 0x765dd1ee, 0xed4fab69, 0x5abd95fa, 0xe0d16fbf, 0xabf5655b, 0x734b7e67, 0x1f56f33d, 0x7fdd2b07, 0x64eba3df, 0x57959df5, 0x76af4d79, 0x2dcdbcd7, 0x6defa1b9, 0x6e71f6d3, 0x57fca3d3, 0xa55b57db, 0x1a4fbcdf, 0xfd0becd5 },
    .{ 0xe32bccff, 0x5fd5d56b, 0x1d9a6fbf, 0xb7b3535f, 0xfbaf25f8, 0xf756dcf1, 0xf3be61bb, 0xe77bf1aa, 0x3af2fcee, 0xd0ebafdb, 0xe9cfce76, 0xf9d56dea, 0xfbeb9873, 0xff93f689, 0xcbdf39d3, 0xdf2fb993, 0xfdf49be8, 0xa7e71ee7, 0xf48ddd7e, 0x27b7ceb7, 0x532ffda7, 0xf6f8ed65, 0xba5b6f37, 0x5fdda37a, 0xf7d8ada7, 0x7a697f73, 0x53e7cfb5, 0x6775dcf9, 0x9c37ddfc, 0xb7def932, 0xe7d63779, 0xa95dddfc, 0xd6d9e5bb, 0xf7adeb13, 0xdd2fdae9, 0xbf3f52e6, 0xf3697de6, 0x97feba0f, 0xe6d63f2f, 0x9dfe15f5, 0x95f7b597, 0x16f7f1eb, 0xeeb4dd67, 0xac3efef2, 0xdbeb1f63, 0xbffd1d32, 0x4afebb37, 0x5dfd1e6d, 0x7ed46ff1, 0x65bfcb6e, 0xb6f376cb, 0xf854dbbf, 0x976e5fb5, 0x5fabadc7, 0xebf5aa37, 0x7da95f3b, 0x89dddd6f, 0x9256eeff, 0x7fda88bf, 0x26a7ceff, 0x7c6ff6a5, 0xb35f57ba, 0xefa5bcd5, 0xa7fdcab6, 0xdfdeec2c, 0x4ceeb3f7, 0x67f3df4c, 0xe6d3fcad, 0xecf3877e, 0xff669e9a, 0xbbef546e, 0xbee58df5, 0xb685dbf7, 0xbb8ee37d, 0xddb4f68f, 0x338bfbb7, 0x4b4acfff, 0xe9bef497, 0xdd2b3e7b, 0x4faaeff2, 0xded3c7e6, 0x777f99b4, 0xfebbee06, 0xf8cfb0fb, 0x35b5f37b, 0xd54e7f79, 0xd06e3ffd, 0xf7caad73, 0xf56e557d, 0xd9f2f66e, 0x5dd6cd7b, 0x67fb7c8b, 0xbeb95edc, 0xaaff88fb, 0x937fd7a9, 0x6ad5fdb9, 0x9beb8fe9, 0xe7bc977a, 0x75e8bb3f, 0x3bfe6ee2, 0x756ec7f5, 0xfcfae399, 0x1776f79e, 0xbbb9de53, 0x7d96de9e, 0xc57fb91f, 0xce47fbae, 0xd35f7dd4, 0xfbf2d03f, 0xf9dbe639, 0x0ffdbf94, 0x75cefee4, 0xb84e5fdf, 0xf8f2bb67, 0xddd65fc5, 0xdf4ee17b, 0xbf4fb56a, 0xbb55e96f, 0xf7f987a6, 0x56e3d37f, 0xd27f6f2d, 0xb373eccf, 0x3b19baff, 0x7efbf321, 0x3f8caff5, 0x7d6c575f, 0x4779bee7, 0x9e7f969e, 0xfd9a3c3f, 0xecdcd9f3, 0x9fa5f9f2, 0x8b9ebb3f, 0x92bfed5b, 0xb2fde6b5, 0x737e0f3f, 0x1dff736a, 0xfa2aeef6, 0xc391f7fd, 0xaffba695, 0x7bbf70d6, 0xbde974e7, 0x7b47ff0b, 0x3f3cbf8b, 0x5bd62fbd, 0xaff2cfa9, 0xcbdcff49, 0xcb3e975f, 0xff45cecd, 0x65c87bff, 0xecb3afb9, 0xd1bc79bf, 0xbd875fcd, 0xa2f17fed, 0x3467d7fb, 0xbe7e7a6a, 0xeb9e5add, 0xbd43fed6, 0x3f959bd7, 0xf79a3773, 0xff44fce6, 0x61ef7b97, 0xf25e39df, 0xddfc1b5b, 0x8fa7ef55, 0x1598ffef, 0xe3fb8cde, 0xfed4f69a, 0xfe6e33ea, 0x35bd7fe2, 0xe9c8fd5f, 0x29fbffa8, 0xdcab1ef7, 0xbc1cb5ff, 0x3d5df93d, 0x6efe6abc, 0x06b776ff, 0xefa6ee6a, 0xff41aeed, 0x73e57eea, 0x1763affd, 0xeeea5fe4, 0xedb61f6b, 0xb1fef2e6, 0xf1c6f7cb, 0x7de0bbf9, 0x6efe768b, 0xd197bdfa, 0x25f657ef, 0xdb6bdb5a, 0xfd36d357, 0x6db3e5d7, 0x6f78ff0e, 0x77cb793b, 0x5af6f1eb, 0xe3bba79d, 0x76fc1ddb, 0x65dbf6b5, 0xddf5c27b, 0x8f9bdd4f, 0xe17dfb4d, 0x3ed7ff12, 0x83af7dbb, 0x67decc5f, 0xcdae9baf, 0xfb6d9d8b, 0x0bb7daef, 0x5ef5acde, 0xff377f01, 0xe3dfdd68, 0x5debf65c, 0xd7fba27c, 0xe733577d, 0xc8fbecd7, 0xcff55da9, 0x1ebfcd3b, 0x7651ffe3, 0xad2fb9f5, 0xc05dfbdf, 0xf657cd3d, 0xff84d6f9, 0xa3dd5fe6, 0xe5dec76e, 0xfc8bddcd, 0xfb657cd3, 0x6e7f0bf5, 0x8eeb477f, 0x73dea9eb, 0x45f72faf, 0xb57ff42e, 0x4efdfaac, 0xf9caf36e, 0x077ecbdf, 0x4f3937ef, 0x7b0b5dfe, 0x95d9797f, 0xcd7ef4e5, 0xaf3fb3b1, 0x941dfffa, 0x2daf2fcf, 0xf93eb79c, 0x6be6e5e7, 0xa4f3dfcd, 0xfe9c76ce, 0xf6fab5d8, 0xb27abf57, 0xbfa3dab9, 0xdb77d2b5, 0x5b7ae5f5, 0x7ff39c39, 0xbb5d6f63, 0xf86e4bef, 0xf57d75b2, 0x67f7f06e, 0x86faabfb, 0xff473f15, 0xf4d2f5b7 },
    .{ 0xfbdf23b9, 0xec2fefda, 0x9f9b5fb9, 0xf76dbd4e, 0xe6d7fb56, 0x32daffbb, 0xf41dfb7d, 0x1eae9dff, 0x3fbacded, 0xbff43aed, 0xfbe4f3f4, 0x7bfadee8, 0xdaef65eb, 0xf95f2cf7, 0x6ecefddc, 0xffdcbd58, 0xc2fc7fdd, 0xbaaefef1, 0xf15feba7, 0xc73b5e7f, 0x5dbde2f7, 0xdcdf8eed, 0xa7f2eedd, 0x772f7f53, 0xbf3bf497, 0xf8bb8fd7, 0x6bf1fa7b, 0x6fb5f52f, 0x939ff9eb, 0xecfed747, 0xbb4fff32, 0x9fbe7657, 0xee7beba5, 0xffd10e7f, 0xfd88fbdb, 0xfd569bf9, 0x1cefafdd, 0x5ca7ebf7, 0xeefd363e, 0x7f9fde31, 0x6dedafe6, 0xbabcf37b, 0x9dfdaab7, 0xfad5f55d, 0x636ef5df, 0x3f9bfd78, 0x3fd69f97, 0x3ffb54bd, 0xc6ff6f5c, 0xa7d9cfde, 0x387ff73e, 0xb747ff47, 0x7d9f27dd, 0x76acf7ee, 0xd5e7acbf, 0x7fdf2ba9, 0xdbfa5af3, 0x78ff4d3f, 0xfdbaeb5a, 0xf5ff3b38, 0xf7deb26b, 0x8ff5cbdd, 0x5f0dfbcf, 0xef0bfed9, 0xfeb7b723, 0xaee3f6f5, 0xffed1b6c, 0xe87abfdb, 0x69beadfd, 0x77cb3fd9, 0x7fed3e4d, 0x5efedc5d, 0x9cdfe7ec, 0x5e2e7fbe, 0x493ffedb, 0xb6b8bddf, 0xfce6b5bb, 0xf575d6fc, 0xfcb5dbf2, 0x66ef99fb, 0x36f4efdb, 0xf4ddbbd6, 0xff6f78e1, 0xf1dfbb33, 0xedde3d5d, 0xb3aeecfd, 0xfcc75cbf, 0x3f5eddcd, 0xd9f7a5f3, 0xfc78e7f5, 0xcd3bdecf, 0x77dedb3a, 0xd3f27df5, 0xf7b7d13d, 0x6dd3fdd9, 0x717abdfd, 0x77d9d737, 0xd76df1db, 0xf6fbee19, 0xddc2bfb7, 0xfb42fdeb, 0x78f7b4ef, 0xdb6f7a67, 0x83ff98ff, 0xe7fd9747, 0xffdce785, 0xf6bb53fc, 0x3f38affb, 0xcb5c7fdb, 0xff79a5d9, 0xff465f67, 0xd5a7ddbb, 0xdffde217, 0x93fedaee, 0x76affc5d, 0x9f4fdb2f, 0xfc6f4bb7, 0xdf9f2f69, 0xc5efafe9, 0xeb7e7a6d, 0xebd9ce6f, 0x4fdf8f37, 0x25d7f5fb, 0xd8be5ff6, 0xb4ffd975, 0x9beb3777, 0x78f1cbff, 0xba3f9fb9, 0xab778aff, 0x67f975d7, 0xeff75d86, 0xe7e7e3c7, 0xfb3e79d9, 0xb3a3a7ff, 0x7dcf35f6, 0xdbbbe9e9, 0xf7dcca3f, 0xf33efcf1, 0xc72f7e9f, 0xf9f1eb6d, 0x5ff6eace, 0x5f5f2f1f, 0xaacbfdfa, 0xe6d6f9bd, 0xef9bfa33, 0xf8e6f3d7, 0xbf459bfe, 0xdbc9fee6, 0xbd2fc7ed, 0x5b63bff3, 0xfaddd763, 0xafede65d, 0xdc8bdf7d, 0xea6ca7ff, 0xbba7f747, 0xb78df2ef, 0xdfd7cb74, 0x3f9c7efa, 0xdfde66d9, 0xdad7caf7, 0x59a6ff7d, 0xbaee7ea7, 0xbe7757f4, 0xa8eafebf, 0xb5d975bf, 0x93bd6fcf, 0x5ff5fc53, 0x3f57f63b, 0xf9f3fa9a, 0x2bfeedec, 0xdf633fe3, 0xf77a963f, 0xfa7bfa3a, 0x5de2f57f, 0x975b6ffa, 0xd7d7733b, 0xfd7ef326, 0x9fcfc7da, 0x369f6ff5, 0x383f5fdf, 0x537df6fa, 0x4d7b9dfb, 0xb5be8f6f, 0x3eb5bbed, 0x3ebedb79, 0x5a75fb7d, 0xeccfcd77, 0x979ff27e, 0xfcebe756, 0xb7f77d92, 0xf2f533fd, 0xfd0ffdf0, 0x7eac7ff8, 0xea9d7cbf, 0x7d1f7f63, 0xc8eb9fef, 0xb45fcfed, 0x7c7ed73e, 0x1fffa2b7, 0x5d3dbbb7, 0x9995fdbf, 0xd5d5dff4, 0xb87ebef9, 0xeeea397f, 0x2dabdfbb, 0xf3f58e9f, 0xfb3f6b1e, 0xf696e67f, 0xbfe47eab, 0xff3fe89c, 0xa3dce3ff, 0xaff5f725, 0x5ffc799b, 0x5d2ff75e, 0x2ffa67be, 0xb655efcf, 0xbbeab6eb, 0x6ace7ffc, 0x5fd6f7e1, 0xbdf3e4db, 0x9bd7fba6, 0x2bffed47, 0x2eaf1fdf, 0xb9f2677f, 0x0ed77ff6, 0x7edee1ee, 0xebde9d7a, 0xe72edfda, 0x79df7d39, 0xfed16fbc, 0x71f6be7b, 0xce87df9f, 0xccfbfaf4, 0xbfa9e3ed, 0xdd2ddbf9, 0xd4d9ddf7, 0x5dff8ead, 0xcecbf2fb, 0xc7fad7b9, 0x9d6cfded, 0x7ee735de, 0xcdf9fb3c, 0xde3d2ffa, 0xd8fcbe7e, 0x79fbb1ee, 0x5f672fbe, 0xdc9977bf, 0xfbf689ee, 0xbd74afed, 0xd525faff, 0x5f5cbbf3, 0xce1bbfaf, 0xe6cff35e, 0x99e7f776, 0xdf3f5d56, 0xf737b1fa },
    .{ 0x6ef9fbcb, 0x7bcffa1f, 0xf89fff78, 0xf7ecfb6c, 0xf3feb0fb, 0x96cff3ef, 0xff76ef4a, 0xc7e7ef5b, 0xdfeee9f2, 0xe67f5ebb, 0xf9fba71f, 0xadfb9daf, 0xff433ff9, 0xefdf037f, 0xffbc0dfb, 0xcfdfa9f5, 0xd6d5dfe7, 0xcdcff7f1, 0xae9fdcfd, 0xeb7edabb, 0x73fd46ff, 0x7ae6ff1f, 0xbaff557b, 0xe9e7f6fc, 0xdfcbeb9b, 0x6bfffe16, 0xeefadf3c, 0xb73e7e5f, 0x36e6ff7e, 0x770fdfbb, 0x9dbabff9, 0xfa6eb9bf, 0xfdf96db6, 0x9ed5f6fb, 0xb1cfffda, 0xa5f77fd3, 0x35aff3ef, 0x7abf3cfe, 0x4f93f9ff, 0x7fd7d3d9, 0xea87fff6, 0xecd7bcef, 0x5167fffd, 0xcdfdbdcd, 0xd7fef7a4, 0xf6bbdfc3, 0xef7eb4bb, 0xffe25f76, 0xfef5379e, 0x5d7ff9ea, 0xed9779fb, 0x3ef71f77, 0xd6c6dffb, 0x7fd71df5, 0x73bb7fe9, 0xdefde6ec, 0x37e79dfb, 0xfef7db29, 0xb9ebd9fd, 0x3e72f7f7, 0x7bf5ebba, 0x79f56f9f, 0xd57fbfe8, 0x1c7faffb, 0xfbae7de6, 0xf7529ffb, 0x2777fff4, 0xdfb7baae, 0x5b1fbf3f, 0x7fd175ef, 0x3f9cdf6f, 0xf871f7df, 0xede8fdf6, 0xd13bfef7, 0xe7fe73f4, 0x3a77fecf, 0xff675c7d, 0x77bfb66b, 0x4ff6fdcd, 0xfdbbea37, 0xd2df7df5, 0x7fe5a7d7, 0xdcffba75, 0xab7bed7d, 0x7ff76f07, 0xe7cffbd8, 0xff9b373b, 0xb37eefe9, 0xbeef79d6, 0x7f79ab9f, 0x6fd78fe7, 0xb56bdfbe, 0xfcf7dc9e, 0xb75edeb7, 0xfc6dfebc, 0xb759e7fb, 0x1fb1f77f, 0xbeebe1fb, 0xee3dfd2f, 0xfb6abd7e, 0x67ea7cff, 0xadfbcfcd, 0x7ebfff60, 0x9fcd767f, 0xce7fbf2d, 0xbcf3bf6e, 0x7bf763ee, 0xcf7cfe9e, 0xbdbff4b6, 0xf67deb6e, 0x5b6bcffe, 0xae6fbe3f, 0xf7373fd5, 0xbf953f5f, 0x96f5f7ee, 0x9fdfeea3, 0xfafb3db5, 0xff7bd8d9, 0x1fff3f59, 0xfeddd6ab, 0xfb6b4e7f, 0xf57e9d6f, 0x6df9df57, 0xffcef917, 0xffe1bbb5, 0xfbeb16df, 0x16ff77af, 0x5b9bff3d, 0x3e7d6ff5, 0x6fdf93cf, 0xb3f3ffa5, 0xbf8e95ff, 0xbedafceb, 0xfddb7d6a, 0x3b9e79ff, 0x7eef39be, 0x9ff6ca7f, 0x9f3ed1ff, 0xd557ef7b, 0x7ddbe73e, 0xc7d7deb7, 0x1eef6efe, 0x9f39bdfd, 0xf5b95fe7, 0xed47ffce, 0xff8cd7de, 0x7d753dfd, 0xf5feacf3, 0xf5bf2d6f, 0xf66dbede, 0x3fcfdfb1, 0x67edbdf3, 0x3db5fbdb, 0x9f67feec, 0xbd6f67bd, 0xba6fadfe, 0xb9fbfb4d, 0xf38d7efd, 0xdbdb5adf, 0xf276ff3b, 0xdeafeccf, 0xb6fb5ebb, 0xef9f1f9b, 0xdee72ddf, 0xdd45bfbf, 0xbc7fa3fe, 0x67d9ddef, 0xf73f7ea3, 0xaf7ff197, 0xecbfaa7f, 0xad7ff979, 0xddf79af5, 0xf4db5faf, 0xd9bdf9e7, 0x7fd6a6fb, 0xf9b3efea, 0x4ff31fdf, 0xc9ff7bb3, 0xbbbed76d, 0x5f7d67fc, 0xc7ef2ef7, 0x77eddf2e, 0xfb8fb6f9, 0xf7b3c3f7, 0xf6afa5fe, 0xfaa6fe9f, 0xfbb51bdf, 0xf1f99fee, 0xbbd35fcf, 0x5c7f8fef, 0xbf9f7e2e, 0xdf9ff327, 0x3befd3bb, 0xfe9bfc67, 0x7f32eaff, 0xf77bec8f, 0x9efd13ff, 0xdaabd7bf, 0xce7fbfd1, 0xff9d5c5f, 0xfd3e6b7d, 0xf5277faf, 0x4ffe7b2f, 0xafb779e7, 0x5786dfff, 0xc79cbdff, 0xc7bfed1f, 0xefdeeae9, 0xfde774af, 0xbfd6dfa9, 0xbff6a7ad, 0xdfbbf52b, 0x7dafc73f, 0xcdebd8ff, 0x7f17e7de, 0xfc3fdfd4, 0xbfcd7de5, 0x3f7bdbae, 0x6fabf77a, 0xd5bf36ef, 0xe6f76ddb, 0x7dfcbcbd, 0xb9bdbf7c, 0xeafef74e, 0x8fdede3f, 0xce6ffee5, 0xddb597fe, 0xf7d8fd67, 0xe67f373f, 0xb967dfcf, 0xbb5a7ff9, 0x62bfbffc, 0xc32f77ff, 0xe7efed8e, 0xb7afe7b5, 0xc777dbee, 0x2e3ff3bf, 0xdfaf79f4, 0xedc7def3, 0x9e77e8ff, 0xfb73787f, 0x9fd3bddb, 0x5f72fbed, 0x6effbf31, 0xe616feff, 0xcbff7ad6, 0x5fdebfb4, 0xfbe1bf37, 0xcff9bbec, 0x9f9fe71f, 0xdbfb1efc, 0x7f2df96f, 0xc77bbfea, 0xfe7efaa9, 0x7d06bfff, 0xef5e5e77 },
    .{ 0xebbf2ff3, 0x6f71fd7f, 0xfefefc53, 0x7ddda7df, 0xf3eeaedf, 0xd5d3fbfe, 0x39bf7eef, 0xe3d775ff, 0x9dfff13f, 0xe97fcdef, 0x5e1efffe, 0xdddf79cf, 0x6ff3fda7, 0x39fffafa, 0x5e9fef5f, 0xfcff8fd6, 0xefb77b3e, 0x9ffbf3f8, 0xf7b97f4f, 0xe57d7efb, 0x7ffcebae, 0xeffffa68, 0x3de9fef7, 0x9dabdfdf, 0xbeb6dfdb, 0x4ff7bef9, 0x69ff7fd9, 0x1ceffbfe, 0x8ffb7fcd, 0xbfbde4f7, 0xfcd39fef, 0xdfb3fdcb, 0xfbefeb8e, 0xf99fdef6, 0x6fbf377d, 0xef78dbef, 0x9f7f7dd6, 0xbfffe85d, 0x7bbbefad, 0xdffbb7ca, 0xeaff3ebd, 0x7ff677e3, 0xbe27ffed, 0xed8ff7bb, 0xad3df3ff, 0x9f5fff63, 0xbf4fd7de, 0xf7f7bee4, 0xff3b973f, 0xe5debeef, 0x7ff9be7a, 0xd7f4bbfd, 0xfabbddaf, 0xd64fff3f, 0xb9ff8dbf, 0x75cdbffd, 0xef375fbb, 0xedb7ddfa, 0xe3bfb5f7, 0x9f5bfd6f, 0xdb7bf6ee, 0xef7d9fb3, 0xf6bdecf7, 0xdf1eefeb, 0xabfbf9eb, 0x3f7ecff9, 0xbabfd3f7, 0xbd3fb6ef, 0xff3fb967, 0x3e7bfeeb, 0xefbf3af3, 0x83defffb, 0x7ebeda7f, 0xbcff7d5e, 0xf67edfd9, 0x5bdfdefa, 0xc5ff96ff, 0xffaee53f, 0xbffc3cfb, 0xbb8fff7a, 0xbf57fc77, 0xbfbff8d3, 0x9f5adfbf, 0xf76b79bf, 0x9cffd7bb, 0xf2befbe7, 0xddfed7d3, 0xef74dbf7, 0xdef7faf4, 0x7bef7f55, 0x76b77f7e, 0xb67cff3f, 0xd6fdfe6b, 0xdeb3eb7f, 0xbffe93af, 0xffcfd2dd, 0xef9e6def, 0x27ff9efd, 0xeefadbe7, 0xfd7be5be, 0x7e5f9efd, 0x7ebefdd3, 0xe2e7ff5f, 0x7fb7bb9d, 0x7bdf67d7, 0xef70dfef, 0x5f7f77b5, 0xedfe767e, 0xae5eff3f, 0xab1fff77, 0xffe4dfda, 0xcfe5ebbf, 0xedbe777e, 0xdde77fda, 0x3fcdfb77, 0xfbdadb9f, 0xd5fcfeee, 0x7fec73ef, 0xf7c77fc7, 0xf2f76ff5, 0x1fefd7be, 0xd7b9defe, 0xbffd72cf, 0xd5faaff7, 0x7ebfebd6, 0xbfbdf17e, 0xfbe2bf9f, 0x7fef1fec, 0xaff7d3eb, 0xf7fb9f69, 0x3f92fffd, 0xdeed6efd, 0xffea5f3e, 0x7fb7fc6e, 0xbeffe0ef, 0x3f79bf7e, 0xd72fffb5, 0xf9ff7e55, 0x7fafbef8, 0xf74ff6ed, 0xd6ffc777, 0xafdf4dbf, 0x9d6ff77e, 0xfcfde5eb, 0x1dd7bfef, 0x7fcfd95f, 0x1fffd7b6, 0xeb7e3bfd, 0xd73edf7d, 0xabebeefb, 0xf3dfae5f, 0xd3bf99ff, 0xfff98f3d, 0xefdff8ce, 0xfdef76ec, 0xfefeb3f4, 0x7f749ff7, 0xfdefd8b7, 0xbb77f9cf, 0xf5ce7fde, 0xe9ef5dbf, 0xdaefef79, 0xfd5daf7e, 0xf4efdbbe, 0xfeeb7b3e, 0xdef7fa6b, 0x9fede7de, 0xeffeb5d3, 0xfcf7eb3d, 0xfdbedabd, 0x776de3ff, 0xa7cbdffb, 0xdef3fdb6, 0xfba8dfbf, 0xb7f13bff, 0xdeabf7db, 0xcccffbfb, 0xffbddcae, 0xde77ffc6, 0xdc77f3f7, 0x73f79fbe, 0xddffe6f1, 0xfecf9ef6, 0xfd3f6d9f, 0xcffef8f6, 0xff3a3ffc, 0xf7deee3e, 0x3bbffb5e, 0xebbaf6fb, 0xfef66e77, 0xddcfeaef, 0x3fcdddfd, 0xfff46cfe, 0xfeffbb1a, 0xa4dfafff, 0xf6f36fee, 0xfbf34ff6, 0xf5e673ff, 0xebaf7aef, 0xb9b3f6ff, 0xae3ddffe, 0xfc76f1ff, 0x77e7ebaf, 0xbfbf9be3, 0xefeefc9b, 0xeee5f7f3, 0x3f7d5dfd, 0xddf7b9f9, 0x7ff7de1e, 0xeb6befed, 0xf69f77eb, 0xbf6f9ded, 0xd95fbddf, 0xd37ffabe, 0xbecd6dff, 0xeef5ef6b, 0xfef9bcfc, 0xed69fff9, 0xfff6d5ae, 0xdfaf36bf, 0x5dfbbfd6, 0xd3af7bef, 0xbb5fcef7, 0xddf5fe3d, 0xf9bb6fbd, 0xebef1fe7, 0xe3ff9fd3, 0xfdfed9cd, 0xefb3fb8f, 0xb93feffc, 0xdbfe9cbf, 0xadc7fefe, 0xf3fb775d, 0xddfeaf76, 0xff95ce7f, 0xde5faffc, 0x7efff0bb, 0xc7bebbfb, 0xe3ef5ff9, 0xdb3fddfc, 0xbb9f7dee, 0xfbdf96d7, 0xf5fadbbd, 0x7f37faee, 0xf4fddfd3, 0xfae77cfd, 0xbe87dfdf, 0x799fe7fd, 0xebebef6b, 0xbfd9f797, 0xc7feef5e, 0xb6efde3f, 0xefef89bf, 0xf5fbb72f, 0xef5cdaff, 0xdeafff6c },
    .{ 0xfdeaffe5, 0xd7fdfa3f, 0xbffaf9dd, 0xf733efef, 0xbf59f7f7, 0xf76dbeef, 0xbef97ff3, 0xbddeffce, 0xf765f77f, 0xfc79ff7d, 0xffff2eab, 0x6ffff9f1, 0xdfffd9ec, 0xdb3bff3f, 0x3b3effbf, 0xf9cefff3, 0xff7f476f, 0x7e9ff79f, 0xe7dfebdd, 0xbf7f7f39, 0xf7dbf6ee, 0xd72fffed, 0xbdfde3df, 0xfee5befe, 0x67fff7d3, 0xfba5fffc, 0xdefedcfe, 0xffdf56be, 0x7bfeafbd, 0x1eedff7f, 0xff6efd3b, 0xff7bded3, 0xedff8f9f, 0xe97f77fd, 0x6ffaddf7, 0xbfb7fa6f, 0xdf5dfbdb, 0xfb7debed, 0xf75ebf7e, 0xf7ebfbab, 0xfaff7adb, 0xcbf7ffd3, 0xdfff86fd, 0xffefbfb0, 0xfcf9bdfd, 0xb7fbebeb, 0xdfddefd9, 0xafeb7f7d, 0x8ff9ffb7, 0xfadf6def, 0x9faeef7f, 0xf5ffbed3, 0x7feedff8, 0xefdbe5fd, 0xafebbbf7, 0x7df7bf2f, 0x7bffc7fa, 0xb2effef7, 0xfdff479f, 0x3f7e77fe, 0xdf5bff79, 0xb7b27fff, 0xff7fce3b, 0xfee7dd6f, 0xdbeebefe, 0xdffeae6f, 0xffef07ef, 0x77ffdda7, 0xfedbbbbb, 0x8f7f5fef, 0xcfe9fdef, 0xf5fea7fb, 0xbbafaf7f, 0x9f6afffd, 0xe3ffbbb7, 0xfbfaffa5, 0xf7d6fb6f, 0xdf7cfafb, 0x7e77f7dd, 0xe7fb4fef, 0xfde3bfbe, 0xfef99fe7, 0x55defffe, 0x7efe77be, 0xfd79fddb, 0xfff9df9c, 0xf66dfdbf, 0x9fcbffbd, 0x7cf7fbed, 0x3bfbb7f7, 0xffed7adb, 0xff7b77b5, 0x7f3f7f9d, 0xcf3f7bfd, 0xf7fbf2af, 0xedbff7c7, 0xfbbebd77, 0xf6a77ffd, 0xbf7d3ff9, 0x3fdbffd3, 0xff53ddfb, 0xf5dfe6df, 0x9fffbcbb, 0xfefcb67f, 0xeffcf73e, 0x2eff37ff, 0x7effe7ab, 0xf3ff9f5b, 0x9bbf3bff, 0xfb9feddd, 0xbfbecdbf, 0xbfb7e5fd, 0xcfedff7a, 0xcbfffaee, 0x9ffdbeaf, 0xe1ffedfd, 0x7fadf6f7, 0x7de73fef, 0x7bedfef6, 0x6dffdb7d, 0xfedfa7db, 0xb9bdfefd, 0xdcefdaff, 0x5ef3f5ff, 0xf799f7fd, 0xfefffc78, 0x9efffc7d, 0xfbdffb4b, 0x76febf6f, 0x3dbddfef, 0xffa757fb, 0xfefc9bbf, 0xbffbea77, 0xfe7eefd3, 0xdeffebd6, 0xfef6a3ff, 0xfadebddf, 0x9bfaffde, 0xebfffe39, 0xefc9fff6, 0xe4ff7efd, 0xff67f3d7, 0xddef9f7e, 0xfa7f55ff, 0xeaefe7fd, 0xdeadedff, 0xffca7def, 0xfdf6cfb7, 0xe3dfdbf7, 0xafff7adb, 0xb73b3fff, 0x3feffbf4, 0xf96fdbf7, 0x6ded7bff, 0xef7fa8ff, 0x7f3df7cf, 0xddff7f0f, 0x775dbbff, 0xf9ffe99f, 0xfebfbdf2, 0x7d3fafef, 0xed7f5f9f, 0xf9f7febc, 0xadfe76ff, 0x7dffceaf, 0xcfe7db7f, 0x7dfee2ff, 0xdf8fef6f, 0x7fafc9ff, 0xfbfbf376, 0xedcffbb7, 0x8b7dffbf, 0xbebbeb7f, 0xbd3ffedb, 0xffaffeb1, 0x7fb1fdef, 0xfdff1f7c, 0xf7f747bf, 0x9ffbcfbd, 0xf5b7fbde, 0xedef77fa, 0xf7ddfe7c, 0xfff66ff4, 0x7fcfddb7, 0xef5ddfbd, 0x7eaffb5f, 0xffd6ff66, 0xf7bbfe76, 0xef7d77cf, 0x7effdfc6, 0xafeaf6ff, 0xd5ebbfbf, 0xeffddf72, 0xf7fddeea, 0xeefb6dfd, 0xfddf1bfb, 0xd4fffcf7, 0xcf73ff7b, 0xfb4ffdeb, 0xdf7ebfd6, 0xfbf9fef2, 0x8cfbff7f, 0xfb5befed, 0xaef3fef7, 0x7f3fbdeb, 0xfd9ff6be, 0x737deffd, 0x1fdcffdf, 0xb7fd9f5f, 0x77e57ff7, 0xb7ffe1bf, 0x9bbff77b, 0xf7b3efee, 0xffff359e, 0xdfd7adfd, 0x7ebfbd7d, 0xf9afbaff, 0xffb7db37, 0xcff9f777, 0xff8fc7fe, 0xd8e7ffbf, 0xe77febde, 0x6f7ddffa, 0xaf79f7df, 0xfdab3fdf, 0xbbf1fddf, 0xbff9fe57, 0xd97efbdf, 0xfff2dd9f, 0xf5fe6ffa, 0x7fdfeeb6, 0xe6dfd3ff, 0xb7bfbfe9, 0x3dbf97ff, 0xbe77ffe3, 0x9f9bfffc, 0xb6efafdf, 0x9fb7efdb, 0xbdffebad, 0xeffaf5fc, 0xf8deedff, 0xb7eddfdd, 0x9dffcfdd, 0xfffcb2fb, 0xfb7bf775, 0xf7bb7bbe, 0xafefdfe6, 0x5ff2ebff, 0xff1ebf77, 0xeecffdbb, 0xcefbedf7, 0xfb7787ff, 0xedf7377f, 0xbcfdcdff, 0x6fe7f5f7, 0xb7db3dff },
    .{ 0xbfffbb57, 0xff5dfbfa, 0x7f3fbfdd, 0xfd97fff5, 0xfdce6fff, 0xffeae3ff, 0x7bffff9a, 0xbfafbefe, 0xfcfef9f7, 0xd9feff9f, 0xfadeb7ff, 0xf5fceffe, 0xfe5effbd, 0xfbf47f7f, 0xf9ffbdfc, 0xbafeff6f, 0xe3fefdfb, 0x9fffdedd, 0x77fbfbb7, 0xfbfefafa, 0xe9bfe7ff, 0x6ebefffe, 0x7dfefe5f, 0xefaf7faf, 0xedf37ffb, 0xfebdef5f, 0xebff5fd7, 0x3dfffbde, 0xcffceeff, 0x7ff67faf, 0xffdfae7b, 0xf7ffd97d, 0xf7ff93df, 0xfb6f9ffb, 0x7bfebbbf, 0xffdebbdd, 0xff9f95ff, 0xfff35efe, 0xedfaff7e, 0x79f6f7ff, 0xfed9fffa, 0xedddf7f7, 0xf7bffe4f, 0xf6deffbd, 0xffdfe4bf, 0xfff77fe4, 0xefeedfbd, 0xbffdffa3, 0x9dffef7b, 0x6fefbfee, 0xc7ffdbf7, 0xffecf7db, 0xbffffd99, 0xdafdf7fd, 0xecfdfddf, 0xfb1dfffe, 0x5b7eff7f, 0x3dfb7ff7, 0xf7bdefed, 0x7fdff6f3, 0xddf6ffd7, 0x3fefff5d, 0xfefdf78f, 0xfefff1bd, 0xebffdb9f, 0xdddfef7b, 0xfffd7cf9, 0x7dc7fffd, 0xf9efeefb, 0xeffec9ff, 0xeeffee77, 0xfdd7fbaf, 0xf7dfcdfe, 0xfcbbfebf, 0xf3df7bfe, 0x77fdefdd, 0xff6db3ff, 0xeefdf73f, 0x7fde7fed, 0xeeedfbf7, 0xffbcf9bf, 0xb7f67ffb, 0xdbddbfbf, 0xfbaff7af, 0xff6fdef9, 0x7ff5f67f, 0x5fff27ff, 0xfbff6fb6, 0xf9fbb7f7, 0xefdcdeff, 0xff77f53f, 0x3ff7ff6e, 0xffcd7e7f, 0xaf7e7eff, 0xff1ebdff, 0xedfdffb9, 0x7fdeedef, 0xfffd7af9, 0xcfefefcf, 0xbfb6f7bf, 0xef7dddfe, 0xedeebfdf, 0xfffb8eef, 0xf5fffb37, 0xe9fdf7df, 0xfdff73f5, 0xff5dfbcf, 0xbfffd6de, 0xbfbebfbe, 0x7ffcdf3f, 0xdffffdca, 0xfffdf3cb, 0xffd737f7, 0x6feeffe7, 0xeffefead, 0xfe6ebbff, 0xdabf6fff, 0xbefe3eff, 0xf7ff9edd, 0xff79e9ff, 0x7fffe57b, 0xffd5cfbf, 0x56f7ffdf, 0xfdfeedee, 0xfff5db7d, 0xbb37ffbf, 0xf7fff957, 0xbf7d67ff, 0x6ff7dff3, 0xff7ff95b, 0x36f7fffe, 0xdff56ff7, 0xfeefbbee, 0xfbefcff5, 0xd77cfffe, 0x7f5bfdef, 0xd77ebbff, 0xf7fcfd3f, 0xbcbcffff, 0xdfbafff5, 0xefeedaff, 0xf6ffebdb, 0xbfed7eef, 0xf7fbe9fb, 0x9fdfcff7, 0xbf7fbf73, 0xfd7bfdfc, 0xff4ef5ff, 0x7fff0dff, 0xb9f6fffb, 0xdfffd797, 0xfc7f9fef, 0xfaff7cbf, 0xf2edf7ff, 0xfaeddffb, 0xebbbfffc, 0x2ffdfebf, 0x1ffbfebf, 0x9f7fbedf, 0x7ebf5ff7, 0xd5ffbff5, 0x4f6f7fff, 0xf3bff6ef, 0xf67edbff, 0x7f67ffe7, 0xffdffc6d, 0xfff6efb6, 0xfff3f7e5, 0xfef77f3d, 0xbebfddfb, 0xabfff7be, 0xf7fbe73f, 0xfb7fccff, 0xfefbbefa, 0xff6d7cff, 0x7efdbedf, 0x7ff5fde7, 0xfdfcbf7e, 0xedffdbbd, 0x6efefdef, 0xf9dafffb, 0xfff7f9e9, 0xf7f67aff, 0xbfa7dbff, 0xafffd7dd, 0xafffbfae, 0xff77df5b, 0x33fff9ff, 0xff33f7ef, 0xbdcfff9f, 0xff6f7fda, 0xffb65ff7, 0xddeffcfb, 0x7f53fdff, 0xffcfaefb, 0xfe797dff, 0xfdd7ff9d, 0xfff5def9, 0xfb7d7efd, 0xd5d9ffff, 0xfff7cebb, 0x17bfdfff, 0xffbfec9f, 0xff8fdd7f, 0x7bfedff5, 0x9dd9ffff, 0x7e7fefbd, 0x6ecf7fff, 0xbefeffa7, 0xb6dffcff, 0x7dffebfa, 0x7ffed6f7, 0xddffebe7, 0xfff6f37b, 0xff37bbfe, 0xe7f7b5ff, 0xfa7f7dfd, 0xffe7cfe7, 0xfffaef5d, 0xc7fdffaf, 0x7d3fbf7f, 0xfe7bfb77, 0xfd77fdf6, 0xdde6feff, 0x5fdf7efb, 0xbe7fb3ff, 0xcffbf7be, 0x57bfffee, 0x7f5fddef, 0xfefbff3a, 0xfd9fdfbd, 0xdfbbf6fe, 0xfeefecfd, 0xfffd737e, 0xeff5efbe, 0xfde7effc, 0x7fbefe7d, 0xedfffef1, 0xfbaffe7e, 0xdf7f7fe9, 0xfdfffbaa, 0xcbfbffbd, 0xfbe7bbf7, 0xdedffe7b, 0xe27f7fff, 0xffedcdbf, 0xffecff79, 0x5fbf7f77, 0xf7efddbe, 0x71fffbbf, 0x75bfeeff, 0xfdf77bf3, 0xdffbfbd5, 0xfaff7afd, 0x6d7fff7e, 0xf7aebfdf },
    .{ 0x77f7ffee, 0xfffeedaf, 0xf7d7bfbf, 0xf7fdcf7f, 0x2fffef7f, 0xcbfedfff, 0xffefd777, 0xefb9fffe, 0xf7fdfbfa, 0xbff6efef, 0xfd9befff, 0xfb9fdfdf, 0xf7f77fcf, 0xe6ffdfdf, 0xed3ffffe, 0xcf77feff, 0xff3bf7fb, 0x9f77fffb, 0xfbffddeb, 0x76fbfffd, 0xeeff9fbf, 0xeffaffee, 0xfffdf7f1, 0xbf77fef7, 0xffafdfe7, 0x35bfffff, 0xbff7befd, 0xfdb9ffef, 0xff4befff, 0xffea6fff, 0xbdff7fd7, 0xfdfafdfe, 0xf7cfdfbf, 0xfbfefe7d, 0xfdfafffc, 0xffbffef4, 0xfbf7fbeb, 0xef9efbff, 0xfffbb6fe, 0xdfdfdbfd, 0xfb7ebffb, 0xff7f7b7e, 0xffe7f3fd, 0xedff7dbf, 0xf6ffdfee, 0xf73efdff, 0xff5ff9df, 0xffff34ff, 0xfbff9ffc, 0x5effb7ff, 0xefa7ffef, 0xc7dff7ff, 0xf7dfeebf, 0xffdbf6fe, 0xfdbfb6ff, 0xf7ff3dfe, 0x76f7fffd, 0x7ff7bdf7, 0xfffbef37, 0xaff67fff, 0xfaffbcff, 0xf7bfaeff, 0xcffbfcff, 0xfbf7bdfe, 0x7dfb3fff, 0xfe7ff8ff, 0xfffcffda, 0xbedfff77, 0x7def7fdf, 0xffffd779, 0x77feff7d, 0xdbfffdcf, 0xfeefbefe, 0xeefbffdd, 0xf17ffbff, 0xfeefafdf, 0xfbff7df5, 0xdfffff9c, 0xfffeecdf, 0xe6fdffbf, 0xffff7fe8, 0xbfdfdfee, 0xf77cfdff, 0xeeeff7bf, 0xfaffecff, 0xfadf7ffd, 0xf5bf7ffd, 0xdff7ffd9, 0x9fefff9f, 0xfff7ff78, 0xfd7fdf7d, 0xeffddeef, 0xfd9fbff7, 0xf7fefedd, 0xfbfdff57, 0xfbdf79ff, 0xffbffe5e, 0xfdff3ddf, 0xb7fbff9f, 0xdffdffcb, 0xffbf3ef7, 0xfaffdf7b, 0x7e7f7fdf, 0xdfbb3fff, 0x3beffbff, 0x6fcfffbf, 0xbfdbdeff, 0xcfbfffe7, 0xabfcffff, 0xdfbf37ff, 0xf3efbfef, 0xbeffaeff, 0xfffe5f3f, 0xfe3ffd7f, 0xff77bdf7, 0xbfef9f7f, 0xbf5f7f7f, 0x7ffdbd7f, 0x9ddf7fff, 0xbff7dbef, 0xd7ff5fbf, 0xf9fdfbfe, 0x5ffbbbff, 0xf3ff6eff, 0xdbfdfff3, 0xf7ff33ff, 0xfe3dffef, 0x77ebbfff, 0xff2fdfdf, 0xffdf7fb3, 0xffd7ff3d, 0xfffbf7f1, 0xffdddfdb, 0xfbfcafff, 0xffd95fff, 0x7f6dffbf, 0xbbfcf7ff, 0xfffbf5d7, 0xfffd7bde, 0xe7ffdddf, 0xfdbeffdd, 0xfbedfff5, 0xebfffeeb, 0xbff7cbff, 0x7fdb7ffe, 0xf9f7ef7f, 0x5fff3eff, 0xefeeafff, 0xaf7bfffe, 0xff27fffb, 0xefeef3ff, 0xf57efeff, 0x6fed7fff, 0x9dfe7fff, 0xfddfbfbe, 0xefbddfdf, 0xfef7bff6, 0xff7d7eef, 0xf6efff7b, 0xbfefedef, 0xffb6fdbf, 0x7fe7feef, 0xbdfcfdff, 0xedfffa7f, 0xffe77ff5, 0xedfbf3ff, 0x7fe1ffff, 0xdbfdb7ff, 0xbffb7ffc, 0xdd7cffff, 0x7ffefbe7, 0xebffc7ff, 0xefffdf6e, 0x7ffefbb7, 0xbbfeffed, 0xff9f7fed, 0xf7bfedfb, 0xbaff5fff, 0xffdbfeed, 0xbfbddfef, 0xebfdcfff, 0xfff7ce7f, 0xfb77eff7, 0xfebd7ffd, 0xf7fe97ff, 0xffcfe77f, 0x0fdfffff, 0xfbbbfbfb, 0xfeebffdd, 0xef73bfff, 0xf79dbfff, 0xebdffebf, 0xb7bfff9f, 0xbf79feff, 0xfffbffd4, 0xdfbdf3ff, 0xcff5ffbf, 0xffbb77f7, 0x9dfff7fd, 0xdfff7ef3, 0xeb7fdffe, 0xffe7affd, 0xff7ef5fd, 0x77fbfbfd, 0x5fffeff5, 0xb3ffbffe, 0xffe5fffa, 0xff59efff, 0xfdf6feef, 0xeabffbff, 0x3ffeffbd, 0xfeff5fdd, 0x7efd7fbf, 0xf35ffffe, 0xbafff7ef, 0xebdfcfff, 0xffebf6fd, 0xfbdf7fbd, 0xdfeff77e, 0x26ffffff, 0xafdd7fff, 0xff9fbfed, 0xfff77f79, 0xeffbfbbd, 0x7bffddfd, 0xceff7f7f, 0xfb7f77df, 0xd7fbf3ff, 0xfeebf3ff, 0xff7f9bfd, 0xffdd7fee, 0xffdabeff, 0xebeffe7f, 0xfcffebef, 0x7dff7f77, 0x7fefdf7d, 0xfbf6fdfb, 0xdffbf67f, 0xedbbefff, 0x7deffedf, 0x73f7fffe, 0x97d7ffff, 0xf76fefdf, 0x9d7fffbf, 0xbbf77eff, 0xdbdfff9f, 0xfb7ff7dd, 0xdefff7fc, 0xf5ffbfdd, 0x9effeeff, 0xd7fdfeef, 0x7ff76f7f, 0xcffffd5f, 0xff77efeb, 0xfd3fddff, 0xf1dfdfff },
    .{ 0x7efff7bf, 0xfffededf, 0xffff5f9f, 0x7ffddeff, 0x6ffffb7f, 0xfffe7faf, 0xfffffbda, 0x7fffbfbb, 0xfffbff4f, 0xdf7efdff, 0xfffbe7f7, 0x7fffefcf, 0xffff67df, 0xfbeffe7f, 0x7ffffdeb, 0xffebfbfe, 0xffefbdef, 0xcffbfffe, 0xfeff7efe, 0xfff8feff, 0xfdfdfbfe, 0xeffdffaf, 0xfff7fbf6, 0xffee7eff, 0xf7ffddbf, 0xfddffb7f, 0xfffaafff, 0xfffff6f5, 0xffffdf79, 0xfdfbeffe, 0xcfffffdd, 0x7bfefff7, 0xffffeef9, 0x5ffdfbff, 0xd7ffff6f, 0xffdf5ff7, 0xdefffbfb, 0xffddff77, 0xfdbfe7ff, 0xefdfffd7, 0x3fdff7ff, 0xd7f7fffd, 0x7f7f7bff, 0xfefffd9f, 0xf97fffef, 0x6fffffdb, 0xfbfdfffa, 0xdfffcfdf, 0xffbfdff3, 0x7ffffff4, 0xa5ffffff, 0xffebefef, 0xddffbfef, 0xfdeeefff, 0xff9ffff9, 0x9fbfffdf, 0xfef3fffd, 0xfbe7ffbf, 0xdff7f7bf, 0x77effeff, 0xffdf3f7f, 0x36ffffff, 0xfffa77ff, 0xffffe5df, 0xffefeefb, 0xefef9fff, 0x9ffffff5, 0xf7bff7bf, 0xff6ffdfb, 0xffff3fb7, 0xfdfdafff, 0xfbfdff7e, 0xffffb77e, 0xcfffffdb, 0xfefdfddf, 0xfe7feff7, 0xffecdfff, 0xf7ffb9ff, 0x9ffbbfff, 0xbff7ff3f, 0x7bffddff, 0x7fdf7fdf, 0xfdfe7f7f, 0xfdfb5fff, 0xff7f9dff, 0x7fbffe7f, 0xf7ff7eef, 0xfff7f9bf, 0xefeff3ff, 0xfeffb5ff, 0xff7fbf5f, 0xbf7bffef, 0xffffe7dd, 0x7dffbdff, 0xdf7f7dff, 0xff7eedff, 0xfff7f7bb, 0x7bfffdfd, 0x7bffffd7, 0xfffeffe3, 0xfb7fbfdf, 0xffbedffe, 0xbbff7ffd, 0xfffdbf6f, 0xe7efffef, 0xfeff7bfd, 0xffde77ff, 0x7ff6ffbf, 0xfff3ffdd, 0xfffbeff9, 0xffd7faff, 0xfffeebbf, 0x6f7ffffd, 0xffbbfbfd, 0xfefffbd7, 0xfcffef7f, 0xfff5ff5f, 0xeffff7d7, 0xfbfff6df, 0xfffb7cff, 0xffb9ffdf, 0xbfbf7ffe, 0xf9ff5fff, 0xff4ff7ff, 0xff5fff7d, 0x7bffff5f, 0xfbff7f77, 0xf7fff7bd, 0xdffebeff, 0xff7efddf, 0x7ddfffef, 0xefeefeff, 0xfbfbfd7f, 0xffffbf79, 0xfeff77fd, 0xfdb3ffff, 0xf5fff7f7, 0xf7fffde7, 0xffff3bbf, 0xfffffdd6, 0xff7fbef7, 0xfef75fff, 0xfb7f7dff, 0xf777f7ff, 0xffedff7b, 0x6ffffeef, 0xfffb6eff, 0xaffffbef, 0xdfffeefb, 0x5fffddff, 0xfbbffdfd, 0xfecff7ff, 0xeff7dbff, 0xfbffb9ff, 0xefebffbf, 0xf77f5fff, 0xbfbffefd, 0xf9fffbf7, 0xfef9bfff, 0xbffdfbbf, 0xff9bfbff, 0xf9ffebff, 0x7bffebff, 0xfdffdbf7, 0xffdfdbfd, 0xbfffd7bf, 0xfd5effff, 0xf5fdbfff, 0x7ffefebf, 0xfdb7fffd, 0xfdbffefb, 0x7dfffe7f, 0xf6effffd, 0xfff37ffd, 0xefffafdf, 0xef7fbf7f, 0xb6ffbfff, 0xfd7feffe, 0xfffbebfb, 0xdffeff7d, 0xbfbffbbf, 0x7ffdfcff, 0x7dffffde, 0xf7cffdff, 0xeffbfeef, 0xedfdffef, 0xfbdfeeff, 0xedeffbff, 0xf7bf7bff, 0xff3bffef, 0xfb7df7ff, 0x7ffe9fff, 0xfffef77d, 0xfffff6e7, 0xfff6fdef, 0xfdff5fef, 0xdf7ffffa, 0xddefffdf, 0xfdffdbfd, 0xf7ffffb6, 0xbfd7efff, 0xff3dfdff, 0xfcfffebf, 0xbdffff9f, 0xfcbffbff, 0xff77fbf7, 0xf37fdfff, 0xeffffcfb, 0x5fefffbf, 0xedff9fff, 0xbfcff7ff, 0xffeffb9f, 0x7ff6ffef, 0xffff76fe, 0xfdbb7fff, 0xddfffbbf, 0xfff7b9ff, 0xffb7fff6, 0xfffd6ffd, 0xffffefcb, 0xb7ffffeb, 0xfb7ffbef, 0xf3ffdffb, 0xfffbf3fd, 0xfffbff3d, 0xf7ff9ff7, 0xffbfbf3f, 0xfef7bfef, 0xffff5f7e, 0xffefddef, 0xef6fefff, 0xeffeebff, 0x7ffeefdf, 0xff7fb7fb, 0x7ffffff1, 0xff5fbfbf, 0xffffefd6, 0x7f6fffef, 0xfbfdef7f, 0xfbffeaff, 0xfeffddef, 0x3feffffd, 0xffed3fff, 0x5fff7bff, 0xfffd7f7b, 0xdfef7ffb, 0xffdbfefe, 0xf7efe7ff, 0xebfffcff, 0xfbf37fff, 0xfbfafff7, 0xfbeff5ff, 0xfe7fff3f, 0xfddffff5, 0xfdbfbff7, 0xbffbfbdf },
    .{ 0x7ff9ffff, 0xbffffebf, 0xfffdcfff, 0xff7bfbff, 0x9effffff, 0xeffbfeff, 0xfdf3ffff, 0xbf7ffffb, 0xffe3ffff, 0xbfffffbe, 0x7fbffffd, 0xffffff97, 0xffbfffe7, 0xffff79ff, 0xfbfefffd, 0xffedffdf, 0xfff3fbff, 0xfbfefffd, 0xfd7ffffd, 0xdffefdff, 0xfff7ffde, 0xffeff77f, 0xdffffbfb, 0xff77fbff, 0xffdfdffb, 0xfbdffffe, 0x3fffffbf, 0xffefd7ff, 0xff7ffe7f, 0xfff7ffde, 0xfdfff7fe, 0xf6fbffff, 0xfffcfdff, 0xfffeffde, 0xfefbffbf, 0xf3ffffdf, 0xfbfff7fd, 0xff7fffaf, 0xfbafffff, 0x7dfeffff, 0xfffef7fe, 0xffdfb7ff, 0xf7f7ffbf, 0xfff7fe7f, 0xffffb5ff, 0x7ffffdf7, 0xffbffe7f, 0xdfffdffe, 0x3fffffbf, 0xffffff97, 0xffffdfe7, 0xfdffffe7, 0xaffeffff, 0xffdfb7ff, 0xdfffcfff, 0xffdfdfbf, 0x7dffff7f, 0x7ff9ffff, 0xfff77f7f, 0xefbf7fff, 0x7dfffbff, 0x7ff7f7ff, 0xffffdefb, 0xfff3fdff, 0xffe3ffff, 0xf7febfff, 0xfefb7fff, 0xffffff5d, 0xfbdbffff, 0xfdff7bff, 0xff7bfbff, 0x5fff7fff, 0xf7fddfff, 0xf7dfffdf, 0x5fff7fff, 0xf5fffffe, 0xffbfffe7, 0xffefeff7, 0xfffdcfff, 0xfffcfdff, 0xf7fddfff, 0x7effdfff, 0xfdff7bff, 0x7ffbfeff, 0xfdff7bff, 0xfbfebfff, 0xfff9f7ff, 0xfffdffcf, 0xfffeeffb, 0xfd7ffffd, 0xdbffffbf, 0xf7fddfff, 0xfffcffef, 0xffedffdf, 0xfffeeffb, 0xbfff7ffb, 0xff77fbff, 0xffffff5d, 0xffdfdfbf, 0xaffffffe, 0xefff7dff, 0xffffdfe7, 0x7ffbfeff, 0xdffffbfe, 0xffdfdfbf, 0xfdfff7fe, 0xfffcefff, 0xfdf3ffff, 0xffff7efd, 0xfdffff7b, 0xfffcffef, 0xdbfdffff, 0xffeff7bf, 0xffdffbfd, 0xffbbff7f, 0xfffcfdff, 0x7dfeffff, 0xfffdb7ff, 0xfffcffef, 0x7ff7f7ff, 0xfffdffcf, 0xffeff7bf, 0xff77fbff, 0xffbbff7f, 0xff7eff7f, 0xfbfbffef, 0xf7febfff, 0xfbdffffe, 0xaffffffe, 0xfff3fdff, 0xdfffcfff, 0xdffffbfb, 0xffffffe6, 0xffbfffe7, 0xfffd7eff, 0xfff3fbff, 0xdbfffdff, 0x7ffbfeff, 0xfdffdfbf, 0xfffffebd, 0xff7bfbff, 0xfffd7eff, 0xeddfffff, 0xbffffebf, 0xffefbfbf, 0xff7eff7f, 0xfefb7fff, 0xfff77f7f, 0xffefbfbf, 0xffe3ffff, 0xffbbff7f, 0xdbfdffff, 0xfffdcfff, 0xffbfeffd, 0xbfffffbe, 0xfefffff6, 0xfff7fe7f, 0xfffecfff, 0xfffdffcf, 0xbfdff7ff, 0xfff6ffdf, 0x3fffffbf, 0xbfffffbe, 0xfbdbffff, 0xbfdff7ff, 0xfffcffef, 0xffdffbbf, 0xdfffdffe, 0xffffffe6, 0xf7f7ffbf, 0xdfffeff7, 0xffffdfe7, 0xffdf7fdf, 0xffff79ff, 0xff7ffd7f, 0xdffffbfb, 0xff7f7ffe, 0x3fffffbf, 0x7ff7f7ff, 0xfdffffe7, 0xffefeff7, 0xf7febfff, 0xbfff7ffb, 0x7ffffdf7, 0xfbfefffd, 0xff7df7ff, 0xffdfffdd, 0xfbfefffd, 0xfbfefffb, 0xf7febfff, 0x7ffbfeff, 0xdbfdffff, 0xff7ffe7f, 0xff7fffaf, 0xf7fddfff, 0xdfffff77, 0xffbf77ff, 0xfffdcfff, 0xfbfebfff, 0xfff9f7ff, 0xffefeff7, 0xfffef7fe, 0xfff6ffdf, 0xffffff5d, 0xffbf77ff, 0xfbbffffb, 0xdfdfffdf, 0xffbf77ff, 0x7ffffdf7, 0xffeff77f, 0xfffdbfef, 0x7ff7fbff, 0x7ff9ffff, 0xbfdff7ff, 0xfbafffff, 0xffd7fffb, 0xff6fffdf, 0xaffeffff, 0xbffaffff, 0xf6fbffff, 0x3fffffbf, 0xfffeeffb, 0xfffeeffb, 0xfffecfff, 0xfff3fbff, 0xfff7fe7f, 0xfbdffffe, 0xfffcefff, 0xffbfffe7, 0xfffffb7b, 0xfbbffffb, 0xffffff5d, 0xdffefffe, 0x7fbffffd, 0x7dfffbff, 0xffdfffbe, 0xbf7ffffb, 0xbfffffbe, 0xeffbfeff, 0xf7f7ffbf, 0xbfdff7ff, 0xdbffffbf, 0xfdfff7fe, 0xffffdfe7, 0xefffdffd, 0xfefb7fff, 0xffff5ff7, 0xfdffffe7, 0xffbffe7f, 0xbf7ffffb, 0x7fbffffd, 0xfffdcfff, 0xffff79ff, 0xffdf7fdf, 0x9effffff, 0xbfff7ffb },
    .{ 0xfeefffff, 0xfffffbef, 0xfffff6ff, 0xfeefffff, 0xfffff7bf, 0x7ffeffff, 0xfffffd7f, 0xfffff6ff, 0xfeefffff, 0xff7f7fff, 0x7ffeffff, 0xfffffd7f, 0xffffdffd, 0xfffffd7f, 0xfeefffff, 0xfffff6ff, 0xfff7fffd, 0xfffffbef, 0xfeefffff, 0xeffffdff, 0xfffffd7f, 0xbfffbfff, 0xffcfffff, 0xfeefffff, 0xffbffffe, 0xffcfffff, 0xfeefffff, 0xfff7fffd, 0xffcfffff, 0xff7f7fff, 0xfffff6ff, 0xfffffbef, 0xffffdffb, 0xffcfffff, 0x7ffeffff, 0xfffffbef, 0xffffbfdf, 0xffffdffb, 0xfffff6ff, 0xbfffbfff, 0xfffffd7f, 0xffffdffd, 0xfeefffff, 0xffffdffb, 0xfeefffff, 0xeffffdff, 0xff7f7fff, 0xbfffbfff, 0xffffdffd, 0xffffdffb, 0xfffff6ff, 0xffffdffb, 0xff7f7fff, 0xffffdffd, 0x7ffeffff, 0xbfffbfff, 0xfffffbef, 0xfffff6ff, 0xfffffefd, 0xffffbfdf, 0x7ffeffff, 0xbfffbfff, 0xfffffd7f, 0xbfffbfff, 0xffffdffb, 0xfeefffff, 0x7ffeffff, 0xfffff6ff, 0xfffff7bf, 0xffffdffd, 0xfffffbef, 0xffffbfdf, 0xffffdffb, 0xbfffbfff, 0xfffffefd, 0xbfffbfff, 0xffffbfdf, 0xfff7fffd, 0xfffffbef, 0xffffdffd, 0xeffffdff, 0xfeefffff, 0x7ffeffff, 0xffbffffe, 0xfffffd7f, 0xfeefffff, 0xffcfffff, 0xfffff7bf, 0xffcfffff, 0xfffffd7f, 0xff7f7fff, 0xfffff7bf, 0xfffffbef, 0xbfffbfff, 0xfffffefd, 0xffffdffd, 0xfffffefd, 0xfeefffff, 0xffffdffb, 0xffffdffb, 0xfffffbef, 0xbfffbfff, 0xfffffd7f, 0xffffdffd, 0xeffffdff, 0xfffff7bf, 0xfffff6ff, 0xffffbfdf, 0xffffdffd, 0xfeefffff, 0xbfffbfff, 0xfffffefd, 0xfffff7bf, 0xfffff6ff, 0xffffbfdf, 0xffffdffb, 0x7ffeffff, 0xff7f7fff, 0xffffbfdf, 0xfff7fffd, 0xffffdffd, 0xffffdffb, 0xfffff6ff, 0xbfffbfff, 0xffbffffe, 0xfffff7bf, 0xffffdffb, 0xbfffbfff, 0xfffffefd, 0xbfffbfff, 0xfffffefd, 0xfffffefd, 0xfffffbef, 0xfffffefd, 0xfeefffff, 0xffbffffe, 0xfffff7bf, 0xffffdffb, 0xfeefffff, 0xfffff7bf, 0xffffdffd, 0xeffffdff, 0xffffdffd, 0x7ffeffff, 0x7ffeffff, 0xfffffbef, 0xfffff7bf, 0xfffffd7f, 0xfffffd7f, 0xffbffffe, 0xfffff7bf, 0x7ffeffff, 0xfffffefd, 0xffffdffb, 0xfff7fffd, 0xffffdffb, 0xfeefffff, 0xbfffbfff, 0xfffff6ff, 0xffffbfdf, 0xffffdffb, 0xfffffd7f, 0xfff7fffd, 0xfffffbef, 0xfffffbef, 0xffbffffe, 0xfff7fffd, 0xffffbfdf, 0xfffff7bf, 0xfffffd7f, 0xffffdffb, 0xbfffbfff, 0xffffbfdf, 0xfff7fffd, 0xeffffdff, 0xfffffbef, 0xfffff6ff, 0xffcfffff, 0xffbffffe, 0xfffff6ff, 0xfeefffff, 0xfffffbef, 0xfffffefd, 0xfeefffff, 0xbfffbfff, 0xfff7fffd, 0xfeefffff, 0xeffffdff, 0xfeefffff, 0xeffffdff, 0xffcfffff, 0xfffffbef, 0xffffdffd, 0xfffffd7f, 0xffffdffd, 0xbfffbfff, 0xffffbfdf, 0xeffffdff, 0xfffff7bf, 0xbfffbfff, 0xeffffdff, 0xfeefffff, 0xffffdffd, 0xfffff7bf, 0xffcfffff, 0xffffdffd, 0xff7f7fff, 0xbfffbfff, 0xffffdffd, 0xffffdffb, 0xffffdffb, 0xff7f7fff, 0xffffdffd, 0xfffff7bf, 0xffffdffd, 0xffcfffff, 0xfffffefd, 0xfff7fffd, 0xfffffd7f, 0xfffffefd, 0xff7f7fff, 0xffffbfdf, 0xfffffefd, 0xffcfffff, 0xfff7fffd, 0xfffffbef, 0xffffdffb, 0xfffff7bf, 0xffffbfdf, 0xffffbfdf, 0xff7f7fff, 0x7ffeffff, 0xffbffffe, 0xfffffd7f, 0xeffffdff, 0xffffbfdf, 0xff7f7fff, 0xfffffbef, 0xffbffffe, 0xffffdffd, 0xfffffd7f, 0xfffffd7f, 0xffcfffff, 0xbfffbfff, 0xfffffd7f, 0xffffdffb, 0xfff7fffd, 0xfeefffff, 0xffcfffff, 0xfffffd7f, 0xfffffbef, 0xfff7fffd, 0xfeefffff, 0x7ffeffff, 0xffcfffff, 0x7ffeffff },
    .{ 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff, 0xdfffffff },
    .{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff },
};
