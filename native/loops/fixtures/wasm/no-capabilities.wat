(module
 (import "wasi_snapshot_preview1" "environ_sizes_get" (func $env (param i32 i32) (result i32)))
 (import "wasi_snapshot_preview1" "args_sizes_get" (func $args (param i32 i32) (result i32)))
 (import "wasi_snapshot_preview1" "fd_read" (func $read (param i32 i32 i32 i32) (result i32)))
 (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
 (memory (export "memory") 1)
 (data (i32.const 64) "{\22n\22:5}")
 (func (export "_start")
  i32.const 0 i32.const 4 call $env if unreachable end
  i32.const 0 i32.load if unreachable end
  i32.const 4 i32.load if unreachable end
  i32.const 0 i32.const 4 call $args if unreachable end
  i32.const 0 i32.load i32.const 1 i32.ne if unreachable end
  i32.const 3 i32.const 0 i32.const 0 i32.const 8 call $read i32.eqz if unreachable end
  i32.const 0 i32.const 64 i32.store i32.const 4 i32.const 7 i32.store
  i32.const 1 i32.const 0 i32.const 1 i32.const 8 call $write drop))
