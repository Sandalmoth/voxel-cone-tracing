const std = @import("std");

const Scene = @This();

pub const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
};

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
    0,  1,  2,  3,  2,  1,
    4,  5,  6,  7,  6,  5,
    8,  9,  10, 11, 10, 9,
    12, 13, 14, 15, 14, 13,
    16, 17, 18, 19, 18, 17,
    20, 21, 22, 23, 22, 21,
};

pub fn init(gpa: std.mem.Allocator) !Scene {
    _ = gpa;
    return .{};
}

pub fn deinit(scene: *Scene) void {
    scene.* = undefined;
}
