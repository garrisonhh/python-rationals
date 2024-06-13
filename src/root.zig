const std = @import("std");
const big = std.math.big;

const log = std.log.scoped(.rational);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const ally = gpa.allocator();

const Id = enum(c_uint) { _ };

const Pool = struct {
    const Self = @This();

    const Entry = struct {
        refs: u32,
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
            self.items.items(.refs)[@intFromEnum(id)] = 1;
            self.items.items(.rational)[@intFromEnum(id)] = value;

            return id;
        } else {
            const id: Id = @enumFromInt(self.items.len);
            try self.items.append(ally, .{
                .refs = 1,
                .rational = value,
            });

            return id;
        }
    }

    /// increment id reference count
    fn ref(self: *Self, id: Id) void {
        std.debug.assert(self.items.items(.refs)[@intFromEnum(id)] > 0);
	self.items.items(.refs)[@intFromEnum(id)] += 1;
    }

    /// decrement id reference count
    fn del(self: *Self, id: Id) void {
        const refs = &self.items.items(.refs)[@intFromEnum(id)];
        std.debug.assert(refs.* > 0);
        refs.* -= 1;
        if (refs.* == 0) {
            self.items.items(.rational)[@intFromEnum(id)].deinit();
        }
    }

    /// get a value when you know it's arefs
    fn mustGet(self: *const Self, id: Id) *big.Rational {
        std.debug.assert(self.items.items(.refs)[@intFromEnum(id)] > 0);
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
        if (self.items.items(.refs)[n] == 0) {
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

fn check(x: anytype) @TypeOf(x) {
    comptime std.debug.assert(@typeInfo(@TypeOf(x)) == .ErrorUnion);
    return x catch |e| {
        log.err("error: {s}", .{@errorName(e)});
        return e;
    };
}

/// a null ptr means an error happened
const String = extern struct {
    const Err = String{ .len = 0, .ptr = null };

    len: c_uint,
    ptr: ?[*:0]const u8,
};

export fn to_string(id: c_long) String {
    const value = check(pool.getFfi(id)) catch return String.Err;
    const q_str = check(value.q.toString(ally, 10, .upper)) catch return String.Err;
    defer ally.free(q_str);
    const p_str = check(value.p.toString(ally, 10, .upper)) catch return String.Err;
    defer ally.free(p_str);

    const cstr = check(std.fmt.allocPrintZ(ally, "{s}/{s}", .{ p_str, q_str })) catch {
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
    const id = check(pool.fromFloat(value)) catch return -1;
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
    const rational = check(pool.getFfi(id)) catch return ToFloatResult.Err;
    const float = check(rational.toFloat(f64)) catch return ToFloatResult.Err;
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
            const x = check(pool.getFfi(a)) catch return -1;
            const y = check(pool.getFfi(b)) catch return -1;

            var res = check(big.Rational.init(ally)) catch return -1;
            check(func(&res, x.*, y.*)) catch return -1;
            const id = check(pool.new(res)) catch return -1;

            return @intFromEnum(id);
        }
    }.f;
}

export fn add(a: c_long, b: c_long) c_long {
    return threeway(big.Rational.add)(a, b);
}

export fn sub(a: c_long, b: c_long) c_long {
    return threeway(big.Rational.sub)(a, b);
}

export fn mul(a: c_long, b: c_long) c_long {
    const a_id = check(pool.idFromInt(a)) catch return -1;
    const x = pool.mustGet(a_id);
    if (x.p.eqlZero()) {
        pool.ref(a_id);
        return a;
    }

    const b_id = check(pool.idFromInt(b)) catch return -1;
    const y = pool.mustGet(b_id);
    if (y.p.eqlZero()) {
        pool.ref(b_id);
        return b;
    }

    var res = check(big.Rational.init(ally)) catch return -1;
    check(big.Rational.mul(&res, x.*, y.*)) catch return -1;
    const id = check(pool.new(res)) catch return -1;

    return @intFromEnum(id);
}

export fn div(a: c_long, b: c_long) c_long {
    const a_id = check(pool.idFromInt(a)) catch return -1;
    const x = pool.mustGet(a_id);
    if (x.p.eqlZero()) {
        pool.ref(a_id);
        return a;
    }
    const y = check(pool.getFfi(b)) catch return -1;
    if (y.p.eqlZero()) return -1;

    var res = check(big.Rational.init(ally)) catch return -1;
    check(big.Rational.div(&res, x.*, y.*)) catch return -1;
    const id = check(pool.new(res)) catch return -1;

    return @intFromEnum(id);
}

/// returns:
/// - negative if this is an invalid id
/// - 1 if a is zero
/// - 0 if a is not zero
export fn is_zero(a: c_long) c_int {
    const x = check(pool.getFfi(a)) catch return -1;
    return @intFromBool(x.p.eqlZero());
}
