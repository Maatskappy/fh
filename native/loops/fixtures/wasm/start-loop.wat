(module (memory (export "memory") 1) (func $init (loop $forever br $forever)) (start $init) (func (export "_start")))
