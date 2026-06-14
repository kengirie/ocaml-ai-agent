(** A tool-using agent loop over the DeepSeek-V4 engine.

    An agent holds a conversation (a list of {!Dsml.message}s) together with a
    set of {!Tool.t}s the model may call. Each user turn is driven to
    completion: the conversation is rendered to a prompt, streamed through the
    engine token by token, and decoded into a reply. When the reply contains
    tool calls the agent runs the matching tools, folds their results back into
    the conversation as new messages, and generates again; the turn ends once
    the model replies with text alone.

    {[
    let agent =
      Eio.Path.with_open_dir Eio.Path.(fs / "workspace") @@ fun ws ->
      Agent.create engine
        ~tools:
          [ Toolbox.read ~dir:ws; Toolbox.write ~dir:ws; Toolbox.bash ~proc ]
    in
    Agent.send agent "read README.md and summarise it" ~on_event:(function
      | Agent.Content c -> print_string c
      | _ -> ())
    ]} *)

(** {1 Events} *)

(** A unit of agent progress, delivered to {!send}'s [on_event] callback as it
    happens during a turn. *)
type event =
  | Reasoning of string  (** a chunk of the model's [<think>] reasoning text *)
  | Content of string  (** a chunk of the model's reply text *)
  | Tool_call of Dsml.tool_call  (** the model asked to call a tool *)
  | Tool_result of string * string
      (** a [(tool_name, result)] pair folded back into the conversation *)
  | Done  (** the turn finished with a plain-text reply *)

(** {1 Agent} *)

type t
(** An agent: an engine, its inference session, the running conversation, and
    the set of tools the model may call. *)

val create :
  ?system:string ->
  ?thinking:Dsml.thinking_mode ->
  ?ctx_size:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?min_p:float ->
  ?seed:int64 ->
  ?max_tokens:int ->
  ?tools:Tool.t list ->
  V4.engine ->
  t
(** [create engine] starts a fresh conversation on [engine]. [system] is the
    system prompt and defaults to a generic assistant instruction; [tools]
    (default empty) are advertised to the model within it. [thinking] selects a
    direct reply ([Dsml.Chat], the default) or a reasoned one ([Dsml.Thinking]).
    [ctx_size], [temperature], [top_p], [min_p], [seed], and [max_tokens] set
    the context window, sampling, RNG seed, and per-turn token budget, matching
    {!V4.generate}'s defaults. *)

val send : t -> on_event:(event -> unit) -> string -> unit
(** [send t ~on_event prompt] adds [prompt] as a user turn and runs the agent
    loop until the model answers with text alone, calling [on_event] for each
    {!event} as it occurs. [t] keeps the conversation, so a later [send]
    continues the same dialogue. *)
