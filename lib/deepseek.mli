(** Run DeepSeek-V4 locally on Apple Metal, and build agents on top of it.

    This library wraps the vendored DeepSeek-V4 Flash/Pro inference engine and
    layers a small tool-using agent over it:

    - {!V4} loads a GGUF model and generates text (one-shot), or through a
      persistent session whose KV cache survives across turns.
    - {!Agent} drives a multi-turn conversation in which the model may call
      tools, folding their results back in until it answers in plain text.
    - {!Tool} defines a typed tool from an argument codec and an OCaml handler.
    - {!Toolbox} provides ready-made tools, each scoped by an Eio capability.

    Prompt encoding and tool-call parsing live in the companion {!Dsml} library,
    which the agent uses to render conversations and decode replies. *)

module V4 = V4
(** The inference engine. Open a model with {!V4.create}, then either call
    {!V4.generate} for a single streamed reply or drive a {!V4.Session} directly
    for multi-turn use. The engine can run on its own Eio domain. *)

module Agent = Agent
(** A tool-using agent loop over {!V4}. {!Agent.create} starts a conversation
    with a set of tools; {!Agent.send} runs one user turn to completion,
    reporting reasoning, content, tool calls, and results as {!Agent.event}s. *)

module Tool = Tool
(** A typed tool: {!Tool.v} pairs a [Dsml.Codec] argument description (which
    yields both the advertised JSON Schema and the decoder) with a handler over
    plain OCaml values. *)

module Toolbox = Toolbox
(** Ready-made {!Tool.t}s — [read], [write], [dns], and [bash] — following Eio's
    capability model: each can reach only the directory, network, or process
    manager it is handed. *)
