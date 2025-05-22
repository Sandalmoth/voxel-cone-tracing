const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Input = @import("input.zig");
const Scene = @import("scene.zig");

const log = std.log;

pub const ticks_per_second = 83;
pub const tick: f32 = 1.0 / @as(f32, @floatFromInt(ticks_per_second));
pub const tick_ns: u64 = 1_000_000_000 / ticks_per_second;
pub const max_tick_ns: u64 = 250_000_000;

pub fn main() !void {
    var gpa_struct: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_struct.deinit();
    const gpa = gpa_struct.allocator();

    sdl.c.SDL_SetMainReady();

    if (!sdl.c.SDL_Init(sdl.c.SDL_INIT_VIDEO)) {
        log.err("SDL_Init: {s}", .{sdl.c.SDL_GetError()});
        return error.Sdl;
    }
    defer sdl.c.SDL_Quit();

    const window = sdl.c.SDL_CreateWindow(
        "voxel_cone_tracing",
        1920,
        1080,
        sdl.c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        log.err("SDL_CreateWindow: {s}", .{sdl.c.SDL_GetError()});
        return error.Sdl;
    };
    defer sdl.c.SDL_DestroyWindow(window);

    const gpu_device = sdl.c.SDL_CreateGPUDevice(
        sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
        true,
        null,
    ) orelse {
        log.err("SDL_CreateGPUDevice: {s}", .{sdl.c.SDL_GetError()});
        return error.Sdl;
    };
    defer sdl.c.SDL_DestroyGPUDevice(gpu_device);

    if (!sdl.c.SDL_ClaimWindowForGPUDevice(gpu_device, window)) {
        log.err("SDL_ClaimWindowForGPUDevice: {s}", .{sdl.c.SDL_GetError()});
        return error.Sdl;
    }

    var draw_pass = try DrawPass.init(gpa, gpu_device);
    defer draw_pass.deinit();
    var present_pass = try PresentPass.init(gpa, gpu_device, window);
    defer present_pass.deinit();

    var input = Input.init(gpa);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_W }, .forward);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_S }, .backward);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_D }, .right);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_A }, .left);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_SPACE }, .up);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_LCTRL }, .down);
    defer input.deinit();

    var scene = try Scene.init(gpa);
    defer scene.deinit();

    var frame_timer = try std.time.Timer.start();
    var lag: u64 = 0;
    var time: f64 = 0.0;

    frame_timer.reset();
    main_loop: while (true) {
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

        const command_buffer = sdl.c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse {
            log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };

        {
            draw_pass.begin(command_buffer);
            defer draw_pass.end(command_buffer);
        }
        try present_pass.run(window, command_buffer, draw_pass.backbuffer);

        if (!sdl.c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        }
    }
}

const DrawPass = struct {
    device: *sdl.c.SDL_GPUDevice,
    pipeline: *sdl.c.SDL_GPUGraphicsPipeline,
    render_pass: ?*sdl.c.SDL_GPURenderPass,

    backbuffer: *sdl.c.SDL_GPUTexture,
    backbuffer_depth: *sdl.c.SDL_GPUTexture,

    fn init(
        alloc: std.mem.Allocator,
        device: *sdl.c.SDL_GPUDevice,
    ) !DrawPass {
        const vert_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/draw.vert.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(alloc, 1_000_000);
            defer alloc.free(bytes);

            const create_info = sdl.c.SDL_GPUShaderCreateInfo{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_VERTEX,
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 1,
            };
            break :blk sdl.c.SDL_CreateGPUShader(device, &create_info) orelse {
                log.err("SDL_CreateGPUShader: {s}", .{sdl.c.SDL_GetError()});
                return error.Sdl;
            };
        };
        defer sdl.c.SDL_ReleaseGPUShader(device, vert_shader);

        const frag_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/draw.frag.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(alloc, 1_000_000);
            defer alloc.free(bytes);

            const create_info = sdl.c.SDL_GPUShaderCreateInfo{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_FRAGMENT,
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 0,
            };
            break :blk sdl.c.SDL_CreateGPUShader(device, &create_info) orelse {
                log.err("SDL_CreateGPUShader: {s}", .{sdl.c.SDL_GetError()});
                return error.Sdl;
            };
        };
        defer sdl.c.SDL_ReleaseGPUShader(device, frag_shader);

        const vertex_buffer_descriptions = [_]sdl.c.SDL_GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = @sizeOf(Scene.Vertex),
            .input_rate = sdl.c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        const vertex_attributes = [_]sdl.c.SDL_GPUVertexAttribute{ .{
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

        const color_target_descriptions = [_]sdl.c.SDL_GPUColorTargetDescription{.{
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .blend_state = .{},
        }};
        const depth_stencil_format = if (sdl.c.SDL_GPUTextureSupportsFormat(
            device,
            sdl.c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
            sdl.c.SDL_GPU_TEXTURETYPE_2D,
            sdl.c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        )) sdl.c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT else sdl.c.SDL_GPU_TEXTUREFORMAT_D24_UNORM;
        const pipeline_create_info = sdl.c.SDL_GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
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
        const pipeline = sdl.c.SDL_CreateGPUGraphicsPipeline(
            device,
            &pipeline_create_info,
        ) orelse {
            log.err("SDL_CreateGPUGraphicsPipeline: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        const width = 1920;
        const height = 1080;
        const backbuffer = sdl.c.SDL_CreateGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        }) orelse {
            log.err("SDL_CreateGPUTexture: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUTexture(device, backbuffer);

        const backbuffer_depth = sdl.c.SDL_CreateGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = @intCast(depth_stencil_format),
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        }) orelse {
            log.err("SDL_CreateGPUTexture: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUTexture(device, backbuffer_depth);

        return .{
            .device = device,
            .pipeline = pipeline,
            .render_pass = null,
            .backbuffer = backbuffer,
            .backbuffer_depth = backbuffer_depth,
        };
    }

    fn deinit(pass: *DrawPass) void {
        sdl.c.SDL_ReleaseGPUTexture(pass.device, pass.backbuffer_depth);
        sdl.c.SDL_ReleaseGPUTexture(pass.device, pass.backbuffer);
        sdl.c.SDL_ReleaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn begin(pass: *DrawPass, command_buffer: *sdl.c.SDL_GPUCommandBuffer) void {
        const clear_color: sdl.c.SDL_FColor = .{ .r = 0.22, .g = 0.11, .b = 0.22, .a = 1.0 };
        const color_target_infos = [_]sdl.c.SDL_GPUColorTargetInfo{.{
            .texture = pass.backbuffer,
            .clear_color = clear_color,
            .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
            .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
        }};
        pass.render_pass = sdl.c.SDL_BeginGPURenderPass(
            command_buffer,
            &color_target_infos[0],
            color_target_infos.len,
            &.{
                .texture = pass.backbuffer_depth,
                .clear_depth = 1,
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
        );
        sdl.c.SDL_BindGPUGraphicsPipeline(pass.render_pass, pass.pipeline);
    }

    fn end(pass: *DrawPass, command_buffer: *sdl.c.SDL_GPUCommandBuffer) void {
        const render_pass = pass.render_pass.?;
        sdl.c.SDL_EndGPURenderPass(render_pass);
        _ = command_buffer;
    }
};

const PresentPass = struct {
    const PresentVertex = struct {
        position: [3]f32,
        texcoords: [2]f32,
    };

    const full_screen_quad = [_]PresentVertex{
        .{ .position = .{ -1, 1, 0 }, .texcoords = .{ 0, 0 } },
        .{ .position = .{ 1, 1, 0 }, .texcoords = .{ 1, 0 } },
        .{ .position = .{ 1, -1, 0 }, .texcoords = .{ 1, 1 } },
        .{ .position = .{ -1, 1, 0 }, .texcoords = .{ 0, 0 } },
        .{ .position = .{ 1, -1, 0 }, .texcoords = .{ 1, 1 } },
        .{ .position = .{ -1, -1, 0 }, .texcoords = .{ 0, 1 } },
    };

    device: *sdl.c.SDL_GPUDevice,
    pipeline: *sdl.c.SDL_GPUGraphicsPipeline,
    vertex_buffer: *sdl.c.SDL_GPUBuffer,
    sampler: *sdl.c.SDL_GPUSampler,

    fn init(
        alloc: std.mem.Allocator,
        device: *sdl.c.SDL_GPUDevice,
        window: *sdl.c.SDL_Window,
    ) !PresentPass {
        const vert_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/present.vert.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(alloc, 1_000_000);
            defer alloc.free(bytes);

            const create_info = sdl.c.SDL_GPUShaderCreateInfo{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_VERTEX,
                .num_samplers = 0,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 0,
            };
            break :blk sdl.c.SDL_CreateGPUShader(device, &create_info) orelse {
                log.err("SDL_CreateGPUShader: {s}", .{sdl.c.SDL_GetError()});
                return error.Sdl;
            };
        };
        defer sdl.c.SDL_ReleaseGPUShader(device, vert_shader);

        const frag_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/present.frag.spv",
                .{ .mode = .read_only },
            );
            defer file.close();
            const bytes = try file.reader().readAllAlloc(alloc, 1_000_000);
            defer alloc.free(bytes);

            const create_info = sdl.c.SDL_GPUShaderCreateInfo{
                .code_size = bytes.len,
                .code = bytes.ptr,
                .entrypoint = "main",
                .format = sdl.c.SDL_GPU_SHADERFORMAT_SPIRV,
                .stage = sdl.c.SDL_GPU_SHADERSTAGE_FRAGMENT,
                .num_samplers = 1,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 0,
            };
            break :blk sdl.c.SDL_CreateGPUShader(device, &create_info) orelse {
                log.err("SDL_CreateGPUShader: {s}", .{sdl.c.SDL_GetError()});
                return error.Sdl;
            };
        };
        defer sdl.c.SDL_ReleaseGPUShader(device, frag_shader);

        const vertex_buffer_descriptions = [_]sdl.c.SDL_GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = @sizeOf(PresentVertex),
            .input_rate = sdl.c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        const vertex_attributes = [_]sdl.c.SDL_GPUVertexAttribute{ .{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .location = 0,
            .offset = @offsetOf(PresentVertex, "position"),
        }, .{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
            .location = 1,
            .offset = @offsetOf(PresentVertex, "texcoords"),
        } };

        const color_target_descriptions = [_]sdl.c.SDL_GPUColorTargetDescription{.{
            .format = sdl.c.SDL_GetGPUSwapchainTextureFormat(device, window),
            .blend_state = .{},
        }};
        const pipeline_create_info = sdl.c.SDL_GPUGraphicsPipelineCreateInfo{
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
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
        const pipeline = sdl.c.SDL_CreateGPUGraphicsPipeline(
            device,
            &pipeline_create_info,
        ) orelse {
            log.err("SDL_CreateGPUGraphicsPipeline: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        const vertex_buffer = sdl.c.SDL_CreateGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = 6 * @sizeOf(PresentVertex),
        }) orelse {
            log.err("SDL_CreateGPUBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        const transfer_buffer = sdl.c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = 6 * @sizeOf(PresentVertex),
        }) orelse {
            log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        defer sdl.c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

        const command_buffer = sdl.c.SDL_AcquireGPUCommandBuffer(device) orelse {
            log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };

        const bytes: [*]PresentVertex = @alignCast(@ptrCast(
            sdl.c.SDL_MapGPUTransferBuffer(device, transfer_buffer, true) orelse {
                log.err("SDL_MapGPUTransferBuffer: {s}", .{sdl.c.SDL_GetError()});
                return error.Sdl;
            },
        ));
        @memcpy(bytes, &full_screen_quad);
        sdl.c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

        const copy_pass = sdl.c.SDL_BeginGPUCopyPass(command_buffer);
        sdl.c.SDL_UploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, &.{
            .buffer = vertex_buffer,
            .offset = 0,
            .size = @sizeOf(PresentVertex) * 6,
        }, false);
        sdl.c.SDL_EndGPUCopyPass(copy_pass);

        if (!sdl.c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        }

        const sampler = sdl.c.SDL_CreateGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = sdl.c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        }) orelse {
            log.err("SDL_CreateGPUSampler: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUSampler(device, sampler);

        return .{
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .sampler = sampler,
        };
    }

    fn deinit(pass: *PresentPass) void {
        sdl.c.SDL_ReleaseGPUSampler(pass.device, pass.sampler);
        sdl.c.SDL_ReleaseGPUBuffer(pass.device, pass.vertex_buffer);
        sdl.c.SDL_ReleaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn run(
        pass: *PresentPass,
        window: *sdl.c.SDL_Window,
        command_buffer: *sdl.c.SDL_GPUCommandBuffer,
        backbuffer: *sdl.c.SDL_GPUTexture,
    ) !void {
        var swapchain_texture: ?*sdl.c.SDL_GPUTexture = null;
        var swapchain_width: u32 = 0;
        var swapchain_height: u32 = 0;
        if (!sdl.c.SDL_WaitAndAcquireGPUSwapchainTexture(
            command_buffer,
            window,
            &swapchain_texture,
            &swapchain_width,
            &swapchain_height,
        )) {
            log.err("SDL_WaitAndAcquireGPUSwapchainTexture: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        }
        const color_target_infos = [_]sdl.c.SDL_GPUColorTargetInfo{
            .{ .texture = swapchain_texture, .load_op = sdl.c.SDL_GPU_LOADOP_DONT_CARE },
        };
        const render_pass = sdl.c.SDL_BeginGPURenderPass(
            command_buffer,
            &color_target_infos[0],
            color_target_infos.len,
            null,
        );
        sdl.c.SDL_BindGPUGraphicsPipeline(render_pass, pass.pipeline);
        const vertex_buffers = [_]sdl.c.SDL_GPUBufferBinding{
            .{ .buffer = pass.vertex_buffer, .offset = 0 },
        };
        sdl.c.SDL_BindGPUVertexBuffers(
            render_pass,
            0,
            &vertex_buffers[0],
            vertex_buffers.len,
        );
        const sampler_bindings = [_]sdl.c.SDL_GPUTextureSamplerBinding{
            .{ .texture = backbuffer, .sampler = pass.sampler },
        };
        sdl.c.SDL_BindGPUFragmentSamplers(
            render_pass,
            0,
            &sampler_bindings[0],
            sampler_bindings.len,
        );
        sdl.c.SDL_DrawGPUPrimitives(render_pass, 6, 1, 0, 0);
        sdl.c.SDL_EndGPURenderPass(render_pass);
    }
};
