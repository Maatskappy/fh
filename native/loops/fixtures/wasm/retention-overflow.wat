;; Six stdout bytes are valid JSON, but canonicalizing 1e30 exceeds six bytes.
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 64) "[1e30]")
  (func (export "_start")
    i32.const 0 i32.const 64 i32.store
    i32.const 4 i32.const 6 i32.store
    i32.const 1 i32.const 0 i32.const 1 i32.const 8 call $write drop))
