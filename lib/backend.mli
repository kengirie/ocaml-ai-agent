(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The compiled-in inference backend.

    This is a {e virtual} module: each backend implementation library
    ([deepseek.metal], [deepseek.cpu], …) supplies its own [backend.ml], and the
    final executable selects exactly one by depending on that implementation (or
    via the virtual library's [default_implementation]). The selected backend's
    engine archive and link flags come from the same implementation library, so
    {!which} and the linked native code always agree. *)

val which : [ `Metal | `Cuda | `Cpu ]
(** Which backend this implementation is. {!V4} maps it to the [ds4_backend]
    enum the C engine expects; it must match the engine archive this
    implementation links. *)

val sources : (string * string) list
(** Embedded GPU kernels as [(name, source)] pairs, materialised to disk at
    {!V4.create} time. The Metal backend embeds its [.metal] kernels (the C
    backend JIT-compiles them at engine-open); backends that compile kernels at
    build time (CPU, CUDA) return [[]], making materialisation a no-op. *)
