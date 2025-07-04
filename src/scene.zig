const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Scene = @This();

const log = std.log.scoped(.scene);

// matches std430, important for voxelization
pub const Vertex = extern struct {
    position: [3]f32 align(16),
    normal: [3]f32 align(16),
};

const JsonModel = struct {
    first_vertex: u32,
    first_index: u32,
    num_vertices: u32,
    num_indices: u32,
    diffuse: []const u8,
};

const Model = struct {
    vertex_buffer: *sdl.c.SDL_GPUBuffer,
    index_buffer: *sdl.c.SDL_GPUBuffer,
    first_vertex: u32,
    first_index: u32,
    n_indices: u32,
};

pub const Object = struct {
    model: *Model,

    position: zm.Vec,
    rotation: zm.Quat,
    scale: zm.Vec,

    diffuse: [4]f32,
    emissive: [4]f32,
    roughness: f32,

    pub fn transform(object: Object, alpha: f32) zm.Mat {
        _ = alpha;
        return zm.mul(
            zm.scalingV(object.scale),
            zm.mul(
                zm.matFromQuat(object.rotation),
                zm.translationV(object.position),
            ),
        );
    }
};

models: std.ArrayListUnmanaged(Model),
objects: std.ArrayListUnmanaged(Object),

pub fn init(gpa: std.mem.Allocator, device: *sdl.GPUDevice) !Scene {
    const data_models = try std.fs.cwd().readFileAlloc(
        gpa,
        "data/models/sponza/models.json",
        100_000_000,
    );
    defer gpa.free(data_models);
    const json_models = try std.json.parseFromSlice([]JsonModel, gpa, data_models, .{});
    defer json_models.deinit();

    const data_vertices = try std.fs.cwd().readFileAlloc(
        gpa,
        "data/models/sponza/vertices.bin",
        100_000_000,
    );
    defer gpa.free(data_vertices);

    const data_indices = try std.fs.cwd().readFileAlloc(
        gpa,
        "data/models/sponza/indices.bin",
        100_000_000,
    );
    defer gpa.free(data_indices);

    const n_vertices: u32 = std.mem.readInt(u32, data_vertices[0..4], .little);
    const n_indices: u32 = std.mem.readInt(u32, data_indices[0..4], .little);
    const sizeof_vertices: u32 = n_vertices * @sizeOf(Vertex);
    const sizeof_indices: u32 = n_indices * @sizeOf(u32);

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
    @memcpy(bytes, data_vertices[@sizeOf(u32)..]);
    @memcpy(bytes + sizeof_vertices, data_indices[@sizeOf(u32)..]);
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

    var models = try std.ArrayListUnmanaged(Model).initCapacity(gpa, json_models.value.len);
    errdefer models.deinit(gpa);
    var objects = try std.ArrayListUnmanaged(Object).initCapacity(gpa, json_models.value.len * 3);
    errdefer objects.deinit(gpa);
    for (json_models.value) |model| {
        std.debug.assert(model.num_indices % 3 == 0);
        std.debug.assert(model.num_indices >= model.num_vertices);
        models.appendAssumeCapacity(.{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .first_vertex = model.first_vertex,
            .first_index = model.first_index,
            .n_indices = model.num_indices,
        });
        objects.appendAssumeCapacity(.{
            .model = &models.items[models.items.len - 1],
            .position = zm.f32x4(0.0, 0.0, 0.0, 1.0),
            .rotation = zm.qidentity(),
            .scale = zm.f32x4(1.0, 1.0, 1.0, 0.0),
            .diffuse = castColor(model.diffuse),
            .emissive = .{ 0.0, 0.0, 0.0, 0.0 },
            .roughness = 0.0,
        });
        objects.appendAssumeCapacity(.{
            .model = &models.items[models.items.len - 1],
            .position = zm.f32x4(0.0, -60.0, 1.0, 1.0),
            .rotation = zm.qidentity(),
            .scale = zm.f32x4(7.0, 7.0, 7.0, 0.0),
            .diffuse = castColor(model.diffuse),
            .emissive = .{ 0.0, 0.0, 0.0, 0.0 },
            .roughness = 0.0,
        });
        objects.appendAssumeCapacity(.{
            .model = &models.items[models.items.len - 1],
            .position = zm.f32x4(0.0, -450.0, 7.0, 1.0),
            .rotation = zm.qidentity(),
            .scale = zm.f32x4(49.0, 49.0, 49.0, 0.0),
            .diffuse = castColor(model.diffuse),
            .emissive = .{ 0.0, 0.0, 0.0, 0.0 },
            .roughness = 0.0,
        });
    }

    return .{
        .models = models,
        .objects = objects,
    };
}

pub fn deinit(scene: *Scene, gpa: std.mem.Allocator, device: *sdl.GPUDevice) void {
    // FIXME? is we mix in other vertex buffers, this gets awkward
    if (scene.models.items.len > 0) {
        sdl.releaseGPUBuffer(device, scene.models.items[0].vertex_buffer);
        sdl.releaseGPUBuffer(device, scene.models.items[0].index_buffer);
    }
    scene.models.deinit(gpa);
    scene.objects.deinit(gpa);
    scene.* = undefined;
}

fn castColor(a: []const u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(a[0])) / 255.0,
        @as(f32, @floatFromInt(a[1])) / 255.0,
        @as(f32, @floatFromInt(a[2])) / 255.0,
        0,
    };
}
