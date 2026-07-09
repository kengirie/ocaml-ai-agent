(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** A provider-independent conversation message. It keeps the tool-call [id] that
    pairs an assistant's tool call with the result returned for it, which the
    Anthropic round-trip requires. *)

type tool_call = {
  id : string;  (** provider tool-call id *)
  name : string;  (** tool name *)
  input : Yojson.Safe.t;  (** decoded-as-JSON arguments object *)
}

type t =
  | User of string
  | Assistant of {
      text : string;
      thinking : string;
      tool_calls : tool_call list;
    }
  | Tool_result of { id : string; content : string }
