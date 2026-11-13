const std = @import("std");
const pattern = @import("../../vendor/fx/src/core/mcp/json_schema_pattern.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
pub const Document = struct { path: []const u8, value: Value };
pub const Diagnostic = struct { path: []const u8 = "", message: []const u8 = "" };
pub const Error = error{ InvalidSchema, UnsupportedSchema, UnresolvedSchema, InvalidValue, SchemaLimit, OutOfMemory };
const pattern_limits: pattern.Limits = .{ .max_depth = 64, .max_states = 2048, .max_repeat = 256, .max_steps = 200_000 };

pub fn parse(alloc: Allocator, bytes: []const u8) !Value {
    return parseBounded(alloc, bytes, 1024 * 1024);
}
/// Strict parsing for a bounded transport envelope; domain inputs remain 1 MiB.
pub fn parseBounded(alloc: Allocator, bytes: []const u8, limit: usize) !Value {
    if (bytes.len > limit) return error.DocumentLimit;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidJson;
    // Bound depth before allocating a tree. Zig's strict parser rejects duplicate
    // keys, comments, trailing commas and malformed numbers.
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 128) return error.DocumentLimit;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    var value = try std.json.parseFromSliceLeaky(Value, alloc, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = 1024 * 1024 });
    try finite(&value);
    return value;
}
fn finite(value: *Value) !void {
    switch (value.*) {
        .float => |n| if (!std.math.isFinite(n)) {
            return error.InvalidJson;
        },
        .number_string => |s| {
            const n = std.fmt.parseFloat(f64, s) catch return error.InvalidJson;
            if (!std.math.isFinite(n)) return error.InvalidJson;
            value.* = .{ .float = n };
        },
        .array => |arr| for (arr.items) |*v| {
            try finite(v);
        },
        .object => |obj| for (obj.values()) |*v| {
            try finite(v);
        },
        else => {},
    }
}
pub fn get(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
pub fn string(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
fn number(value: Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => null,
    };
}
pub fn equal(a: Value, b: Value) bool {
    if (number(a)) |n| if (number(b)) |m| return n == m;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!equal(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |e| {
                const v = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!equal(e.value_ptr.*, v)) break :blk false;
            }
            break :blk true;
        },
    };
}
pub fn pointer(alloc: Allocator, root: Value, path: []const u8) !Value {
    if (path.len == 0) return root;
    if (path[0] != '/') return error.InvalidPointer;
    var current = root;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(alloc);
        var i: usize = 0;
        while (i < part.len) : (i += 1) {
            if (part[i] != '~') {
                try decoded.append(alloc, part[i]);
                continue;
            }
            i += 1;
            if (i == part.len) return error.InvalidPointer;
            try decoded.append(alloc, switch (part[i]) {
                '0' => '~',
                '1' => '/',
                else => return error.InvalidPointer,
            });
        }
        current = switch (current) {
            .object => |obj| obj.get(decoded.items) orelse return error.MissingPointer,
            .array => |arr| blk: {
                if (decoded.items.len == 0 or (decoded.items.len > 1 and decoded.items[0] == '0')) return error.InvalidPointer;
                for (decoded.items) |c| if (!std.ascii.isDigit(c)) return error.InvalidPointer;
                const index = std.fmt.parseInt(usize, decoded.items, 10) catch return error.InvalidPointer;
                if (index >= arr.items.len) return error.MissingPointer;
                break :blk arr.items[index];
            },
            else => return error.MissingPointer,
        };
    }
    return current;
}

pub const Registry = struct {
    alloc: Allocator,
    documents: []const Document,
    diagnostic: Diagnostic = .{},
    work: usize = 0,
    checked: std.AutoHashMapUnmanaged(usize, void) = .{},

    fn tick(self: *Registry, depth: usize) Error!void {
        self.work += 1;
        if (depth > 128 or self.work > 200_000) return error.SchemaLimit;
    }
    fn reject(self: *Registry, path: []const u8, message: []const u8) Error {
        self.diagnostic = .{ .path = path, .message = message };
        return error.InvalidValue;
    }
    fn child(self: *Registry, path: []const u8, key: []const u8) Error![]const u8 {
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(self.alloc);
        for (key) |c| switch (c) {
            '~' => try escaped.appendSlice(self.alloc, "~0"),
            '/' => try escaped.appendSlice(self.alloc, "~1"),
            else => try escaped.append(self.alloc, c),
        };
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ path, escaped.items });
    }
    const Resolved = struct { schema: Value, document: []const u8, root: Value };
    pub fn resolve(self: *Registry, reference: []const u8, base: []const u8, root: Value) Error!Resolved {
        const hash = std.mem.indexOfScalar(u8, reference, '#') orelse reference.len;
        const uri = reference[0..hash];
        const fragment = if (hash == reference.len) "" else reference[hash + 1 ..];
        var selected = root;
        var document = base;
        if (uri.len != 0) {
            var found = false;
            for (self.documents) |doc| {
                const identifier = if (get(doc.value, "$id")) |id| string(id) else null;
                if (std.mem.eql(u8, doc.path, uri) or (identifier != null and std.mem.eql(u8, identifier.?, uri))) {
                    selected = doc.value;
                    document = doc.path;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (std.mem.indexOf(u8, uri, ":") != null or std.mem.startsWith(u8, uri, "/") or std.mem.indexOfScalar(u8, uri, '\\') != null) return error.UnresolvedSchema;
                const parent = std.fs.path.dirname(base) orelse "";
                const path = std.fs.path.resolve(self.alloc, &.{ "/", parent, uri }) catch return error.OutOfMemory;
                for (self.documents) |doc| if (std.mem.eql(u8, doc.path, path[1..])) {
                    selected = doc.value;
                    document = doc.path;
                    found = true;
                    break;
                };
                if (!found) return error.UnresolvedSchema;
            }
        }
        if (fragment.len != 0) {
            if (fragment[0] == '/') selected = pointer(self.alloc, selected, fragment) catch return error.UnresolvedSchema else selected = (try self.anchor(selected, fragment, 0)) orelse return error.UnresolvedSchema;
        }
        return .{ .schema = selected, .document = document, .root = if (uri.len == 0) root else blk: {
            for (self.documents) |d| if (std.mem.eql(u8, d.path, document)) break :blk d.value;
            return error.UnresolvedSchema;
        } };
    }
    fn anchor(self: *Registry, value: Value, name: []const u8, depth: usize) Error!?Value {
        try self.tick(depth);
        if (value == .object) {
            if (get(value, "$anchor")) |v| if (string(v)) |s| if (std.mem.eql(u8, s, name)) return value;
            for (value.object.values()) |v| if (try self.anchor(v, name, depth + 1)) |found| return found;
        } else if (value == .array) for (value.array.items) |v| {
            if (try self.anchor(v, name, depth + 1)) |found| return found;
        };
        return null;
    }
    pub fn check(self: *Registry, schema: Value, document: []const u8) Error!void {
        self.work = 0;
        self.checked.clearRetainingCapacity();
        try self.checkNode(schema, document, schema, 0);
    }
    fn checkNode(self: *Registry, schema: Value, document: []const u8, root: Value, depth: usize) Error!void {
        try self.tick(depth);
        if (schema == .bool) return;
        if (schema != .object) return error.InvalidSchema;
        const identity = @intFromPtr(schema.object.keys().ptr);
        const checked_entry = try self.checked.getOrPut(self.alloc, identity);
        if (checked_entry.found_existing) return;
        const keywords = [_][]const u8{ "$schema", "$id", "$anchor", "$ref", "$defs", "definitions", "type", "enum", "const", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "$comment", "format", "contentEncoding", "contentMediaType", "contentSchema", "properties", "patternProperties", "additionalProperties", "required", "dependentRequired", "dependentSchemas", "propertyNames", "minProperties", "maxProperties", "items", "prefixItems", "minItems", "maxItems", "uniqueItems", "contains", "minContains", "maxContains", "minLength", "maxLength", "pattern", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "allOf", "anyOf", "oneOf", "not", "if", "then", "else" };
        for (schema.object.keys()) |key| {
            var supported = false;
            for (keywords) |known| if (std.mem.eql(u8, key, known)) {
                supported = true;
                break;
            };
            if (!supported) return error.UnsupportedSchema;
        }
        if (get(schema, "$schema")) |v| {
            const s = string(v) orelse return error.InvalidSchema;
            if (!std.mem.eql(u8, s, "https://json-schema.org/draft/2020-12/schema")) return error.UnsupportedSchema;
        }
        if (get(schema, "$id")) |v| {
            _ = string(v) orelse return error.InvalidSchema;
            if (depth != 0) return error.UnsupportedSchema;
        }
        if (get(schema, "$ref")) |v| {
            const ref = string(v) orelse return error.InvalidSchema;
            const resolved = try self.resolve(ref, document, root);
            try self.checkNode(resolved.schema, resolved.document, resolved.root, depth + 1);
        }
        if (get(schema, "type")) |t| {
            if (t == .array) {
                if (t.array.items.len == 0) return error.InvalidSchema;
                for (t.array.items) |v| try checkType(v);
            } else try checkType(t);
        }
        if (get(schema, "enum")) |v| {
            if (v != .array or v.array.items.len == 0 or v.array.items.len > 1024) return error.InvalidSchema;
            for (v.array.items, 0..) |a, i| for (v.array.items[0..i]) |b| {
                if (equal(a, b)) return error.InvalidSchema;
            };
        }
        inline for (.{ "minLength", "maxLength", "minItems", "maxItems", "minContains", "maxContains", "minProperties", "maxProperties" }) |k| if (get(schema, k)) |v| {
            if (v != .integer or v.integer < 0) return error.InvalidSchema;
        };
        inline for (.{ "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf" }) |k| if (get(schema, k)) |v| {
            const n = number(v) orelse return error.InvalidSchema;
            if (!std.math.isFinite(n) or (std.mem.eql(u8, k, "multipleOf") and n <= 0)) return error.InvalidSchema;
        };
        if (get(schema, "uniqueItems")) |v| if (v != .bool) return error.InvalidSchema;
        inline for (.{ "title", "description", "$comment", "format", "$anchor", "contentEncoding", "contentMediaType" }) |k| if (get(schema, k)) |v| {
            if (v != .string) return error.InvalidSchema;
        };
        inline for (.{ "deprecated", "readOnly", "writeOnly" }) |k| if (get(schema, k)) |v| {
            if (v != .bool) return error.InvalidSchema;
        };
        if (get(schema, "examples")) |v| if (v != .array) return error.InvalidSchema;

        if (get(schema, "pattern")) |v| {
            const s = string(v) orelse return error.InvalidSchema;
            pattern.validate(self.alloc, s, pattern_limits) catch return error.UnsupportedSchema;
        }
        inline for (.{"required"}) |k| if (get(schema, k)) |v| try stringArray(v);
        if (get(schema, "dependentRequired")) |v| {
            if (v != .object) return error.InvalidSchema;
            for (v.object.values()) |arr| try stringArray(arr);
        }
        inline for (.{ "items", "contains", "additionalProperties", "propertyNames", "not", "if", "then", "else", "contentSchema" }) |k| if (get(schema, k)) |v| try self.checkNode(v, document, root, depth + 1);
        inline for (.{ "properties", "patternProperties", "dependentSchemas", "$defs", "definitions" }) |k| if (get(schema, k)) |map| {
            if (map != .object) return error.InvalidSchema;
            var it = map.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, k, "patternProperties")) pattern.validate(self.alloc, entry.key_ptr.*, pattern_limits) catch return error.UnsupportedSchema;
                try self.checkNode(entry.value_ptr.*, document, root, depth + 1);
            }
        };
        inline for (.{ "allOf", "anyOf", "oneOf", "prefixItems" }) |k| if (get(schema, k)) |list| {
            if (list != .array or (list.array.items.len == 0 and !std.mem.eql(u8, k, "prefixItems"))) return error.InvalidSchema;
            for (list.array.items) |v| try self.checkNode(v, document, root, depth + 1);
        };
    }
    pub fn validate(self: *Registry, schema: Value, document: []const u8, data: Value) Error!void {
        self.work = 0;
        self.diagnostic = .{};
        try self.visit(schema, document, schema, data, "", 0);
    }
    fn matches(self: *Registry, schema: Value, document: []const u8, root: Value, data: Value, path: []const u8, depth: usize) Error!bool {
        self.visit(schema, document, root, data, path, depth) catch |err| {
            if (err == error.InvalidValue) return false;
            return err;
        };
        return true;
    }
    fn visit(self: *Registry, schema: Value, document: []const u8, root: Value, data: Value, path: []const u8, depth: usize) Error!void {
        try self.tick(depth);
        if (schema == .bool) {
            if (!schema.bool) return self.reject(path, "Value is forbidden by schema.");
            return;
        }
        if (schema != .object) return error.InvalidSchema;
        if (get(schema, "$ref")) |v| {
            const target = try self.resolve(string(v) orelse return error.InvalidSchema, document, root);
            try self.visit(target.schema, target.document, target.root, data, path, depth + 1);
        }
        if (get(schema, "type")) |t| {
            var valid = false;
            if (t == .array) {
                for (t.array.items) |v| if (hasType(data, string(v) orelse return error.InvalidSchema)) {
                    valid = true;
                    break;
                };
            } else valid = hasType(data, string(t) orelse return error.InvalidSchema);
            if (!valid) return self.reject(path, "Value has the wrong type.");
        }
        if (get(schema, "const")) |v| if (!equal(v, data)) return self.reject(path, "Value does not match const.");
        if (get(schema, "enum")) |list| {
            var valid = false;
            for (list.array.items) |v| if (equal(v, data)) {
                valid = true;
                break;
            };
            if (!valid) return self.reject(path, "Value is outside enum.");
        }
        inline for (.{ "allOf", "anyOf", "oneOf" }) |k| if (get(schema, k)) |list| {
            var count: usize = 0;
            for (list.array.items) |s| {
                if (try self.matches(s, document, root, data, path, depth + 1)) count += 1;
            }
            if ((std.mem.eql(u8, k, "allOf") and count != list.array.items.len) or (std.mem.eql(u8, k, "anyOf") and count == 0) or (std.mem.eql(u8, k, "oneOf") and count != 1)) return self.reject(path, "Value does not satisfy schema alternatives.");
        };
        if (get(schema, "not")) |s| if (try self.matches(s, document, root, data, path, depth + 1)) return self.reject(path, "Value matches a forbidden schema.");
        if (get(schema, "if")) |s| {
            const branch = if (try self.matches(s, document, root, data, path, depth + 1)) "then" else "else";
            if (get(schema, branch)) |v| try self.visit(v, document, root, data, path, depth + 1);
        }
        switch (data) {
            .string => |s| {
                const n = std.unicode.utf8CountCodepoints(s) catch return error.InvalidValue;
                if (below(schema, "minLength", n) or above(schema, "maxLength", n)) return self.reject(path, "String length is outside its bounds.");
                if (get(schema, "pattern")) |v| {
                    var steps: usize = 0;
                    const ok = pattern.matches(self.alloc, v.string, s, pattern_limits, &steps) catch return error.SchemaLimit;
                    self.work += steps;
                    try self.tick(depth);
                    if (!ok) return self.reject(path, "String does not match pattern.");
                }
            },
            .integer, .float => {
                const n = number(data).?;
                if (get(schema, "minimum")) |v| if (n < number(v).?) return self.reject(path, "Number is below minimum.");
                if (get(schema, "maximum")) |v| if (n > number(v).?) return self.reject(path, "Number exceeds maximum.");
                if (get(schema, "exclusiveMinimum")) |v| if (n <= number(v).?) return self.reject(path, "Number is below exclusiveMinimum.");
                if (get(schema, "exclusiveMaximum")) |v| if (n >= number(v).?) return self.reject(path, "Number exceeds exclusiveMaximum.");
                if (get(schema, "multipleOf")) |v| {
                    const q = n / number(v).?;
                    if (@abs(q - @round(q)) > @max(1, @abs(q)) * 1e-12) return self.reject(path, "Number is not a multipleOf.");
                }
            },
            .array => |arr| {
                if (below(schema, "minItems", arr.items.len) or above(schema, "maxItems", arr.items.len)) return self.reject(path, "Array size is outside its bounds.");
                if (get(schema, "uniqueItems")) |v| if (v.bool) {
                    for (arr.items, 0..) |a, i| for (arr.items[0..i]) |b| {
                        try self.tick(depth);
                        if (equal(a, b)) return self.reject(path, "Array contains duplicate items.");
                    };
                };
                const prefix = get(schema, "prefixItems");
                for (arr.items, 0..) |v, i| {
                    const p = try std.fmt.allocPrint(self.alloc, "{s}/{d}", .{ path, i });
                    if (prefix != null and i < prefix.?.array.items.len) try self.visit(prefix.?.array.items[i], document, root, v, p, depth + 1) else if (get(schema, "items")) |s| try self.visit(s, document, root, v, p, depth + 1);
                }
                if (get(schema, "contains")) |s| {
                    var count: usize = 0;
                    for (arr.items) |v| if (try self.matches(s, document, root, v, path, depth + 1)) {
                        count += 1;
                    };
                    const min = if (get(schema, "minContains")) |v| @as(usize, @intCast(v.integer)) else 1;
                    if (count < min or above(schema, "maxContains", count)) return self.reject(path, "Array contains count is outside its bounds.");
                }
            },
            .object => |obj| {
                if (below(schema, "minProperties", obj.count()) or above(schema, "maxProperties", obj.count())) return self.reject(path, "Object size is outside its bounds.");
                if (get(schema, "required")) |v| for (v.array.items) |key| {
                    if (!obj.contains(key.string)) return self.reject(try self.child(path, key.string), "Required property is missing.");
                };
                const props = get(schema, "properties");
                const patterns = get(schema, "patternProperties");
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const p = try self.child(path, key);
                    var known = false;
                    if (props) |map| if (map.object.get(key)) |s| {
                        known = true;
                        try self.visit(s, document, root, entry.value_ptr.*, p, depth + 1);
                    };
                    if (patterns) |map| {
                        var pi = map.object.iterator();
                        while (pi.next()) |e| {
                            var steps: usize = 0;
                            const ok = pattern.matches(self.alloc, e.key_ptr.*, key, pattern_limits, &steps) catch return error.SchemaLimit;
                            self.work += steps;
                            if (ok) {
                                known = true;
                                try self.visit(e.value_ptr.*, document, root, entry.value_ptr.*, p, depth + 1);
                            }
                        }
                    }
                    if (!known) if (get(schema, "additionalProperties")) |s| try self.visit(s, document, root, entry.value_ptr.*, p, depth + 1);
                    if (get(schema, "propertyNames")) |s| try self.visit(s, document, root, .{ .string = key }, p, depth + 1);
                }
                if (get(schema, "dependentRequired")) |map| {
                    var di = map.object.iterator();
                    while (di.next()) |e| if (obj.contains(e.key_ptr.*)) {
                        for (e.value_ptr.array.items) |k| if (!obj.contains(k.string)) return self.reject(try self.child(path, k.string), "Dependent property is missing.");
                    };
                }
                if (get(schema, "dependentSchemas")) |map| {
                    var di = map.object.iterator();
                    while (di.next()) |e| if (obj.contains(e.key_ptr.*)) {
                        try self.visit(e.value_ptr.*, document, root, data, path, depth + 1);
                    };
                }
            },
            else => {},
        }
    }
};
fn checkType(value: Value) Error!void {
    const s = string(value) orelse return error.InvalidSchema;
    for ([_][]const u8{ "object", "array", "string", "integer", "number", "boolean", "null" }) |known| if (std.mem.eql(u8, s, known)) return;
    return error.InvalidSchema;
}
fn stringArray(value: Value) Error!void {
    if (value != .array or value.array.items.len > 1024) return error.InvalidSchema;
    for (value.array.items, 0..) |v, i| {
        _ = string(v) orelse return error.InvalidSchema;
        for (value.array.items[0..i]) |prior| if (equal(prior, v)) return error.InvalidSchema;
    }
}
fn hasType(value: Value, name: []const u8) bool {
    if (std.mem.eql(u8, name, "number")) return number(value) != null;
    if (std.mem.eql(u8, name, "integer")) return value == .integer or (value == .float and @trunc(value.float) == value.float);
    const tag = switch (value) {
        .bool => "boolean",
        .number_string => "number",
        else => @tagName(value),
    };
    return std.mem.eql(u8, name, tag);
}
fn below(schema: Value, key: []const u8, n: usize) bool {
    const v = get(schema, key) orelse return false;
    return n < @as(usize, @intCast(v.integer));
}
fn above(schema: Value, key: []const u8, n: usize) bool {
    const v = get(schema, key) orelse return false;
    return n > @as(usize, @intCast(v.integer));
}

test "strict JSON rejects duplicates, excessive nesting and nonfinite values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"x\":1,\"x\":2}"));
    try std.testing.expectError(error.InvalidJson, parse(a, "1e9999"));
    var nested: [260]u8 = undefined;
    @memset(nested[0..130], '[');
    @memset(nested[130..], ']');
    try std.testing.expectError(error.DocumentLimit, parse(a, &nested));
}
test "native schema validates exact paths, references and Unicode patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try parse(a, "{\"$defs\":{\"name\":{\"type\":\"string\",\"minLength\":2,\"pattern\":\"^\\\\S+$\"}},\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"$ref\":\"#/$defs/name\"}},\"additionalProperties\":false}");
    var reg = Registry{ .alloc = a, .documents = &.{} };
    try reg.check(s, "input.json");
    try reg.validate(s, "input.json", try parse(a, "{\"name\":\"λ猫\"}"));
    try std.testing.expectError(error.InvalidValue, reg.validate(s, "input.json", try parse(a, "{\"name\":\"x\"}")));
    try std.testing.expectEqualStrings("/name", reg.diagnostic.path);
    try std.testing.expectError(error.UnsupportedSchema, reg.check(try parse(a, "{\"unevaluatedProperties\":false}"), "input.json"));
    try std.testing.expectError(error.UnresolvedSchema, reg.check(try parse(a, "{\"$ref\":\"https://example.com/missing\"}"), "input.json"));
}

test "native bounded transport envelope preserves strict JSON and domain input limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bytes = try alloc.alloc(u8, 1048576 + 32);
    @memset(bytes, ' ');
    @memcpy(bytes[0..2], "{}");
    try std.testing.expectError(error.DocumentLimit, parse(alloc, bytes));
    try std.testing.expect((try parseBounded(alloc, bytes, 1048576 + 16384)) == .object);
    try std.testing.expectError(error.DuplicateField, parseBounded(alloc, "{\"a\":1,\"a\":2}", 1048576 + 16384));
    try std.testing.expectError(error.DocumentLimit, parseBounded(alloc, bytes, 1048576));
}
