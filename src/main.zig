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

    try sdl.claimWindowForGPUDevice(device, window);

    try sdl.setWindowRelativeMouseMode(window, true);
    if (sdl.windowSupportsGPUPresentMode(device, window, sdl.c.SDL_GPU_PRESENTMODE_MAILBOX)) {
        log.info("Swapchain composition set to mailbox", .{});
        try sdl.setGPUSwapchainParameters(
            device,
            window,
            sdl.c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
            sdl.c.SDL_GPU_PRESENTMODE_MAILBOX,
        );
    } else if (sdl.windowSupportsGPUPresentMode(
        device,
        window,
        sdl.c.SDL_GPU_PRESENTMODE_IMMEDIATE,
    )) {
        log.info("Swapchain composition set to immediate", .{});
        try sdl.setGPUSwapchainParameters(
            device,
            window,
            sdl.c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
            sdl.c.SDL_GPU_PRESENTMODE_IMMEDIATE,
        );
    }

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

    var draw_pass = try DrawPass.init(gpa, device);
    defer draw_pass.deinit();
    var present_pass = try PresentPass.init(gpa, device, window);
    defer present_pass.deinit();
    var voxelize_pass = try VoxelizePass.init(gpa, device);
    defer voxelize_pass.deinit();
    var sort_pass = try SortPass.init(gpa, device);
    defer sort_pass.deinit();

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

    var frame_timer = try std.time.Timer.start();
    var lag: u64 = 0;
    var time: f64 = 0.0;

    perf_counter.init(gpa);
    defer perf_counter.deinit();
    var perf_print_timer = try std.time.Timer.start();
    var frame_counter: u32 = 0;

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
            try voxelize_pass.end(command_buffer, &sort_pass);
        }
        {
            try draw_pass.begin(command_buffer);
            defer draw_pass.end();
            const vp_matrix = camera.vp(alpha);
            for (scene.objects.items) |object| draw_pass.drawObject(
                command_buffer,
                object,
                vp_matrix,
                alpha,
            );
        }
        try present_pass.run(window, command_buffer, draw_pass.color_target);

        try sdl.submitGPUCommandBuffer(command_buffer);
    }
}

const VoxelizePass = struct {
    const VoxelizationUBO = struct {
        model_matrix: [16]f32 align(16),
        normal_matrix: [16]f32 align(16),
        diffuse: [4]f32 align(16),
        emissive: [4]f32 align(16),
        roughness: f32 align(16),
        n_triangles: u32,
    };

    device: *sdl.GPUDevice,
    clear_pipeline: *sdl.GPUComputePipeline,
    voxelization_pipeline: *sdl.GPUComputePipeline,
    shading_pipeline: *sdl.GPUComputePipeline,

    sampler: *sdl.GPUSampler,
    voxelize_pass: ?*sdl.GPUComputePass,

    triangle_data_buffer: *sdl.GPUBuffer,
    triangle_list_buffer: *sdl.GPUBuffer,

    opacity_cascades: *sdl.GPUTexture,
    radiance_cascades: *sdl.GPUTexture,

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
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 1,
                .num_uniform_buffers = 0,
                .threadcount_x = 1,
                .threadcount_y = 1,
                .threadcount_z = 1,
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
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 2,
                .num_uniform_buffers = 1,
                .threadcount_x = 64,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, voxelization_pipeline);

        const shading_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/shading.comp.spv",
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
                .num_readwrite_storage_textures = 2,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 0,
                .threadcount_x = 4,
                .threadcount_y = 4,
                .threadcount_z = 4,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, shading_pipeline);

        const sampler = sdl.c.SDL_CreateGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        }) orelse {
            log.err("SDL_CreateGPUSampler: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUSampler(device, sampler);

        const triangle_data_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = 64 * 1024 * 1024,
        });
        errdefer sdl.releaseGPUBuffer(device, triangle_data_buffer);

        const triangle_list_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = 64 * 1024 * 1024,
        });
        errdefer sdl.releaseGPUBuffer(device, triangle_list_buffer);

        const opacity_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 8,
            .height = 66,
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, opacity_cascades);

        const radiance_cascades = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 66 * 8,
            .height = 66 * 6,
            .layer_count_or_depth = 66,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, radiance_cascades);

        return .{
            .device = device,
            .clear_pipeline = clear_pipeline,
            .voxelization_pipeline = voxelization_pipeline,
            .shading_pipeline = shading_pipeline,
            .voxelize_pass = null,
            .sampler = sampler,
            .triangle_data_buffer = triangle_data_buffer,
            .triangle_list_buffer = triangle_list_buffer,
            .opacity_cascades = opacity_cascades,
            .radiance_cascades = radiance_cascades,
        };
    }

    fn deinit(pass: *VoxelizePass) void {
        sdl.releaseGPUTexture(pass.device, pass.radiance_cascades);
        sdl.releaseGPUTexture(pass.device, pass.opacity_cascades);
        sdl.releaseGPUBuffer(pass.device, pass.triangle_list_buffer);
        sdl.releaseGPUBuffer(pass.device, pass.triangle_data_buffer);
        sdl.releaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUComputePipeline(pass.device, pass.shading_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.voxelization_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.clear_pipeline);
        pass.* = undefined;
    }

    fn begin(pass: *VoxelizePass, command_buffer: *sdl.GPUCommandBuffer) !void {
        const clear_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{.{ .buffer = pass.triangle_list_buffer, .cycle = true }},
        );
        sdl.bindGPUComputePipeline(clear_pass, pass.clear_pipeline);
        sdl.dispatchGPUCompute(clear_pass, 132, 99, 17);
        sdl.endGPUComputePass(clear_pass);

        pass.voxelize_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{
                .{ .buffer = pass.triangle_data_buffer, .cycle = true },
                .{ .buffer = pass.triangle_list_buffer },
            },
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
                .roughness = object.roughness,
                .n_triangles = n_triangles,
            },
            @sizeOf(VoxelizationUBO),
        );
        sdl.dispatchGPUCompute(
            pass.voxelize_pass.?,
            (n_triangles + 63) / 64,
            8,
            1,
        );
    }

    fn end(
        pass: *VoxelizePass,
        command_buffer: *sdl.GPUCommandBuffer,
        sort_pass: *SortPass,
    ) !void {
        sdl.endGPUComputePass(pass.voxelize_pass.?);
        pass.voxelize_pass = null;

        try sort_pass.sort(command_buffer, pass.triangle_list_buffer);

        const shading_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{
                .{ .texture = pass.opacity_cascades, .cycle = true },
                .{ .texture = pass.radiance_cascades, .cycle = true },
            },
            &.{},
        );
        sdl.bindGPUComputePipeline(shading_pass, pass.shading_pipeline);
        sdl.bindGPUComputeStorageBuffers(shading_pass, 0, &.{
            pass.triangle_data_buffer,
            pass.triangle_list_buffer,
        });
        sdl.dispatchGPUCompute(shading_pass, 132, 99, 17);
        sdl.endGPUComputePass(shading_pass);
    }
};

const SortPass = struct {
    device: *sdl.GPUDevice,

    dispatch_pipeline: *sdl.GPUComputePipeline,
    histogram_pipeline: *sdl.GPUComputePipeline,
    scan_a_pipeline: *sdl.GPUComputePipeline,
    // scan_b_pipeline: *sdl.GPUComputePipeline,
    scatter_pipeline: *sdl.GPUComputePipeline,

    dispatch_buffer: *sdl.GPUBuffer,
    histogram_buffer: *sdl.GPUBuffer,

    fn init(gpa: std.mem.Allocator, device: *sdl.GPUDevice) !SortPass {
        const dispatch_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/sort_dispatch.comp.spv",
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
                .num_readonly_storage_buffers = 1,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 1,
                .num_uniform_buffers = 0,
                .threadcount_x = 1,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, dispatch_pipeline);

        const histogram_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/sort_histogram.comp.spv",
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
                .num_readonly_storage_buffers = 1,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 1,
                .num_uniform_buffers = 1,
                .threadcount_x = 256,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, histogram_pipeline);

        const scan_a_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/sort_scan_a.comp.spv",
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
                .num_readonly_storage_buffers = 1,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 1,
                .num_uniform_buffers = 0,
                .threadcount_x = 256,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, scan_a_pipeline);

        // const scan_b_pipeline = blk: {
        //     const file = try std.fs.cwd().openFile(
        //         "data/shaders/sort_scan_b.comp.spv",
        //         .{ .mode = .read_only },
        //     );
        //     defer file.close();
        //     const bytes = try file.reader().readAllAlloc(gpa, 1_000_000);
        //     defer gpa.free(bytes);

        //     break :blk try sdl.createGPUComputePipeline(device, &.{
        //         .code_size = bytes.len,
        //         .code = bytes.ptr,
        //         .entrypoint = "main",
        //         .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
        //         .num_samplers = 0,
        //         .num_readonly_storage_textures = 0,
        //         .num_readonly_storage_buffers = 1,
        //         .num_readwrite_storage_textures = 0,
        //         .num_readwrite_storage_buffers = 1,
        //         .num_uniform_buffers = 0,
        //         .threadcount_x = 256,
        //         .threadcount_y = 1,
        //         .threadcount_z = 1,
        //     });
        // };
        // errdefer sdl.releaseGPUComputePipeline(device, scan_b_pipeline);

        const scatter_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/sort_scatter.comp.spv",
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
                .num_readonly_storage_buffers = 1,
                .num_readwrite_storage_textures = 0,
                .num_readwrite_storage_buffers = 2,
                .num_uniform_buffers = 1,
                .threadcount_x = 256,
                .threadcount_y = 1,
                .threadcount_z = 1,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, scatter_pipeline);

        const dispatch_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_INDIRECT |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = 1024,
        });
        errdefer sdl.releaseGPUBuffer(device, dispatch_buffer);

        const histogram_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ |
                sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = 64 * 1024 * 1024, // TODO take max number of sortable elements as parameter
        });
        errdefer sdl.releaseGPUBuffer(device, histogram_buffer);

        return .{
            .device = device,
            .dispatch_pipeline = dispatch_pipeline,
            .histogram_pipeline = histogram_pipeline,
            .scan_a_pipeline = scan_a_pipeline,
            // .scan_b_pipeline = scan_b_pipeline,
            .scatter_pipeline = scatter_pipeline,
            .dispatch_buffer = dispatch_buffer,
            .histogram_buffer = histogram_buffer,
        };
    }

    fn deinit(pass: *SortPass) void {
        sdl.releaseGPUBuffer(pass.device, pass.histogram_buffer);
        sdl.releaseGPUBuffer(pass.device, pass.dispatch_buffer);
        sdl.releaseGPUComputePipeline(pass.device, pass.scatter_pipeline);
        // sdl.releaseGPUComputePipeline(pass.device, pass.scan_b_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.scan_a_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.histogram_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.dispatch_pipeline);
        pass.* = undefined;
    }

    fn sort(pass: *SortPass, command_buffer: *sdl.GPUCommandBuffer, in_data: *sdl.GPUBuffer) !void {
        const dispatch_pass = try sdl.beginGPUComputePass(
            command_buffer,
            &.{},
            &.{.{ .buffer = pass.dispatch_buffer, .cycle = true }},
        );
        sdl.bindGPUComputePipeline(dispatch_pass, pass.dispatch_pipeline);
        sdl.bindGPUComputeStorageBuffers(dispatch_pass, 0, &.{in_data});
        sdl.dispatchGPUCompute(dispatch_pass, 1, 1, 1);
        sdl.endGPUComputePass(dispatch_pass);

        for (0..4) |i| {
            const histogram_pass = try sdl.beginGPUComputePass(
                command_buffer,
                &.{},
                &.{.{ .buffer = pass.histogram_buffer }},
            );
            sdl.bindGPUComputePipeline(histogram_pass, pass.histogram_pipeline);
            sdl.bindGPUComputeStorageBuffers(histogram_pass, 0, &.{in_data});
            sdl.pushGPUComputeUniformData(command_buffer, 0, &@as(u32, @intCast(i * 8)), 4);
            sdl.dispatchGPUComputeIndirect(histogram_pass, pass.dispatch_buffer, 0);
            sdl.endGPUComputePass(histogram_pass);

            const scan_pass = try sdl.beginGPUComputePass(
                command_buffer,
                &.{},
                &.{.{ .buffer = pass.histogram_buffer }},
            );
            sdl.bindGPUComputePipeline(scan_pass, pass.scan_a_pipeline);
            sdl.bindGPUComputeStorageBuffers(scan_pass, 0, &.{in_data});
            sdl.dispatchGPUCompute(histogram_pass, 1, 1, 1);
            sdl.endGPUComputePass(scan_pass);

            const scatter_pass = try sdl.beginGPUComputePass(
                command_buffer,
                &.{},
                &.{
                    .{ .buffer = pass.histogram_buffer },
                    .{ .buffer = in_data, .cycle = true },
                },
            );
            sdl.bindGPUComputePipeline(scatter_pass, pass.scatter_pipeline);
            sdl.bindGPUComputeStorageBuffers(scatter_pass, 0, &.{in_data});
            sdl.pushGPUComputeUniformData(command_buffer, 0, &@as(u32, @intCast(i * 8)), 4);
            sdl.dispatchGPUComputeIndirect(scatter_pass, pass.dispatch_buffer, 0);
            sdl.endGPUComputePass(scatter_pass);
        }
    }
};

const IndexPass = struct {};

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

    draw_pass: ?*sdl.GPURenderPass,
    color_target: *sdl.GPUTexture,
    depth_target: *sdl.GPUTexture,

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
                .num_samplers = 0,
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
        const color_target_descriptions = [_]sdl.GPUColorTargetDescription{.{
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .blend_state = .{},
        }};
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
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = window_width,
            .height = window_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.releaseGPUTexture(device, depth_target);

        return .{
            .device = device,
            .pipeline = pipeline,
            .draw_pass = null,
            .color_target = color_target,
            .depth_target = depth_target,
        };
    }

    fn deinit(pass: *DrawPass) void {
        sdl.releaseGPUTexture(pass.device, pass.depth_target);
        sdl.releaseGPUTexture(pass.device, pass.color_target);
        sdl.releaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn begin(
        pass: *DrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
    ) !void {
        const clear_color: sdl.FColor = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 };
        const color_target_infos = [_]sdl.GPUColorTargetInfo{.{
            .texture = pass.color_target,
            .clear_color = clear_color,
            .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
            .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
        }};
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

    fn end(pass: *DrawPass) void {
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
