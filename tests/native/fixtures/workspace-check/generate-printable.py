"""Author-only regeneration: Python 3.12 / Unicode 15.0.0, never an fh build hook."""
import unicodedata
assert unicodedata.unidata_version == '15.0.0'
ranges = []
for cp in range(0x110000):
    if not chr(cp).isprintable():
        if ranges and ranges[-1][1] + 1 == cp:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp])
print('// Python Unicode 15.0.0 nonprintable ranges; retained to preserve clean() semantics.')
print('pub fn printable(cp: u21) bool {\n    for (nonprintable) |r| { if (cp < r[0]) return true; if (cp <= r[1]) return false; }\n    return true;\n}')
print('pub fn whitespace(cp: u21) bool { return switch (cp) { ' + ', '.join(hex(c) for c in range(0x110000) if chr(c).isspace()) + ' => true, else => false }; }')
print('const nonprintable = [_][2]u21{')
for lo, hi in ranges:
    print('    .{0x%x, 0x%x},' % (lo, hi))
print('};')
