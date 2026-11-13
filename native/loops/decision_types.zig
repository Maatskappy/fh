//! Portable question definitions, independent of provider configuration.
const std = @import("std");
const Value = std.json.Value;
fn nonblank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len != 0;
}
fn structured(v: Value) bool {
    return v == .string or v == .object or v == .array;
}
pub fn validateQuestions(questions: Value) !void {
    if (questions != .object or questions.object.count() == 0 or questions.object.count() > 64) return error.InvalidDecisionQuestions;
    var it = questions.object.iterator();
    while (it.next()) |entry| {
        if (!nonblank(entry.key_ptr.*)) return error.InvalidDecisionQuestions;
        const q = entry.value_ptr.*;
        if (q != .object) return error.InvalidDecisionQuestions;
        for (q.object.keys()) |key| if (!std.mem.eql(u8, key, "type") and !std.mem.eql(u8, key, "instructions") and !std.mem.eql(u8, key, "criteria")) return error.InvalidDecisionQuestions;
        const kind = q.object.get("type") orelse return error.InvalidDecisionQuestions;
        if (kind != .string) return error.InvalidDecisionQuestions;
        const instructions = q.object.get("instructions") orelse return error.InvalidDecisionQuestions;
        if (!structured(instructions)) return error.InvalidDecisionQuestions;
        const criteria = q.object.get("criteria");
        if (std.mem.eql(u8, kind.string, "noul")) {
            if (criteria) |c| {
                if (c != .object) return error.InvalidDecisionQuestions;
                var rubric = c.object.iterator();
                while (rubric.next()) |item| {
                    if ((!std.mem.eql(u8, item.key_ptr.*, "true") and !std.mem.eql(u8, item.key_ptr.*, "false")) or !structured(item.value_ptr.*)) return error.InvalidDecisionQuestions;
                }
            }
        } else if (std.mem.eql(u8, kind.string, "choice")) {
            const c = criteria orelse return error.InvalidDecisionQuestions;
            if (c != .object or c.object.count() == 0 or c.object.count() > 255) return error.InvalidDecisionQuestions;
            var rubric = c.object.iterator();
            while (rubric.next()) |item| if (!nonblank(item.key_ptr.*) or (item.value_ptr.* != .null and !structured(item.value_ptr.*))) return error.InvalidDecisionQuestions;
        } else if (std.mem.eql(u8, kind.string, "score")) {
            const c = criteria orelse return error.InvalidDecisionQuestions;
            if (c != .array or c.array.items.len < 2 or c.array.items.len > 10) return error.InvalidDecisionQuestions;
            for (c.array.items) |v| if (!structured(v)) return error.InvalidDecisionQuestions;
        } else return error.InvalidDecisionQuestions;
    }
}
