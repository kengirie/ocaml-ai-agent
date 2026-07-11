(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** A tool-using agent loop over a pluggable {!Llm.S} backend.

    The agent owns the conversation and tool set; each user turn asks the backend
    for one assistant message, runs any tools it calls (confined by their Eio
    capabilities), folds the results back in, and repeats until the model replies
    with text alone — or the turn budget runs out. *)

type event = Llm.event =
  | Reasoning of string
  | Content of string
  | Tool_call of Message.tool_call
  | Tool_result of string * string
  | Retry of { attempt : int; max : int; delay : float; reason : string }
  | Turn_limit of int
  | Done

type t

val create :
  ?system:string ->
  ?params:Params.t ->
  ?tools:Tool.t list ->
  ?max_turns:int ->
  ?max_tool_output:int ->
  (module Llm.S with type t = 'e) ->
  'e ->
  t
(** [create (module L) engine] is an agent over backend [L].

    [max_turns] (default [50]) caps the backend calls per {!send}; on reaching
    it the agent emits {!Llm.Turn_limit} and stops with history intact, so the
    next send resumes cleanly. [max_tool_output] (default [30_000]) is the
    byte budget per tool result; larger results keep their head and tail around
    an omission marker (see {!truncate_middle}). *)

val send : t -> on_event:(event -> unit) -> string -> unit

val truncate_middle : max:int -> string -> string
(** [truncate_middle ~max s] is [s] if it fits in [max] bytes; otherwise its
    first and last [max/2] bytes around an [[... output truncated ...]] marker,
    cut on UTF-8 character boundaries. *)
