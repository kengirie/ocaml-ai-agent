(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The Anthropic Claude Messages API as an {!Llm.S} backend.

    Streaming (SSE) by default — events arrive token-by-token — with a
    non-streaming fallback. [converse] shapes the conversation and tool set into
    a [POST /v1/messages] request and walks the response content blocks back into
    {!Llm} events: [text]->{!Llm.Content}, [thinking]->{!Llm.Reasoning},
    [tool_use]->{!Llm.Tool_call}. The {!Agent} loop runs any tools and feeds the
    results back as {!Message.Tool_result}s on the next call. *)

include Llm.S

val default_model : string
(** The model used when none is given: ["claude-opus-4-8"]. *)

val create :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?base_url:string ->
  ?api_key:string ->
  ?model:string ->
  ?stream:bool ->
  unit ->
  t
(** [create ~sw ~env ()] is a cloud backend. [api_key] defaults to the
    [ANTHROPIC_API_KEY] environment variable, raising [Failure] if unset;
    [model] defaults to {!default_model}; [base_url] to ["https://api.anthropic.com"];
    [stream] to [true]. The key is sent only in the [x-api-key] header and is
    never logged. *)
