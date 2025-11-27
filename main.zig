const std = @import("std");

const Mode = enum { serial, forget, group, waiter, waiter2, workers, select };

const Args = struct { port: u16, mode: Mode, limit: usize, sleep: std.Io.Duration };

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 5) die(
        \\Usage: {s} PORT MODE SLEEP LIMIT
        \\
        \\* Runs a server on PORT
        \\* MODE is one of: serial, forget, group, waiter, select, workers
        \\* Each request handler sleeps for SLEEP s to simulate workload
        \\* Accepts LIMIT requests then shuts down (and checks for leaks)
    , .{args[0]});
    const port = std.fmt.parseUnsigned(u16, args[1], 10) catch die("{s}: invalid port", .{args[1]});
    const mode = std.meta.stringToEnum(Mode, args[2]) orelse die("{s}: invalid mode", .{args[2]});
    const sleep_s = std.fmt.parseFloat(f64, args[3]) catch die("{s}: invalid sleep", .{args[3]});
    const sleep = std.Io.Duration.fromNanoseconds(@intFromFloat(sleep_s * std.time.ns_per_s));
    const limit = std.fmt.parseUnsigned(usize, args[4], 10) catch die("{s}: invalid limit", .{args[4]});
    return Args{ .port = port, .mode = mode, .limit = limit, .sleep = sleep };
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const args = try parseArgs(allocator);
    var threaded: std.Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(args.port) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    try run(io, &server, args.mode, args.limit, args.sleep);
}

fn run(io: std.Io, server: *std.Io.net.Server, mode: Mode, limit: usize, sleep: std.Io.Duration) !void {
    switch (mode) {
        // Handles one request at a time.
        // PROBLEM: no concurrency!
        .serial => {
            for (0..limit) |_| {
                var future = try io.concurrent(handle, .{ io, try server.accept(io), sleep });
                future.await(io);
            }
        },
        // Use io.concurrent and forget about the futures.
        // PROBLEM: leaks memory! (DebugAllocator confirms)
        .forget => {
            for (0..limit) |_| {
                _ = try io.concurrent(handle, .{ io, try server.accept(io), sleep });
            }
        },
        // Use std.Io.Group.
        // PROBLEM: unbounded memory growth!
        .group => {
            var group: std.Io.Group = .init;
            defer group.cancel(io);
            // Use group.concurrent once https://github.com/ziglang/zig/pull/26036 hits nightly.
            for (0..limit) |_| group.async(io, handle, .{ io, try server.accept(io), sleep });
        },
        // Use io.concurrent to spawn a task whose only job is to await futures.
        // PROBLEM: unbounded memory growth!
        // (And even if it worked, one slow request starves cleanup of others.)
        .waiter => {
            var buffer: [16]std.Io.Future(void) = undefined;
            var queue: std.Io.Queue(std.Io.Future(void)) = .init(&buffer);
            var total: usize = 0;
            var awaited = try io.concurrent(waiter, .{ io, &queue });
            defer cancelOutstanding(io, &queue, total - awaited.cancel(io));
            while (total < limit) : (total += 1) {
                try queue.putOne(io, try io.concurrent(handle, .{ io, try server.accept(io), sleep }));
            }
        },
        // Like Mode.waiter, but tasks enqueue themselves once they're done.
        // This idea comes from kprotty.
        // PROBLEM: unbounded memory growth!
        // (But it avoids the cleanup starving problem of Mode.waiter.)
        .waiter2 => {
            var buffer: [16]std.Io.Future(void) = undefined;
            var queue: std.Io.Queue(std.Io.Future(void)) = .init(&buffer);
            var total: usize = 0;
            var awaited = try io.concurrent(waiter, .{ io, &queue });
            defer cancelOutstanding(io, &queue, total - awaited.cancel(io));
            while (total < limit) : (total += 1) {
                var oneshot: std.Io.Queue(std.Io.Future(void)) = .init(&.{});
                try oneshot.putOne(io, try io.concurrent(handleAndEnqueue, .{ io, &oneshot, &queue, try server.accept(io), sleep }));
            }
        },
        // Spawn a fixed number of workers.
        // PROBLEM: this is just threads with extra steps! IO is supposed to manage this for us!
        // (Too few workers limits concurrency, too many workers wastes resources when not used.)
        .workers => {
            var buffer: [16]std.Io.net.Stream = undefined;
            var queue: std.Io.Queue(std.Io.net.Stream) = .init(&buffer);
            var workers: [4]std.Io.Future(void) = undefined;
            for (&workers) |*w| w.* = try io.concurrent(worker, .{ io, &queue, sleep });
            defer for (&workers) |*w| w.cancel(io);
            for (0..limit) |_| try queue.putOne(io, try server.accept(io));
        },
        // Use select to juggle 1 accept and N handlers.
        // PROBLEM: unbounded memory growth!
        .select => {
            const Item = union(enum) {
                connection: std.Io.net.Server.AcceptError!std.Io.net.Stream,
                handler: void,
            };
            var buffer: [16]Item = undefined;
            var select: std.Io.Select(Item) = .init(io, &buffer);
            defer select.cancel();
            var serviced: usize = 0;
            outer: while (true) {
                // TODO: Use select.concurrent once that's available.
                // See https://github.com/ziglang/zig/pull/26036#issuecomment-3572873009
                select.async(.connection, std.Io.net.Server.accept, .{ server, io });
                while (true) switch (try select.wait()) {
                    .connection => |stream| {
                        select.async(.handler, handle, .{ io, try stream, sleep });
                        break;
                    },
                    .handler => {
                        serviced += 1;
                        if (serviced == limit) break :outer;
                    },
                };
            }
        },
    }
}

// Used for Mode.waiter and Mode.waiter2.
// Returns the number of futures awaited.
fn waiter(io: std.Io, queue: *std.Io.Queue(std.Io.Future(void))) usize {
    var awaited: usize = 0;
    while (true) {
        var future = queue.getOne(io) catch |err| switch (err) {
            error.Canceled => return awaited,
        };
        future.await(io);
        awaited += 1;
    }
}

// Used for Mode.waiter and Mode.waiter2.
fn cancelOutstanding(io: std.Io, queue: *std.Io.Queue(std.Io.Future(void)), outstanding: usize) void {
    for (0..outstanding) |_| {
        var future = queue.getOneUncancelable(io);
        future.cancel(io);
    }
}

// Used for Mode.waiter2.
fn handleAndEnqueue(
    io: std.Io,
    oneshot: *std.Io.Queue(std.Io.Future(void)),
    queue: *std.Io.Queue(std.Io.Future(void)),
    stream: std.Io.net.Stream,
    sleep: std.Io.Duration,
) void {
    // Uncancelable because it should be there right away.
    const my_own_future = oneshot.getOneUncancelable(io);
    handle(io, stream, sleep);
    // Uncancelable because otherwise we leak the future.
    queue.putOneUncancelable(io, my_own_future);
}

// Used for Mode.workers.
fn worker(io: std.Io, queue: *std.Io.Queue(std.Io.net.Stream), sleep: std.Io.Duration) void {
    while (true) {
        const stream = queue.getOne(io) catch |err| switch (err) {
            error.Canceled => break,
        };
        handle(io, stream, sleep);
    }
}

fn handle(io: std.Io, stream: std.Io.net.Stream, sleep: std.Io.Duration) void {
    defer stream.close(io);
    var read_buffer: [1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var reader = &stream_reader.interface;
    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    var writer = &stream_writer.interface;
    _ = reader.streamRemaining(writer) catch |err| switch (err) {
        error.ReadFailed => std.log.err("streaming: read: {t}", .{stream_reader.err.?}),
        error.WriteFailed => std.log.err("streaming: write: {t}", .{stream_writer.err.?}),
    };
    writer.flush() catch std.log.err("flushing: {t}", .{stream_writer.err.?});
    io.sleep(sleep, .awake) catch |err| std.log.err("sleeping: {t}", .{err});
}
