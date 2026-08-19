const std = @import("std");

pub const StandardLogLevel = enum {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Fatal,
    pub fn color(self: @This()) []const u8 {
        return switch (self) {
            .Trace => "\x1b[35m", // Magenta
            .Debug => "\x1b[36m", // Cyan
            .Info => "\x1b[32m", // Green
            .Warn => "\x1b[33m", // Yellow
            .Error => "\x1b[31m", // Red
            .Fatal => "\x1b[1;31m", // Bold Red
        };
    }

    pub fn label(self: @This()) []const u8 {
        return switch (self) {
            .Trace => "TRACE",
            .Debug => "DEBUG",
            .Info => "INFO ",
            .Warn => "WARN ",
            .Error => "ERROR",
            .Fatal => "FATAL",
        };
    }
};

pub const ThreadMode = enum { single_thread, multi_thread };

const BaseRecordConfig = struct {
    max_dynamic_msg_len: usize = 16,
};
const RecordConfig = struct {
    thread_mode: ThreadMode = .single_thread,
    base_record_config: BaseRecordConfig = .{},
};

fn BaseRecord(LogLevel: type, comptime config: BaseRecordConfig) type {
    return struct {
        source: std.builtin.SourceLocation,
        level: LogLevel,
        real_timestamp: std.Io.Clock.Timestamp,
        msg: union(enum) {
            allocated: []u8,
            dynamic: struct { buf: [config.max_dynamic_msg_len]u8, len: usize },
            static: []const u8,
        },
        pub fn getMsg(self: *const @This()) []const u8 {
            return switch (self.msg) {
                .allocated => |str| str,
                .dynamic => |d_str| d_str.buf[0..d_str.len],
                .static => |str| str,
            };
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.msg) {
                .allocated => |str| allocator.free(str),
                else => {},
            }
        }
    };
}
fn Record(LogLevel: type, comptime config: RecordConfig) type {
    return struct {
        base_record: BaseRecord(LogLevel, config),
        ready: if (config.thread_mode == .multi_thread) std.atomic.Value(bool) else void,
    };
}

pub fn standartFormatWriteFn(io: std.Io, allocator: std.mem.Allocator, writer: std.Io.Writer, base_record: anytype) void {
    _ = allocator;
    _ = io;
    const error_label: []const u8 = base_record.level.label();
    // const error_color: []const u8 = base_record.level.color(); // TODO: implement

    const source_file = base_record.source.file;
    const source_line = base_record.source.line;
    const source_fn = base_record.source.fn_name;
    const msg = base_record.getMsg();
    writer.print("{d} - [{s}] - in {s}:{} fn:{s} - {s}\n", .{
        base_record.real_timestamp,
        error_label,
        source_file,
        source_line,
        source_fn,
        msg,
    }) catch |err| {
        std.debug.print("LOG ERROR: {}\n", .{err});
    };
}

pub const LoggerConfig = struct {
    thread_mode: ThreadMode = .single_thread,
    base_record_config: BaseRecordConfig = .{},
};

pub fn Logger(LogLevel: type, comptime max_dynamic_msg_len: usize, comptime config: LoggerConfig) type {
    return struct {
        const LogBaseRecord: type = BaseRecord(LogLevel, config.base_record_config);
        const LogRecord: type = Record(LogLevel, .{ .base_record_config = config.base_record_config, .thread_mode = config.thread_mode });
        records_buffer: []Record(LogLevel, max_dynamic_msg_len, .{ .thread_mode = config.thread_mode }),

        start: std.atomic.Value(usize) = .init(0),
        end: std.atomic.Value(usize) = .init(0),
        worker_futex: std.atomic.Value(u32) = .init(0),
        log_futex: std.atomic.Value(u32) = .init(0),
        worker_handler: std.Thread,
        worker_status: std.atomic.Value(enum { work, finish }) = .init(.work),

        log_format_fn: fn (io: std.Io, allocator: std.mem.Allocator, writer: std.Io.Writer, base_record: *const BaseRecord(LogLevel, RecordConfig)) void,

        fn worker(io: std.Io, allocator: std.mem.Allocator, self: *@This(), writer: std.Io.Writer) void { // TODO: optimize
            while (true) {
                const start = self.start.load(.monotonic);
                const end = self.end.load(.acquire);
                if (start == end) {
                    if (self.worker_status.load(.monotonic) == .finish) {
                        return;
                    }
                    const waker = self.worker_futex.load(.acquire);
                    if (self.start.load(.monotonic) == self.end.load(.acquire)) {
                        io.futexWaitUncancelable(usize, &self.worker_futex.raw, waker);
                    }
                    continue;
                }
                const index = self.start.fetchAdd(1, .release) % self.records_buffer.len;
                const record = &self.records_buffer[index];
                const base_record = &record.base_record;
                self.log_format_fn(io, allocator, writer, base_record) catch |err| self.log_format_error_handler(err);
                if (config.thread_mode == .multi_thread) {
                    record.ready.store(false, .monotonic);
                }
                self.log_futex.fetchAdd(1, .release);
                io.futexWake(u32, &self.log_futex, 1);
            }
        }

        pub fn log(self: *@This(), io: std.Io, log_level: LogLevel, comptime fmt: []const u8, args: anytype) void {
            const start = self.start.load(.acquire);
            const end = self.end.load(.monotonic);
            if (start + 1 == end) {
                const waker = self.log_futex.load(.acquire);
                while (self.start.load(.acquire) + 1 == self.end.load(.monotonic)) {
                    io.futexWaitUncancelable(u32, &self.log_futex, waker);
                }
            }
        }
        pub fn init(io: std.Io, allocator: std.mem.Allocator, recodrs_buffer: []Record, writer: std.Io.Writer) (std.Thread.SpawnError | std.mem.Allocator.Error)!*@This() { // TODO: remove allocation for Logger
            var self = try allocator.create(@This());
            self.records_buffer = recodrs_buffer;
            self.worker_handler = try std.Thread.spawn(.{}, worker, .{ io, allocator, self, writer });
            return self;
        }
        pub fn deinit(self: *@This()) void {
            self.worker_status.store(.finish, .monotonic);
            defer self.worker_handler.join();
        }
    };
}
