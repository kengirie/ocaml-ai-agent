(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** Sampling parameters for one turn. *)

type t = { temperature : float; max_tokens : int }

val default : t
(** [temperature = 1.0], [max_tokens = 1024]. *)
