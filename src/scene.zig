const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Scene = @This();

const log = std.log.scoped(.scene);

const cube_vertices = @import("models/cube.zig").cube_vertices;
const cube_indices = @import("models/cube.zig").cube_indices;
const bunny_vertices = @import("models/bunny.zig").bunny_vertices;
const bunny_indices = @import("models/bunny.zig").bunny_indices;
const sponza_vertices = @import("models/sponza.zig").sponza_vertices;
const sponza_indices = @import("models/sponza.zig").sponza_indices;

// matches std430
pub const Vertex = extern struct {
    position: [3]f32 align(16),
    normal: [3]f32 align(16),
};

const Model = struct {
    vertex_buffer: *sdl.c.SDL_GPUBuffer,
    index_buffer: *sdl.c.SDL_GPUBuffer,
    n_indices: u32,

    fn init(device: *sdl.c.SDL_GPUDevice, vertices: []const Vertex, indices: []const u32) !Model {
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

    fn deinit(model: *Model, device: *sdl.c.SDL_GPUDevice) void {
        sdl.releaseGPUBuffer(device, model.index_buffer);
        sdl.releaseGPUBuffer(device, model.vertex_buffer);
        model.* = undefined;
    }
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

    diffuse: zm.Vec,
    emissive: zm.Vec,
    roughness: f32,

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

        if (zm.all(zm.isNearEqual(zm.qidentity(), object.angular_velocity, zm.f32x4s(1e-3)), 4)) {
            return;
        }

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
bunny: Model,
sponza: Model,
objects: std.ArrayListUnmanaged(Object),

pub fn init(gpa: std.mem.Allocator, device: *sdl.c.SDL_GPUDevice) !Scene {
    var scene = Scene{
        .cube = try Model.init(device, &cube_vertices, &cube_indices),
        .bunny = try Model.init(device, &bunny_vertices, &bunny_indices),
        .sponza = undefined,
        .objects = .empty,
    };

    try scene.objects.append(gpa, .{
        .model = scene.bunny,
        .position = zm.f32x4(0, 0, 0, 1),
        .rotation = zm.qidentity(),
        .scale = zm.f32x4(1, 1, 1, 0),
        .prev_position = zm.f32x4(0, 0, 0, 1),
        .prev_rotation = zm.qidentity(),
        .prev_scale = zm.f32x4(1, 1, 1, 0),
        .angular_velocity = zm.quatFromRollPitchYaw(0.0, 1.0, 0.0),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    // also a bunny on top of the box (for shadows)
    try scene.objects.append(gpa, .{
        .model = scene.bunny,
        .position = zm.f32x4(0, 4, 0, 1),
        .rotation = zm.qidentity(),
        .scale = zm.f32x4(1, 1, 1, 0),
        .prev_position = zm.f32x4(0, 4, 0, 1),
        .prev_rotation = zm.qidentity(),
        .prev_scale = zm.f32x4(1, 1, 1, 0),
        .angular_velocity = zm.quatFromRollPitchYaw(0.0, 1.0, 0.0),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    // floor
    try scene.objects.append(gpa, .{
        .model = scene.cube,
        .position = zm.f32x4(0, -2, 0, 1),
        .rotation = zm.qidentity(),
        .scale = zm.f32x4(4, 1, 4, 0),
        .prev_position = zm.f32x4(0, -2, 0, 1),
        .prev_rotation = zm.qidentity(),
        .prev_scale = zm.f32x4(4, 1, 4, 0),
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    // ceiling
    // try scene.objects.append(gpa, .{
    //     .model = scene.cube,
    //     .position = zm.f32x4(0, 2, 0, 1),
    //     .rotation = zm.qidentity(),
    //     .scale = zm.f32x4(4, 1, 4, 0),
    //     .prev_position = zm.f32x4(0, 2, 0, 1),
    //     .prev_rotation = zm.qidentity(),
    //     .prev_scale = zm.f32x4(4, 1, 4, 0),
    //     .angular_velocity = zm.qidentity(),
    //     .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
    //     .emissive = zm.f32x4s(0.0),
    //     .roughness = 0.5,
    // });

    // rear_wall
    try scene.objects.append(gpa, .{
        .model = scene.cube,
        .position = zm.f32x4(2, 0, 0, 1),
        .rotation = zm.qidentity(),
        .scale = zm.f32x4(1, 4, 4, 0),
        .prev_position = zm.f32x4(2, 0, 0, 1),
        .prev_rotation = zm.qidentity(),
        .prev_scale = zm.f32x4(1, 4, 4, 0),
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    // left wall
    try scene.objects.append(gpa, .{
        .model = scene.cube,
        .position = zm.f32x4(0.01, 0.01, -2, 1),
        .rotation = zm.qidentity(),
        .scale = zm.f32x4(4, 4, 1, 0),
        .prev_position = zm.f32x4(0.01, 0.01, -2, 1),
        .prev_rotation = zm.qidentity(),
        .prev_scale = zm.f32x4(4, 4, 1, 0),
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.7, 0.0, 0.0, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    // right wall
    try scene.objects.append(gpa, .{
        .model = scene.cube,
        .position = zm.f32x4(0.01, 0.01, 2, 1),
        .rotation = zm.qidentity(),
        .scale = zm.f32x4(4, 4, 1, 0),
        .prev_position = zm.f32x4(0.01, 0.01, 2, 1),
        .prev_rotation = zm.qidentity(),
        .prev_scale = zm.f32x4(4, 4, 1, 0),
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.0, 0.7, 0.0, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    var rng = std.Random.DefaultPrng.init(
        @as(u64, @bitCast(std.time.microTimestamp())) *% 11400714819323198549,
    );
    const rand = rng.random();
    for (0..200) |_| {
        const position = zm.f32x4(
            100 * rand.floatNorm(f32),
            100 * rand.floatNorm(f32),
            100 * rand.floatNorm(f32),
            1,
        );
        const rotation = zm.quatFromRollPitchYaw(
            2 * std.math.pi * rand.float(f32),
            2 * std.math.pi * rand.float(f32),
            2 * std.math.pi * rand.float(f32),
        );
        const scale = zm.f32x4s(19.5 * rand.float(f32) + 0.5);
        const angular_velocity = zm.quatFromRollPitchYaw(
            std.math.pi * rand.float(f32),
            std.math.pi * rand.float(f32),
            std.math.pi * rand.float(f32),
        );
        const diffuse = if (rand.boolean()) zm.f32x4s(1.0) else zm.f32x4(
            rand.float(f32),
            rand.float(f32),
            rand.float(f32),
            1.0,
        );
        const emissive = if (rand.float(f32) > 0.0) zm.f32x4s(0.0) else zm.f32x4(
            rand.float(f32),
            rand.float(f32),
            rand.float(f32),
            rand.float(f32) * 2,
        );
        const roughness = rand.float(f32);
        try scene.objects.append(gpa, .{
            .model = scene.bunny,
            .position = position,
            .rotation = rotation,
            .scale = scale,
            .prev_position = position,
            .prev_rotation = rotation,
            .prev_scale = scale,
            .angular_velocity = angular_velocity,
            .diffuse = diffuse,
            .emissive = emissive,
            .roughness = roughness,
        });
    }

    return scene;
}

pub fn init2(gpa: std.mem.Allocator, device: *sdl.c.SDL_GPUDevice) !Scene {
    var scene = Scene{
        .cube = try Model.init(device, &cube_vertices, &cube_indices),
        .bunny = try Model.init(device, &bunny_vertices, &bunny_indices),
        .sponza = undefined,
        .objects = .empty,
    };

    var position: zm.Vec = zm.f32x4(0.0, 0.0, 0.0, 1.0);
    var rotation: zm.Quat = zm.qidentity();

    try scene.objects.append(gpa, .{
        .model = scene.cube,
        .position = zm.f32x4(19, -3, 0, 1),
        .rotation = zm.qidentity(),
        .scale = zm.f32x4(40, 1, 40, 0),
        .prev_position = zm.f32x4(19, -3, 0, 1),
        .prev_rotation = zm.qidentity(),
        .prev_scale = zm.f32x4(40, 1, 40, 0),
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    position = zm.f32x4(8, 4, -11, 1);
    rotation = zm.qmul(
        zm.quatFromRollPitchYaw(-0.2, 0.0, 0.0),
        zm.quatFromRollPitchYaw(0.0, 0.0, 0.3),
    );
    try scene.objects.append(gpa, .{
        .model = scene.cube,
        .position = position,
        .rotation = rotation,
        .scale = zm.f32x4(20, 0.1, 20, 0),
        .prev_position = position,
        .prev_rotation = rotation,
        .prev_scale = zm.f32x4(20, 0.1, 20, 0),
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    position = zm.f32x4(8, 4, 11, 1);
    rotation = zm.qmul(
        zm.quatFromRollPitchYaw(0.2, 0.0, 0.0),
        zm.quatFromRollPitchYaw(0.0, 0.0, 0.3),
    );
    try scene.objects.append(gpa, .{
        .model = scene.cube,
        .position = position,
        .rotation = rotation,
        .scale = zm.f32x4(20, 0.1, 20, 0),
        .prev_position = position,
        .prev_rotation = rotation,
        .prev_scale = zm.f32x4(20, 0.1, 20, 0),
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    return scene;
}

pub fn init3(gpa: std.mem.Allocator, device: *sdl.c.SDL_GPUDevice) !Scene {
    var scene = Scene{
        .cube = undefined,
        .bunny = undefined,
        .sponza = try Model.init(device, &sponza_vertices, &sponza_indices),
        .objects = .empty,
    };

    const position: zm.Vec = zm.f32x4(0.0, 0.0, 0.0, 1.0);
    const rotation: zm.Quat = zm.qidentity();
    const scale: zm.Vec = zm.f32x4(40, 40, 40, 0);
    try scene.objects.append(gpa, .{
        .model = scene.sponza,
        .position = position,
        .rotation = rotation,
        .scale = scale,
        .prev_position = position,
        .prev_rotation = rotation,
        .prev_scale = scale,
        .angular_velocity = zm.qidentity(),
        .diffuse = zm.f32x4(0.7, 0.7, 0.7, 1.0),
        .emissive = zm.f32x4s(0.0),
        .roughness = 0.5,
    });

    return scene;
}

pub fn deinit(scene: *Scene, gpa: std.mem.Allocator, device: *sdl.c.SDL_GPUDevice) void {
    scene.objects.deinit(gpa);
    scene.bunny.deinit(device);
    scene.cube.deinit(device);
    scene.* = undefined;
}

pub fn deinit3(scene: *Scene, gpa: std.mem.Allocator, device: *sdl.c.SDL_GPUDevice) void {
    scene.objects.deinit(gpa);
    scene.sponza.deinit(device);
    scene.* = undefined;
}
