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

    try sdl.setWindowRelativeMouseMode(window, true);

    const device = try sdl.createGPUDevice(
        sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
        true,
        "vulkan",
    );
    defer sdl.destroyGPUDevice(device);

    try sdl.claimWindowForGPUDevice(device, window);

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

        const command_buffer = try sdl.acquireGPUCommandBuffer(device);

        {
            try draw_pass.begin(command_buffer);
            defer draw_pass.end();
        }
        try present_pass.run(window, command_buffer, draw_pass.color_target);

        try sdl.submitGPUCommandBuffer(command_buffer);
    }
}

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

    fn init(
        gpa: std.mem.Allocator,
        device: *sdl.GPUDevice,
    ) !DrawPass {
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
                .num_uniform_buffers = 0,
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
