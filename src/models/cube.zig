const Vertex = @import("../scene.zig").Vertex;

pub const cube_vertices = [_]Vertex{
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

pub const cube_indices = [_]u32{
    4,  5,  6,  7,  6,  5,
    12, 13, 14, 15, 14, 13,
    20, 21, 22, 23, 22, 21,
    2,  1,  0,  1,  2,  3,
    10, 9,  8,  9,  10, 11,
    18, 17, 16, 17, 18, 19,
};
