(* Metal backend, with the embedded .metal kernels the C backend JIT-compiles at
   engine-open. *)
let which = `Metal
let sources = Shaders.sources
