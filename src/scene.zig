const std = @import("std");
const zm = @import("zmath");

const sdl = @import("sdl.zig");

const Scene = @This();

const log = std.log.scoped(.scene);
