(** A set of ready-made {!Tool.t} values, following Eio's capability model so
    that each tool can reach only what it is handed. *)

val read : dir:_ Eio.Path.t -> Tool.t
(** [read ~dir] is a [read] tool that returns the contents of a file resolved
    under [dir]. Grant a wide [dir] for broad read access or a sandboxed one to
    limit it. *)

val write : dir:_ Eio.Path.t -> Tool.t
(** [write ~dir] is a [write] tool that creates or overwrites a file resolved
    under [dir]. Pass an {!Eio.Path.open_dir} sandbox as [dir] to confine every
    write to that subtree. *)

val dns : net:_ Eio.Net.t -> Tool.t
(** [dns ~net] is a [dns] tool that resolves a hostname to its IP addresses with
    {!Eio.Net.getaddrinfo} over [net], returning one address per line. Holding
    [net] is the capability to reach the network, so grant it deliberately. *)

val bash : proc:_ Eio.Process.mgr -> Tool.t
(** [bash ~proc] is a [bash] tool that runs a shell command with [proc] and
    returns its combined output. Holding [proc] is the full capability to spawn
    processes, so grant this tool deliberately. *)
