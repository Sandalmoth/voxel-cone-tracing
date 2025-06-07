const std = @import("std");

const log = std.log.scoped(.perf_counter);

const PerfCounter = @This();

const N_SAMPLES = 67;

const Counter = struct {
    timer: std.time.Timer,
    n: usize,
    cursor: usize,
    history: [N_SAMPLES]u64,
};

var counters: std.StringHashMap(Counter) = undefined;
var mutex: std.Thread.Mutex = undefined;

pub fn init(alloc: std.mem.Allocator) void {
    counters = std.StringHashMap(Counter).init(alloc);
    mutex = std.Thread.Mutex{};
}

pub fn deinit() void {
    counters.deinit();
}

pub fn start(comptime name: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    const counter = counters.getOrPut(name) catch return;
    if (counter.found_existing) {
        counter.value_ptr.timer.reset();
    } else {
        counter.value_ptr.n = 0;
        counter.value_ptr.cursor = 0;
        counter.value_ptr.timer = std.time.Timer.start() catch {
            _ = counters.remove(name);
            return;
        };
    }
}

pub fn stop(comptime name: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    const counter = counters.getPtr(name) orelse {
        log.debug("{s} not found", .{name});
        return;
    };
    const t = counter.timer.lap();
    counter.history[counter.cursor] = t + 1;
    counter.n = @min(counter.n + 1, counter.history.len);
    counter.cursor = (counter.cursor + 1) % counter.history.len;
}

pub fn stats(name: []const u8) [5]f64 {
    const counter = counters.getPtr(name) orelse {
        log.debug("{s} not found", .{name});
        return .{ 0, 0, 0, 0, 0 };
    };
    if (counter.n == 0) return .{ 0, 0, 0, 0, 0 };

    var buf: [N_SAMPLES]u64 = counter.history;
    for ([_]usize{ 57, 23, 10, 4, 1 }) |gap| {
        if (gap >= counter.n) continue;
        for (gap..counter.n) |j| {
            const tmp = buf[j];
            var k = j;
            while (k >= gap and buf[k - gap] > tmp) : (k -= gap) {
                buf[k] = buf[k - gap];
            }
            buf[k] = tmp;
        }
    }

    return .{
        @as(f64, @floatFromInt(buf[0])),
        @as(f64, @floatFromInt(buf[counter.n / 4])),
        @as(f64, @floatFromInt(buf[counter.n / 2])),
        @as(f64, @floatFromInt(buf[3 * counter.n / 4])),
        @as(f64, @floatFromInt(buf[counter.n - 1])),
    };
}

const NameIterator = struct {
    it: std.StringHashMap(Counter).KeyIterator,

    pub fn next(it: *NameIterator) ?[]const u8 {
        const name = it.it.next() orelse return null;
        return name.*;
    }
};

pub fn nameIterator() NameIterator {
    return .{ .it = counters.keyIterator() };
}
