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
    };
}
fn Record(LogLevel: type, comptime config: RecordConfig) type {
    return struct {
        base_record: BaseRecord(LogLevel, config),
        ready: if (config.thread_mode == .multi_thread) std.atomic.Value(bool) else void,
    };
}

pub fn standartFormatWriteFn(LogLevel: type, comptime base_record_config: BaseRecordConfig, allocator: std.mem.Allocator, writer: std.Io.Writer, base_record: BaseRecord(LogLevel, base_record_config)) (std.mem.Allocator.Error | std.Io.Writer.Error)!void {
    const error_label: []const u8 = base_record.level.label();
    // const error_color: []const u8 = base_record.level.color(); // TODO:

    const source_file = base_record.source.file;
    const source_line = base_record.source.line;
    const source_fn = base_record.source.fn_name;
    const msg: []const u8 = switch (base_record.msg) {
        .allocated => |str| str,
        .dynamic => |d_str| d_str.buf[0..d_str.len],
        .static => |str| str,
    };
    try writer.print("{d} - [{s}] - in {s}:{} fn:{s} - {s}", .{
        base_record.real_timestamp,
        error_label,
        source_file,
        source_line,
        source_fn,
        msg,
    });
}

pub const LoggerConfig = struct {
    thread_mode: ThreadMode = .single_thread,
};

pub fn Logger(LogLevel: type, comptime max_dynamic_msg_len: usize, comptime config: LoggerConfig) type {
    return struct {
        // record_config
        records_buffer: []Record(LogLevel, max_dynamic_msg_len, .{ .thread_mode = config.thread_mode }),

        start: std.atomic.Value(usize) = .init(0),
        end: std.atomic.Value(usize) = .init(0),
        futex_waker: std.atomic.Value(usize) = .init(0),
        worker_handler: std.Thread,

        log_format_fn: fn (allocator: std.mem.Allocator, writer: std.Io.Writer, base_record: BaseRecord(LogLevel, RecordConfig)) std.Io.Writer.Error!void,

        config: struct {
            //
        },
        fn worker(io: std.Io, allocator: std.mem.Allocator, self: *@This(), writer: std.Io.Writer) void {
            while (true) {
                const start = self.start.load(.monotonic);
                const end = self.end.load(.acquire);
                if (start == end) {
                    const waker = self.futex_waker.load(.acquire);
                    if (self.start.load(.monotonic) == self.end.load(.acquire)) {
                        io.futexWaitUncancelable(usize, &self.futex_waker.raw, waker);
                    }
                    continue;
                }
                const index = self.start.fetchAdd(1, .monotonic);
                const record = self.records_buffer[index];
            }
        }
        pub fn init(allocator: std.mem.Allocator, io: std.Io, recodrs_buffer: []Record, writer: std.Io.Writer) (std.Thread.SpawnError | std.mem.Allocator.Error)!*@This() {
            var self = try allocator.create(@This());
            self.records_buffer = recodrs_buffer;
            self.worker_handler = try std.Thread.spawn(.{}, worker, .{ io, allocator, self, writer });
            return self;
        }
    };
}
