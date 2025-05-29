const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Scene = @This();

const log = std.log.scoped(.scene);

// this must match std430
pub const Vertex = extern struct {
    position: [3]f32 align(16),
    normal: [3]f32 align(16),
};

const Model = struct {
    vertex_buffer: *sdl.c.SDL_GPUBuffer,
    index_buffer: *sdl.c.SDL_GPUBuffer,
    n_indices: u32,
};

pub const Object = struct {
    model: Model,
    position: zm.Vec,
    rotation: zm.Quat,
    scale: zm.Vec,
    prev_position: zm.Vec,
    prev_rotation: zm.Quat,
    prev_scale: zm.Vec,

    angular_velocity: zm.Quat,

    pub fn transform(object: Object, alpha: f32) zm.Mat {
        const position = zm.lerp(object.prev_position, object.prev_position, alpha);
        const rotation = zm.slerp(object.prev_rotation, object.rotation, alpha);
        const scale = zm.lerp(object.prev_scale, object.prev_scale, alpha);
        return zm.mul(
            zm.scalingV(scale),
            zm.mul(
                zm.matFromQuat(rotation),
                zm.translationV(position),
            ),
        );
    }

    pub fn update(object: *Object, tick: f32) void {
        object.prev_rotation = object.rotation;

        var axis: zm.Vec = undefined;
        var angle: f32 = undefined;
        zm.quatToAxisAngle(object.angular_velocity, &axis, &angle);
        angle *= tick;

        object.rotation = zm.qmul(
            zm.quatFromAxisAngle(axis, angle),
            object.rotation,
        );
    }
};

cube: Model,
objects: std.ArrayListUnmanaged(Object),

pub fn init(gpa: std.mem.Allocator, device: *sdl.c.SDL_GPUDevice) !Scene {
    var scene = Scene{
        .cube = try load(device, &cube_vertices, &cube_indices),
        .objects = .empty,
    };

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    const rand = rng.random();

    for (0..100) |x| {
        for (0..3) |y| {
            for (0..3) |z| {
                const position = zm.f32x4(
                    10 * (@as(f32, @floatFromInt(x)) - 1.5 + rand.float(f32)),
                    10 * (@as(f32, @floatFromInt(y)) - 1.5 + rand.float(f32)),
                    10 * (@as(f32, @floatFromInt(z)) - 1.5 + rand.float(f32)),
                    1,
                );
                const rotation = zm.quatFromRollPitchYaw(
                    2 * std.math.pi * rand.float(f32),
                    2 * std.math.pi * rand.float(f32),
                    2 * std.math.pi * rand.float(f32),
                );
                // const rotation = zm.qidentity();
                const scale = zm.f32x4s(2.0 * (rand.float(f32) + 0.5));
                const angular_velocity = zm.quatFromRollPitchYaw(
                    std.math.pi * rand.float(f32),
                    std.math.pi * rand.float(f32),
                    std.math.pi * rand.float(f32),
                );
                try scene.objects.append(gpa, .{
                    .model = scene.cube,
                    .position = position,
                    .rotation = rotation,
                    .scale = scale,
                    .prev_position = position,
                    .prev_rotation = rotation,
                    .prev_scale = scale,
                    .angular_velocity = angular_velocity,
                });
            }
        }
    }

    return scene;
}

pub fn deinit(scene: *Scene, gpa: std.mem.Allocator, device: *sdl.c.SDL_GPUDevice) void {
    scene.objects.deinit(gpa);
    unload(&scene.cube, device);
    scene.* = undefined;
}

fn load(device: *sdl.c.SDL_GPUDevice, vertices: []const Vertex, indices: []const u32) !Model {
    const sizeof_vertices: u32 = @intCast(vertices.len * @sizeOf(Vertex));
    const sizeof_indices: u32 = @intCast(indices.len * @sizeOf(u32));

    const vertex_buffer = try sdl.createGPUBuffer(device, &.{
        .usage = sdl.c.SDL_GPU_BUFFERUSAGE_VERTEX | sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
        .size = sizeof_vertices,
    });
    errdefer sdl.releaseGPUBuffer(device, vertex_buffer);

    const index_buffer = try sdl.createGPUBuffer(device, &.{
        .usage = sdl.c.SDL_GPU_BUFFERUSAGE_INDEX | sdl.c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
        .size = sizeof_indices,
    });
    errdefer sdl.releaseGPUBuffer(device, index_buffer);

    const transfer_buffer = try sdl.createGPUTransferBuffer(device, &.{
        .usage = sdl.c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = sizeof_vertices + sizeof_indices,
    });
    defer sdl.releaseGPUTransferBuffer(device, transfer_buffer);

    const command_buffer = try sdl.acquireGPUCommandBuffer(device);

    const bytes: [*]u8 = @alignCast(@ptrCast(
        try sdl.mapGPUTransferBuffer(device, transfer_buffer, true),
    ));
    @memcpy(@as([*]Vertex, @alignCast(@ptrCast(bytes))), vertices);
    @memcpy(@as([*]u32, @alignCast(@ptrCast(bytes + sizeof_vertices))), indices);
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
    sdl.uploadToGPUBuffer(copy_pass, &.{
        .transfer_buffer = transfer_buffer,
        .offset = sizeof_vertices,
    }, &.{
        .buffer = index_buffer,
        .offset = 0,
        .size = sizeof_indices,
    }, false);
    sdl.endGPUCopyPass(copy_pass);

    try sdl.submitGPUCommandBuffer(command_buffer);

    return .{
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .n_indices = @intCast(indices.len),
    };
}

fn unload(model: *Model, device: *sdl.c.SDL_GPUDevice) void {
    sdl.releaseGPUBuffer(device, model.index_buffer);
    sdl.releaseGPUBuffer(device, model.vertex_buffer);
    model.* = undefined;
}

const cube_vertices = [_]Vertex{
    .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .normal = .{ -1, 0, 0 } },
};

const cube_indices = [_]u32{
    4,  5,  6,  7,  6,  5,
    12, 13, 14, 15, 14, 13,
    20, 21, 22, 23, 22, 21,
    2,  1,  0,  1,  2,  3,
    10, 9,  8,  9,  10, 11,
    18, 17, 16, 17, 18, 19,
};
