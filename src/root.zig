const std = @import("std");
const big = std.math.big;

const log = std.log.scoped(.rational);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const ally = gpa.allocator();

const Id = enum(c_uint) { _ };

const Pool = struct {
    const Self = @This();

    const Entry = struct {
        live: bool = true,
        rational: big.Rational,
    };

    const order_ids = struct {
        fn order(_: void, a: Id, b: Id) std.math.Order {
            return std.math.order(@intFromEnum(a), @intFromEnum(b));
        }
    }.order;
    const FreeQueue = std.PriorityQueue(Id, void, order_ids);

    items: std.MultiArrayList(Entry) = .{},
    free: FreeQueue,

    fn init() Self {
        return Self{
            .free = FreeQueue.init(ally, {}),
        };
    }

    fn deinit(self: *Self) void {
        self.items.deinit(ally);
        self.free.deinit();
    }

    fn fromFloat(self: *Self, value: f64) !Id {
        var r = try big.Rational.init(ally);
        try r.setFloat(f64, value);
        return try self.new(r);
    }

    fn new(self: *Self, value: big.Rational) !Id {
        if (self.free.removeOrNull()) |id| {
            self.items.items(.live)[@intFromEnum(id)] = true;
            self.items.items(.rational)[@intFromEnum(id)] = value;

            return id;
        } else {
            const id: Id = @enumFromInt(self.items.len);
            try self.items.append(ally, .{
                .rational = value,
            });

            return id;
        }
    }

    fn del(self: *Self, id: Id) void {
        self.items.items(.live)[@intFromEnum(id)] = false;
        self.items.items(.rational)[@intFromEnum(id)].deinit();
    }

    /// get a value when you know it's alive
    fn mustGet(self: *const Self, id: Id) *big.Rational {
        std.debug.assert(self.items.items(.live)[@intFromEnum(id)]);
        return &self.items.items(.rational)[@intFromEnum(id)];
    }

    const IdError = error{
        InvalidValue,
        InvalidId,
        DeadId,
    };

    fn idFromInt(self: *const Self, ffi_val: c_long) IdError!Id {
        const TagInt = @typeInfo(Id).Enum.tag_type;
        if (ffi_val < 0 or ffi_val > std.math.maxInt(TagInt)) {
            return IdError.InvalidValue;
        }

        const n: TagInt = @intCast(ffi_val);
        if (n >= self.items.len) {
            return IdError.InvalidId;
        }
        if (!self.items.items(.live)[n]) {
            return IdError.DeadId;
        }
        return @enumFromInt(n);
    }

    /// get a value from a c function when you don't know if it's valid
    fn getFfi(self: *const Self, ffi_val: c_long) IdError!*big.Rational {
        const id = try self.idFromInt(ffi_val);
        return self.mustGet(id);
    }
};

var pool: Pool = undefined;

export fn init() void {
    pool = Pool.init();
}

export fn deinit() void {
    pool.deinit();
    _ = gpa.deinit();
}

export fn delete(id: c_long) void {
    pool.del(@enumFromInt(id));
}

/// a null ptr means an error happened
const String = extern struct {
    const Err = String{ .len = 0, .ptr = null };

    len: c_uint,
    ptr: ?[*:0]const u8,
};

export fn to_string(id: c_long) String {
    const value = pool.getFfi(id) catch return String.Err;
    const q_str = value.q.toString(ally, 10, .upper) catch return String.Err;
    defer ally.free(q_str);
    const p_str = value.p.toString(ally, 10, .upper) catch return String.Err;
    defer ally.free(p_str);

    const cstr = std.fmt.allocPrintZ(ally, "{s}/{s}", .{ p_str, q_str }) catch {
        return String.Err;
    };
    return .{
        .len = @intCast(cstr.len),
        .ptr = cstr.ptr,
    };
}

export fn free_string(str: String) void {
    if (str.ptr) |ptr| {
        ally.free(ptr[0..str.len :0]);
    }
}

/// returns a valid id or -1 for error
export fn from_float(value: f64) c_long {
    const id = pool.fromFloat(value) catch return -1;
    return @intFromEnum(id);
}

const ToFloatResult = extern struct {
    const Err = ToFloatResult{
        .valid = false,
        .value = undefined,
    };

    valid: bool,
    value: f64,
};

export fn to_float(id: c_long) ToFloatResult {
    const rational = pool.getFfi(id) catch return ToFloatResult.Err;
    const float = rational.toFloat(f64) catch return ToFloatResult.Err;
    return .{
        .valid = true,
        .value = float,
    };
}

/// given a 3-way operator, produce a function performing this operation on pool
/// ids, returning a negative value on error
fn threeway(
    comptime func: fn (
        out: *big.Rational,
        big.Rational,
        big.Rational,
    ) std.mem.Allocator.Error!void,
) fn (c_long, c_long) c_long {
    return struct {
        fn f(a: c_long, b: c_long) c_long {
            const x = pool.getFfi(a) catch return -1;
            const y = pool.getFfi(b) catch return -1;

            var res = big.Rational.init(ally) catch return -1;
            func(&res, x.*, y.*) catch return -1;
            const id = pool.new(res) catch return -1;

            return @intFromEnum(id);
        }
    }.f;
}

export fn add(a: c_long, b: c_long) c_long {
    return threeway(big.Rational.add)(a, b);
}

export fn mul(a: c_long, b: c_long) c_long {
    return threeway(big.Rational.mul)(a, b);
}

export fn div(a: c_long, b: c_long) c_long {
    return threeway(big.Rational.div)(a, b);
}
