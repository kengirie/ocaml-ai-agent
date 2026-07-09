(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** A tool-using agent loop over a pluggable {!Llm.S} backend.

    The agent owns the conversation and tool set; each user turn asks the backend
    for one assistant message, runs any tools it calls (confined by their Eio
    capabilities), folds the results back in, and repeats until the model replies
    with text alone. *)

type event = Llm.event =
  | Reasoning of string
  | Content of string
  | Tool_call of Message.tool_call
  | Tool_result of string * string
  | Done

type t

val create :
  ?system:string ->
  ?params:Params.t ->
  ?tools:Tool.t list ->
  (module Llm.S with type t = 'e) ->
  'e ->
  t

val send : t -> on_event:(event -> unit) -> string -> unit
