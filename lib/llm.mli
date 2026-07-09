(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The backend abstraction an {!Agent} drives. A backend turns a conversation
    plus a tool set into one assistant turn, streaming its progress as
    {!event}s. *)

type event =
  | Reasoning of string
  | Content of string
  | Tool_call of Message.tool_call
  | Tool_result of string * string
  | Done

module type S = sig
  type t

  val converse :
    t ->
    system:string ->
    tools:Tool.t list ->
    messages:Message.t list ->
    params:Params.t ->
    on_event:(event -> unit) ->
    Message.t
end
