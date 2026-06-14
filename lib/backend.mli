(** The compiled-in inference backend.

    This is a {e virtual} module: each backend implementation library
    ([deepseek.metal], [deepseek.cpu], …) supplies its own [backend.ml], and the
    final executable selects exactly one by depending on that implementation (or
    via the virtual library's [default_implementation]). The selected backend's
    engine archive and link flags come from the same implementation library, so
    {!id} and the linked native code always agree. *)

val id : int
(** The [ds4_backend] enum value passed to [ds4_engine_open]: Metal = 0, CUDA =
    1, CPU = 2. Must match the engine archive this implementation links. *)

val sources : (string * string) list
(** Embedded GPU kernels as [(name, source)] pairs, materialised to disk at
    {!V4.create} time. The Metal backend embeds its [.metal] kernels (the C
    backend JIT-compiles them at engine-open); backends that compile kernels at
    build time (CPU, CUDA) return [[]], making materialisation a no-op. *)
