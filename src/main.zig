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

    if (!sdl.c.SDL_SetWindowRelativeMouseMode(window, true)) {
        log.err("SDL_SetWindowRelativeMouseMode: {s}", .{sdl.c.SDL_GetError()});
        return error.Sdl;
    }

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

    var voxelize_pass = try VoxelizePass.init(gpa, gpu_device);
    defer voxelize_pass.deinit();
    var debug_voxel_draw_pass = try DebugVoxelDrawPass.init(gpa, gpu_device);
    defer debug_voxel_draw_pass.deinit();
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
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_TAB }, .toggle_debug_view);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_1 }, .prev_debug_view);
    try input.map.put(.{ .keyboard = sdl.c.SDL_SCANCODE_2 }, .next_debug_view);
    defer input.deinit();

    var debug_view: bool = false;

    var camera = Camera{
        .pos = zm.f32x4(0.0, 0.0, 0.0, 1.0),
        .yaw = 0.0,
        .pitch = 0.0,
        .prev_pos = zm.f32x4(0.0, 0.0, 0.0, 1.0),
        .prev_yaw = 0.0,
        .prev_pitch = 0.0,
    };

    var scene = try Scene.init(gpa, gpu_device);
    defer scene.deinit(gpa, gpu_device);

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
            camera.update(&input);
            if (input.peek(.toggle_debug_view).pressed) debug_view = !debug_view;
            if (input.peek(.next_debug_view).pressed) {
                const n_modes: u32 = @intCast(std.meta.fields(DebugVoxelDrawPass.Mode).len);
                const mode: u32 = @intFromEnum(debug_voxel_draw_pass.mode);
                debug_voxel_draw_pass.mode = @enumFromInt((mode + 1) % n_modes);
            }
            if (input.peek(.prev_debug_view).pressed) {
                const n_modes: u32 = @intCast(std.meta.fields(DebugVoxelDrawPass.Mode).len);
                const mode: u32 = @intFromEnum(debug_voxel_draw_pass.mode);
                debug_voxel_draw_pass.mode = @enumFromInt((mode + n_modes - 1) % n_modes);
            }
            for (scene.objects.items) |*object| object.update(tick);

            input.decay();
            lag -= tick_ns;
            time += 1.0 / @as(f64, @floatFromInt(ticks_per_second));
        }

        const alpha = @as(f32, @floatFromInt(lag)) / @as(f32, @floatFromInt(tick_ns));

        const voxelize_command_buffer = sdl.c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse {
            log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };

        {
            voxelize_pass.begin(voxelize_command_buffer);
            defer voxelize_pass.end(voxelize_command_buffer);
            for (scene.objects.items) |object| voxelize_pass.voxelizeObject(
                voxelize_command_buffer,
                object,
                alpha,
            );
        }

        if (!sdl.c.SDL_SubmitGPUCommandBuffer(voxelize_command_buffer)) {
            log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        }

        const command_buffer = sdl.c.SDL_AcquireGPUCommandBuffer(gpu_device) orelse {
            log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };

        if (!debug_view) {
            {
                draw_pass.begin(command_buffer);
                defer draw_pass.end(command_buffer);
                const camera_vp = camera.vp(alpha);
                for (scene.objects.items) |object| draw_pass.drawObject(
                    command_buffer,
                    object,
                    camera_vp,
                    alpha,
                );
            }
            try present_pass.run(window, command_buffer, draw_pass.backbuffer);
        } else {
            debug_voxel_draw_pass.run(
                command_buffer,
                &voxelize_pass.cascades,
                camera.v(alpha),
                camera.p(alpha),
            );
            try present_pass.run(window, command_buffer, debug_voxel_draw_pass.backbuffer);
        }

        if (!sdl.c.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        }
    }
}

const VoxelizePass = struct {
    const n_cascades = 8;

    const VoxelizeData = extern struct {
        model_matrix: [16]f32 align(16),
        normal_matrix: [16]f32 align(16),
        n_triangles: u32 align(16),
        ix_cascade: u32,
    };

    const AverageData = extern struct {
        ix_temporal: u32,
        ix_cascade: u32,
    };

    const LightingData = extern struct {
        ix_temporal: u32,
        ix_cascade: u32,
    };

    const Target = enum {
        weight_coverage,
        diffuse_emissive_r,
        diffuse_emissive_g,
        diffuse_emissive_b,
        normal_xy,
        normal_z_pad,
    };

    const Cascade = enum {
        coverage,
        diffuse,
        emissive,
        normal,
        radiance,
    };

    device: *sdl.GPUDevice,
    clear_pipeline: *sdl.GPUComputePipeline,
    voxelize_pipeline: *sdl.GPUComputePipeline,
    average_pipeline: *sdl.GPUComputePipeline,
    lighting_pipeline: *sdl.GPUComputePipeline,
    sampler: *sdl.GPUSampler,
    compute_pass: ?*sdl.GPUComputePass,

    targets: std.EnumArray(Target, *sdl.GPUTexture),
    cascades: std.EnumArray(Cascade, *sdl.GPUTexture),

    ix_temporal: u32,
    ix_cascade: u32,
    cascade_counter: i32,

    fn init(
        gpa: std.mem.Allocator,
        device: *sdl.GPUDevice,
    ) !VoxelizePass {
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
                .num_readwrite_storage_textures = 6,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 0,
                .threadcount_x = 4,
                .threadcount_y = 4,
                .threadcount_z = 4,
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
                .num_samplers = 0,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 2,
                .num_readwrite_storage_textures = 6,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 1,
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
                .num_samplers = 6,
                .num_readonly_storage_textures = 0,
                .num_readonly_storage_buffers = 0,
                .num_readwrite_storage_textures = 4,
                .num_readwrite_storage_buffers = 0,
                .num_uniform_buffers = 1,
                .threadcount_x = 4,
                .threadcount_y = 4,
                .threadcount_z = 4,
            });
        };
        errdefer sdl.releaseGPUComputePipeline(device, average_pipeline);

        const lighting_pipeline = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/lighting.comp.spv",
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
                .num_samplers = 4,
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
        errdefer sdl.releaseGPUComputePipeline(device, lighting_pipeline);

        var targets = std.EnumArray(Target, *sdl.GPUTexture).initUndefined();
        var cascades = std.EnumArray(Cascade, *sdl.GPUTexture).initUndefined();

        // if zig allows this, why not have local functions :|
        const TextureBuilder = struct {
            fn createTarget(dev: *sdl.GPUDevice) !*sdl.GPUTexture {
                return sdl.createGPUTexture(dev, &.{
                    .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
                    .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R32_UINT,
                    .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                        sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                    .width = 64,
                    .height = 64,
                    .layer_count_or_depth = 64,
                    .num_levels = 1,
                    .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
                });
            }
        };

        // NOTE at some point we should make sure we only use always-supported formats if possible
        targets.set(.weight_coverage, try TextureBuilder.createTarget(device));
        errdefer sdl.releaseGPUTexture(device, targets.get(.weight_coverage));
        targets.set(.diffuse_emissive_r, try TextureBuilder.createTarget(device));
        errdefer sdl.releaseGPUTexture(device, targets.get(.diffuse_emissive_r));
        targets.set(.diffuse_emissive_g, try TextureBuilder.createTarget(device));
        errdefer sdl.releaseGPUTexture(device, targets.get(.diffuse_emissive_g));
        targets.set(.diffuse_emissive_b, try TextureBuilder.createTarget(device));
        errdefer sdl.releaseGPUTexture(device, targets.get(.diffuse_emissive_b));
        targets.set(.normal_xy, try TextureBuilder.createTarget(device));
        errdefer sdl.releaseGPUTexture(device, targets.get(.normal_xy));
        targets.set(.normal_z_pad, try TextureBuilder.createTarget(device));
        errdefer sdl.releaseGPUTexture(device, targets.get(.normal_z_pad));

        cascades.set(.coverage, try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16_UNORM,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 64 * n_cascades,
            .height = 64 * 2,
            .layer_count_or_depth = 64,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        }));
        errdefer sdl.releaseGPUTexture(device, cascades.get(.coverage));

        cascades.set(.diffuse, try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 64 * n_cascades,
            .height = 64,
            .layer_count_or_depth = 64,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        }));
        errdefer sdl.releaseGPUTexture(device, cascades.get(.diffuse));

        cascades.set(.emissive, try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 64 * n_cascades,
            .height = 64,
            .layer_count_or_depth = 64,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        }));
        errdefer sdl.releaseGPUTexture(device, cascades.get(.emissive));

        cascades.set(.normal, try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_SNORM,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 64 * n_cascades,
            .height = 64,
            .layer_count_or_depth = 64,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        }));
        errdefer sdl.releaseGPUTexture(device, cascades.get(.normal));

        cascades.set(.radiance, try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_3D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE |
                sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 64 * n_cascades,
            .height = 64 * 2,
            .layer_count_or_depth = 64,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        }));
        errdefer sdl.releaseGPUTexture(device, cascades.get(.radiance));

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
            .clear_pipeline = clear_pipeline,
            .voxelize_pipeline = voxelize_pipeline,
            .average_pipeline = average_pipeline,
            .lighting_pipeline = lighting_pipeline,
            .sampler = sampler,
            .compute_pass = null,
            .targets = targets,
            .cascades = cascades,
            .ix_temporal = 0,
            .ix_cascade = 0,
            .cascade_counter = 0,
        };
    }

    fn deinit(pass: *VoxelizePass) void {
        sdl.c.SDL_ReleaseGPUSampler(pass.device, pass.sampler);
        for (pass.cascades.values) |cascade| sdl.releaseGPUTexture(pass.device, cascade);
        for (pass.targets.values) |target| sdl.releaseGPUTexture(pass.device, target);
        sdl.releaseGPUComputePipeline(pass.device, pass.lighting_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.average_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.voxelize_pipeline);
        sdl.releaseGPUComputePipeline(pass.device, pass.clear_pipeline);
        pass.* = undefined;
    }

    fn begin(pass: *VoxelizePass, command_buffer: *sdl.GPUCommandBuffer) void {
        pass.updateCascadeIndex();

        const storage_texture_bindings_0 = [_]sdl.GPUStorageTextureReadWriteBinding{
            .{ .texture = pass.targets.get(.weight_coverage), .cycle = true },
            .{ .texture = pass.targets.get(.diffuse_emissive_r), .cycle = true },
            .{ .texture = pass.targets.get(.diffuse_emissive_g), .cycle = true },
            .{ .texture = pass.targets.get(.diffuse_emissive_b), .cycle = true },
            .{ .texture = pass.targets.get(.normal_xy), .cycle = true },
            .{ .texture = pass.targets.get(.normal_z_pad), .cycle = true },
        };
        const clear_pass = sdl.c.SDL_BeginGPUComputePass(
            command_buffer,
            &storage_texture_bindings_0[0],
            storage_texture_bindings_0.len,
            null,
            0,
        );
        sdl.c.SDL_BindGPUComputePipeline(clear_pass, pass.clear_pipeline);
        sdl.c.SDL_DispatchGPUCompute(clear_pass, 16, 16, 16);
        sdl.c.SDL_EndGPUComputePass(clear_pass);

        const storage_texture_bindings_1 = [_]sdl.GPUStorageTextureReadWriteBinding{
            .{ .texture = pass.targets.get(.weight_coverage) },
            .{ .texture = pass.targets.get(.diffuse_emissive_r) },
            .{ .texture = pass.targets.get(.diffuse_emissive_g) },
            .{ .texture = pass.targets.get(.diffuse_emissive_b) },
            .{ .texture = pass.targets.get(.normal_xy) },
            .{ .texture = pass.targets.get(.normal_z_pad) },
        };
        pass.compute_pass = sdl.c.SDL_BeginGPUComputePass(
            command_buffer,
            &storage_texture_bindings_1[0],
            storage_texture_bindings_1.len,
            null,
            0,
        );
        sdl.c.SDL_BindGPUComputePipeline(pass.compute_pass.?, pass.voxelize_pipeline);
    }

    fn voxelizeObject(
        pass: *VoxelizePass,
        command_buffer: *sdl.GPUCommandBuffer,
        object: Scene.Object,
        alpha: f32,
    ) void {
        const storage_buffers = [_]*sdl.GPUBuffer{
            object.model.vertex_buffer,
            object.model.index_buffer,
        };
        sdl.c.SDL_BindGPUComputeStorageBuffers(
            pass.compute_pass,
            0,
            &storage_buffers[0],
            storage_buffers.len,
        );
        sdl.c.SDL_PushGPUComputeUniformData(
            command_buffer,
            0,
            &VoxelizeData{
                .model_matrix = zm.matToArr(object.transform(alpha)),
                .normal_matrix = zm.matToArr(zm.transpose(zm.inverse(object.transform(alpha)))),
                .n_triangles = object.model.n_indices / 3,
                .ix_cascade = pass.ix_cascade,
            },
            @sizeOf(VoxelizeData),
        );
        sdl.c.SDL_DispatchGPUCompute(
            pass.compute_pass,
            (object.model.n_indices / 3 + 63) / 64,
            1,
            1,
        );
    }

    fn end(pass: *VoxelizePass, command_buffer: *sdl.GPUCommandBuffer) void {
        sdl.c.SDL_EndGPUComputePass(pass.compute_pass.?);
        pass.compute_pass = null;

        const storage_texture_bindings_0 = [_]sdl.GPUStorageTextureReadWriteBinding{
            .{ .texture = pass.cascades.get(.coverage) },
            .{ .texture = pass.cascades.get(.diffuse) },
            .{ .texture = pass.cascades.get(.emissive) },
            .{ .texture = pass.cascades.get(.normal) },
        };
        const average_pass = sdl.c.SDL_BeginGPUComputePass(
            command_buffer,
            &storage_texture_bindings_0[0],
            storage_texture_bindings_0.len,
            null,
            0,
        );
        sdl.c.SDL_BindGPUComputePipeline(average_pass, pass.average_pipeline);
        const texture_sampler_bindings_0 = [_]sdl.c.struct_SDL_GPUTextureSamplerBinding{
            .{ .texture = pass.targets.get(.weight_coverage), .sampler = pass.sampler },
            .{ .texture = pass.targets.get(.diffuse_emissive_r), .sampler = pass.sampler },
            .{ .texture = pass.targets.get(.diffuse_emissive_g), .sampler = pass.sampler },
            .{ .texture = pass.targets.get(.diffuse_emissive_b), .sampler = pass.sampler },
            .{ .texture = pass.targets.get(.normal_xy), .sampler = pass.sampler },
            .{ .texture = pass.targets.get(.normal_z_pad), .sampler = pass.sampler },
        };
        sdl.c.SDL_BindGPUComputeSamplers(
            average_pass,
            0,
            &texture_sampler_bindings_0[0],
            texture_sampler_bindings_0.len,
        );
        sdl.c.SDL_PushGPUComputeUniformData(
            command_buffer,
            0,
            &AverageData{
                .ix_temporal = pass.ix_temporal,
                .ix_cascade = pass.ix_cascade,
            },
            @sizeOf(AverageData),
        );
        sdl.c.SDL_DispatchGPUCompute(average_pass, 16, 16, 16);
        sdl.c.SDL_EndGPUComputePass(average_pass);
    }

    fn updateCascadeIndex(pass: *VoxelizePass) void {
        pass.cascade_counter += 1;
        pass.cascade_counter = @mod(pass.cascade_counter, std.math.pow(i32, 2, n_cascades));

        if (pass.cascade_counter == 0) {
            pass.ix_cascade = n_cascades - 1;
        } else {
            pass.ix_cascade = 31 - @clz(pass.cascade_counter & -pass.cascade_counter);
        }
    }
};

const DebugVoxelDrawPass = struct {
    const DrawData = extern struct {
        iv: [16]f32 align(16),
        ip: [16]f32 align(16),
    };

    const Vertex = struct {
        position: [3]f32,
    };

    const Mode = enum(u32) {
        coverage = 0,
        diffuse = 1,
        emissive = 2,
        normal = 3,
        radiance = 4,
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

    backbuffer: *sdl.c.SDL_GPUTexture,
    vertex_buffer: *sdl.GPUBuffer,
    sampler: *sdl.GPUSampler,

    mode: Mode,

    fn init(
        gpa: std.mem.Allocator,
        device: *sdl.c.SDL_GPUDevice,
    ) !DebugVoxelDrawPass {
        const vertex_shader = blk: {
            const file = try std.fs.cwd().openFile(
                "data/shaders/debug_voxel_draw.vert.spv",
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
                "data/shaders/debug_voxel_draw.frag.spv",
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
                .num_samplers = 5,
                .num_storage_textures = 0,
                .num_storage_buffers = 0,
                .num_uniform_buffers = 1,
            });
        };
        defer sdl.releaseGPUShader(device, fragment_shader);

        const vertex_buffer_descriptions = [_]sdl.c.SDL_GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = @sizeOf(Vertex),
            .input_rate = sdl.c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        const vertex_attributes = [_]sdl.c.SDL_GPUVertexAttribute{.{
            .buffer_slot = 0,
            .format = sdl.c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
            .location = 0,
            .offset = @offsetOf(Vertex, "position"),
        }};

        const color_target_descriptions = [_]sdl.c.SDL_GPUColorTargetDescription{.{
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .blend_state = .{},
        }};
        const pipeline_create_info = sdl.c.SDL_GPUGraphicsPipelineCreateInfo{
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
        const pipeline = sdl.c.SDL_CreateGPUGraphicsPipeline(
            device,
            &pipeline_create_info,
        ) orelse {
            log.err("SDL_CreateGPUGraphicsPipeline: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        const width = 640;
        const height = 360;
        const backbuffer = try sdl.createGPUTexture(device, &.{
            .type = sdl.c.SDL_GPU_TEXTURETYPE_2D,
            .format = sdl.c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .usage = sdl.c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | sdl.c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = sdl.c.SDL_GPU_SAMPLECOUNT_1,
        });
        errdefer sdl.c.SDL_ReleaseGPUTexture(device, backbuffer);

        const sizeof_vertices: u32 = @intCast(full_screen_quad.len * @sizeOf(Vertex));

        const vertex_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_VERTEX | sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
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

        const sampler = sdl.c.SDL_CreateGPUSampler(device, &.{
            .min_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = sdl.c.SDL_GPU_FILTER_LINEAR,
            .address_mode_u = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = sdl.c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        }) orelse {
            log.err("SDL_CreateGPUSampler: {s}", .{sdl.c.SDL_GetError()});
            return error.Sdl;
        };
        errdefer sdl.c.SDL_ReleaseGPUSampler(device, sampler);

        return .{
            .device = device,
            .pipeline = pipeline,
            .backbuffer = backbuffer,
            .vertex_buffer = vertex_buffer,
            .sampler = sampler,
            .mode = .normal,
        };
    }

    fn deinit(pass: *DebugVoxelDrawPass) void {
        sdl.c.SDL_ReleaseGPUSampler(pass.device, pass.sampler);
        sdl.releaseGPUBuffer(pass.device, pass.vertex_buffer);
        sdl.releaseGPUTexture(pass.device, pass.backbuffer);
        sdl.c.SDL_ReleaseGPUGraphicsPipeline(pass.device, pass.pipeline);
        pass.* = undefined;
    }

    fn run(
        pass: *DebugVoxelDrawPass,
        command_buffer: *sdl.GPUCommandBuffer,
        cascades: *std.EnumArray(VoxelizePass.Cascade, *sdl.GPUTexture),
        camera_v: zm.Mat,
        camera_p: zm.Mat,
    ) void {
        const clear_color: sdl.c.SDL_FColor = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 };
        const color_target_infos = [_]sdl.c.SDL_GPUColorTargetInfo{.{
            .texture = pass.backbuffer,
            .clear_color = clear_color,
            .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
        }};
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
        sdl.c.SDL_PushGPUVertexUniformData(
            command_buffer,
            0,
            &DrawData{
                .iv = zm.matToArr(zm.inverse(camera_v)),
                .ip = zm.matToArr(zm.inverse(camera_p)),
            },
            @sizeOf(DrawData),
        );
        sdl.c.SDL_PushGPUFragmentUniformData(
            command_buffer,
            0,
            &@as(u32, @intFromEnum(pass.mode)),
            @sizeOf(u32),
        );
        const sampler_bindings = [_]sdl.c.SDL_GPUTextureSamplerBinding{
            .{ .texture = cascades.get(.coverage), .sampler = pass.sampler },
            .{ .texture = cascades.get(.diffuse), .sampler = pass.sampler },
            .{ .texture = cascades.get(.emissive), .sampler = pass.sampler },
            .{ .texture = cascades.get(.normal), .sampler = pass.sampler },
            .{ .texture = cascades.get(.radiance), .sampler = pass.sampler },
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

const DrawPass = struct {
    const DrawData = extern struct {
        mvp: [16]f32 align(16),
        normal: [16]f32 align(16),
    };

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
        const clear_color: sdl.c.SDL_FColor = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 };
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
                .clear_depth = 0,
                .load_op = sdl.c.SDL_GPU_LOADOP_CLEAR,
                .store_op = sdl.c.SDL_GPU_STOREOP_STORE,
            },
        );
        sdl.c.SDL_BindGPUGraphicsPipeline(pass.render_pass, pass.pipeline);
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
        sdl.c.SDL_BindGPUVertexBuffers(
            pass.render_pass,
            0,
            &vertex_buffers[0],
            vertex_buffers.len,
        );
        sdl.c.SDL_BindGPUIndexBuffer(
            pass.render_pass,
            &.{ .buffer = object.model.index_buffer, .offset = 0 },
            sdl.c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
        );
        const model = object.transform(alpha);
        const mvp = zm.mul(model, camera_vp);
        const normal = zm.transpose(zm.inverse(model));
        sdl.c.SDL_PushGPUVertexUniformData(
            command_buffer,
            0,
            &DrawData{
                .mvp = zm.matToArr(mvp),
                .normal = zm.matToArr(normal),
            },
            @sizeOf(DrawData),
        );
        sdl.c.SDL_DrawGPUIndexedPrimitives(pass.render_pass, object.model.n_indices, 1, 0, 0, 0);
    }

    fn end(pass: *DrawPass, command_buffer: *sdl.c.SDL_GPUCommandBuffer) void {
        const render_pass = pass.render_pass.?;
        sdl.c.SDL_EndGPURenderPass(render_pass);
        _ = command_buffer;
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
            .pitch = @sizeOf(Vertex),
            .input_rate = sdl.c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        const vertex_attributes = [_]sdl.c.SDL_GPUVertexAttribute{ .{
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

        const vertex_buffer = try sdl.createGPUBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = 6 * @sizeOf(Vertex),
        });
        errdefer sdl.releaseGPUBuffer(device, vertex_buffer);

        const transfer_buffer = try sdl.createGPUTransferBuffer(device, &.{
            .usage = sdl.c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = 6 * @sizeOf(Vertex),
        });
        defer sdl.releaseGPUTransferBuffer(device, transfer_buffer);

        const command_buffer = try sdl.acquireGPUCommandBuffer(device);

        const bytes: [*]Vertex = @alignCast(@ptrCast(
            try sdl.mapGPUTransferBuffer(device, transfer_buffer, true),
        ));
        @memcpy(bytes, &full_screen_quad);
        sdl.unmapGPUTransferBuffer(device, transfer_buffer);

        const copy_pass = try sdl.beginGPUCopyPass(command_buffer);
        sdl.uploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, &.{
            .buffer = vertex_buffer,
            .offset = 0,
            .size = @sizeOf(Vertex) * 6,
        }, false);
        sdl.endGPUCopyPass(copy_pass);

        try sdl.submitGPUCommandBuffer(command_buffer);

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

const Camera = struct {
    pos: zm.Vec,
    yaw: f32,
    pitch: f32,

    prev_pos: zm.Vec,
    prev_yaw: f32,
    prev_pitch: f32,

    const up = zm.f32x4(0.0, 1.0, 0.0, 0.0);
    const mouse_sensitivity = 0.3;
    const move_speed = 30;

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
        return perspectiveFovRhInv(std.math.degreesToRadians(69), 16.0 / 9.0, 0.1, 1e5);
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
