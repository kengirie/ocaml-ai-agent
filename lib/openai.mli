(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** An OpenAI-compatible Chat Completions API as an {!Llm.S} backend.

    One backend serves every provider that speaks the OpenAI wire format —
    OpenAI, DeepSeek, Kimi (Moonshot), and others — differing only in
    [base_url], the API-key environment variable, and the model. [converse]
    shapes the conversation and tools into a [POST {base_url}/chat/completions]
    request and folds the response (or SSE stream) back into {!Llm} events:
    [content]->{!Llm.Content}, [reasoning_content]->{!Llm.Reasoning},
    [tool_calls]->{!Llm.Tool_call}. Streaming (SSE) by default, with a
    non-streaming fallback. *)

include Llm.S

val create :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  base_url:string ->
  ?api_key:string ->
  ?api_key_env:string ->
  model:string ->
  ?stream:bool ->
  ?retry:Retry.config ->
  unit ->
  t
(** [create ~sw ~env ~base_url ~model ()] is an OpenAI-compatible cloud backend
    posting to [base_url ^ "/chat/completions"] (so pass a [base_url] like
    ["https://api.openai.com/v1"]). [api_key] defaults to the environment
    variable named by [api_key_env] (default ["OPENAI_API_KEY"]), raising
    [Failure] if unset; [stream] to [true]. The key is sent only in the
    [Authorization: Bearer] header and is never logged.

    Transient failures — connection errors, 408/429/5xx — are retried with
    exponential backoff per [retry] (default {!Retry.default}), emitting
    {!Llm.Retry} before each wait. Other HTTP errors raise [Failure] at once. *)
