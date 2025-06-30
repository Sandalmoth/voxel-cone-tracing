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

const Model = struct {
    vertex_buffer: *sdl.c.SDL_GPUBuffer,
    index_buffer: *sdl.c.SDL_GPUBuffer,
    n_indices: u32,
};
