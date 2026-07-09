(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Ready-made {!Tool.t} values following Eio's capability model: each closes
    over exactly one capability (a directory, the network, or the process
    manager), so its reach is precisely what the caller grants. *)

val read : dir:_ Eio.Path.t -> Tool.t
(** [read ~dir] reads a UTF-8 file resolved under [dir] (and nothing outside it). *)

val write : dir:_ Eio.Path.t -> Tool.t
(** [write ~dir] creates or overwrites a UTF-8 file resolved under [dir]. *)

val dns : net:_ Eio.Net.t -> Tool.t
(** [dns ~net] resolves a hostname to IP addresses over [net]. *)

val bash : proc:_ Eio.Process.mgr -> Tool.t
(** [bash ~proc] runs a shell command with [proc] and returns its output. *)
