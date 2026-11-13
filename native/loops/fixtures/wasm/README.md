# Portable Wasm fixtures

Tests load checked-in `.wasm` bytes with `@embedFile`. They do not invoke a compiler, Docker, Node, Python or a Wasm CLI.

| Fixture | Coverage |
| --- | --- |
| `transform.c` | Ordinary WASI libc command. Input `{"n":4}` returns `{"n":5}`. |
| `transform.wat` | Independent bounded fd-stream checks. |
| Other WAT sources | Rejected imports, features and types. Guest errors. Startup. Growth. Cancellation. |
| `finite.wat` | Runs beside a cancelled sibling to check isolation. |

## Rebuild C

Use Zig 0.16.0 from the repository root:

```sh
zig cc -target wasm32-wasi -O2 -Wl,--strip-all native/loops/fixtures/wasm/transform.c -o native/loops/fixtures/wasm/transform-c.wasm
```

## Rebuild WAT

Use the pinned C API already fetched by `zig build`. On macOS arm64:

```sh
zig cc native/loops/fixtures/wasm/build.c \
  -Izig-pkg/N-V-__8AAMbdPQTKr09Kbm-5hPVE6e2CPpY9vslxOAPN1aIv/include \
  zig-pkg/N-V-__8AAMbdPQTKr09Kbm-5hPVE6e2CPpY9vslxOAPN1aIv/lib/libwasmtime.a \
  -o /tmp/fh-wat-build
for fixture in native/loops/fixtures/wasm/*.wat; do
  /tmp/fh-wat-build "$fixture" "${fixture%.wat}.wasm" || exit
done
chmod 644 native/loops/fixtures/wasm/*.wasm
zig build test-wasm
```

Other targets need the matching dependency hash. The Linux helper links `-lpthread -ldl -lm -lunwind`.

`build.c` is an editable developer fixture compiler. fh accepts only binary modules and never uses the helper during check or run. See the [runtime contract](../../../../docs/contracts/wasm32-wasi-json-1.md).
