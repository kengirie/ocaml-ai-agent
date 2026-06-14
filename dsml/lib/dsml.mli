(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** dsml — encode DeepSeek-V4 prompts and parse model replies.

    {1 Synopsis}

    {[
    open Dsml

    let prompt =
      encode_messages Thinking
        [ system "You are helpful."; user "What is 2+2?" ]

    let reply = parse_message_from_completion_text Thinking completion
    ]}

    {1 Description}

    A conversation is a list of {!message}s — system, user, assistant, and tool
    results. {!encode_messages} renders them into the prompt string a
    DeepSeek-V4 model expects; {!parse_message_from_completion_text} turns one
    reply back into its text, reasoning, and tool calls. Use {!Chat} for a
    direct answer or {!Thinking} to have the model reason first.

    Tool calls travel as DSML, the model's tool-call markup:

    {v
    <｜DSML｜tool_calls>
    <｜DSML｜invoke name="edit">
    <｜DSML｜parameter name="path" string="true">/tmp/x.c</｜DSML｜parameter>
    <｜DSML｜parameter name="line" string="false">42</｜DSML｜parameter>
    </｜DSML｜invoke>
    </｜DSML｜tool_calls>
    v}

    [string="true"] is a raw-text value; [string="false"] is JSON. It looks like
    XML but is not — parameter bodies are raw text. Tool results are supplied as
    {!tool} messages and fold into the preceding turn. Tool schemas and
    tool-call arguments are {!Json.t} values (jsont's representation); the
    tool-call grammar itself is the bidirectional combinator codec {!Codec}. *)

(** {1 Tokens} *)

(** The model's reserved marker strings. *)

val bos_token : string
val eos_token : string
val thinking_start_token : string
val thinking_end_token : string
val dsml_token : string
val user_token : string
val assistant_token : string
val latest_reminder_token : string

(** {1 JSON}

    Generic JSON values on jsont's representation ([Json.t = Jsont.json], so
    jsont's own combinators apply directly). Tool schemas and tool-call
    arguments are {!Json.t} values. *)
module Json : sig
  type t = Jsont.json
  (** A generic JSON value. *)

  module Value : sig
    val to_string : t -> string
    (** [to_string j] is the compact (minified) JSON text of [j]. *)

    val of_string : string -> (t, string) result
    (** [of_string s] parses [s], or returns an error message. *)

    val of_string_exn : string -> t
    (** [of_string_exn s] parses [s]; raises [Invalid_argument] on a parse
        error. *)
  end
end

(** {1 Types} *)

(** Reply directly, or reason in [<think>] first. *)
type thinking_mode = Chat | Thinking

(** [Max] asks for maximum reasoning; [High] is accepted but inert. *)
type reasoning_effort = High | Max

(** Quick-instruction tasks for DeepSeek's internal pipeline. *)
type task = Action | Query | Authority | Domain | Title | Read_url

type tool_call = { id : string option; name : string; arguments : string }
(** A tool call. [arguments] is a JSON object string. *)

type parsed_message = {
  content : string;
  reasoning_content : string;
  tool_calls : tool_call list;
}
(** A parsed assistant turn. *)

type message
(** A conversation message. *)

exception Parse_error of string
(** Malformed model output. *)

(** {1 Messages} *)

val system : ?tools:Json.t list -> ?response_format:Json.t -> string -> message
(** [system content] is a system turn; [tools] advertises callable tools. *)

val developer :
  ?tools:Json.t list -> ?response_format:Json.t -> string -> message
(** [developer content] is a developer turn; content must be non-empty. *)

val user : ?task:task -> string -> message
(** [user content] is a user turn. *)

val assistant :
  ?content:string ->
  ?reasoning_content:string ->
  ?tool_calls:tool_call list ->
  ?wo_eos:bool ->
  ?task:task ->
  unit ->
  message
(** [assistant ()] is an assistant turn; [wo_eos] leaves it open for continued
    generation. *)

val tool : id:string -> string -> message
(** [tool ~id result] is a tool result for call [id]. *)

val latest_reminder : string -> message
(** [latest_reminder content] is a latest-reminder turn (date, locale). *)

val tool_call :
  ?id:string -> name:string -> arguments:string -> unit -> tool_call
(** [tool_call ~name ~arguments ()] builds a tool call. *)

(** {1 Encode} *)

val encode_messages :
  ?context:message list ->
  ?drop_thinking:bool ->
  ?add_default_bos_token:bool ->
  ?reasoning_effort:reasoning_effort ->
  thinking_mode ->
  message list ->
  string
(** [encode_messages mode messages] renders the conversation to the prompt
    string. [context] prepends an already-encoded prefix and suppresses the
    leading token; [drop_thinking] (default true) drops reasoning from turns
    before the last user message; [reasoning_effort] [Max] maximises reasoning.
*)

(** {1 Parse} *)

val parse_message_from_completion_text :
  thinking_mode -> string -> parsed_message
(** [parse_message_from_completion_text mode text] parses one raw reply,
    trailing EOS included; raises {!Parse_error} on malformed output. *)

(** {1 Codec}

    A bidirectional combinator codec for the DSML tool-call grammar, in the
    style of [Json.Codec]: one description both decodes a tool-call block to
    OCaml values and encodes them back.

    {[
    type edit = { path : string; line : int }

    let edit_codec =
      let open Dsml.Codec in
      Invoke.map "edit" (fun path line -> { path; line })
      |> Invoke.param ~enc:(fun e -> e.path) "path" string
      |> Invoke.param ~enc:(fun e -> e.line) "line" int
      |> Invoke.seal

    let block =
      Dsml.Codec.encode edit_codec [ { path = "/tmp/x.c"; line = 42 } ]

    let calls = Dsml.Codec.decode edit_codec block
    ]} *)
module Codec : sig
  type 'a value
  (** A codec for one parameter value. *)

  val string : string value
  (** [string] is a raw-text parameter ([string="true"]). *)

  val bool : bool value
  (** [bool] is a JSON boolean parameter. *)

  val int : int value
  (** [int] is a JSON integer parameter. *)

  val float : float value
  (** [float] is a JSON number parameter. *)

  val json : Json.t value
  (** [json] is any JSON parameter (or a JSON string). *)

  val map_value : dec:('a -> 'b) -> enc:('b -> 'a) -> 'a value -> 'b value
  (** [map_value ~dec ~enc v] adapts the value codec [v] to another type. *)

  type 'a t
  (** A codec for one tool invocation, producing a value of type ['a]. *)

  (** Build an invoke codec member-by-member, like [Json.Codec.Object]. *)
  module Invoke : sig
    type ('o, 'dec) map
    (** A partially-built invoke codec for ['o], constructed by ['dec]. *)

    val map : string -> 'dec -> ('o, 'dec) map
    (** [map name dec] starts an invoke for tool [name] assembled by [dec]. *)

    val param :
      enc:('o -> 'a) ->
      ?description:string ->
      string ->
      'a value ->
      ('o, 'a -> 'b) map ->
      ('o, 'b) map
    (** [param ~enc ?description name v m] adds required parameter [name] of
        type [v] to the invoke under construction [m]. [enc] projects the value
        from ['o] when encoding, and [description] documents the parameter in
        the derived {!schema}. *)

    val seal : ('o, 'o) map -> 'o t
    (** [seal m] finalises the invoke codec. *)
  end

  val dynamic : tool_call t
  (** [dynamic] decodes/encodes any tool, mapping parameters to JSON arguments.
  *)

  val map : dec:('a -> 'b) -> enc:('b -> 'a) -> 'a t -> 'b t
  (** [map ~dec ~enc c] adapts an invoke codec to another type. *)

  val name : 'a t -> string
  (** [name c] is the tool name [c] decodes and encodes ([""] for {!dynamic} and
      {!choice}). *)

  val schema : 'a t -> Json.t
  (** [schema c] is the JSON Schema for [c]'s parameters object, with one
      property per {!Invoke.param} and a [required] list. Pass it to {!Tool.v}
      to advertise the tool to the model. *)

  val decode_arguments : 'a t -> string -> ('a, string) result
  (** [decode_arguments c arguments] decodes one tool call's JSON-object
      [arguments] string (as carried by {!tool_call}) through [c], returning the
      typed value or an error message. *)

  type 'b case
  (** A case in a {!choice}: one tool name handled by a typed codec. *)

  val case : inject:('a -> 'b) -> project:('b -> 'a option) -> 'a t -> 'b case
  (** [case ~inject ~project c] makes invoke codec [c] a case of a sum type
      ['b]: [inject] lifts a decoded value in, [project] selects it for
      encoding. *)

  val choice : ?default:'b t -> 'b case list -> 'b t
  (** [choice ?default cases] dispatches an invocation on its tool name to the
      matching case; [default] handles unmatched names (e.g. {!dynamic}). *)

  val decode : 'a t -> string -> ('a list, string) result
  (** [decode c s] decodes the tool-call block found in [s] with [c]. *)

  val encode : 'a t -> 'a list -> string
  (** [encode c calls] renders [calls] as a [<｜DSML｜tool_calls>] block. *)
end

(** {1 Tools} *)

(** Build the OpenAI tool objects passed to {!system} and {!developer}. *)
module Tool : sig
  val v :
    name:string -> ?description:string -> ?parameters:Json.t -> unit -> Json.t
  (** [v ~name ?description ?parameters ()] is the tool object
      [{"type":"function","function":{"name";"description";"parameters"}}].
      [parameters] is a JSON Schema. *)
end

(** {1 Streaming decode}

    Decode a completion as it is generated, token by token, emitting reasoning
    and content text as it arrives and tool calls once each block completes.
    This is the primitive an interactive agent feeds with model output. *)
module Stream : sig
  (** A piece of decoded output. *)
  type event =
    | Reasoning of string  (** a chunk of [<think>] reasoning *)
    | Content of string  (** a chunk of reply text *)
    | Tool_call of tool_call  (** a completed tool call *)
    | Done  (** end of turn (EOS reached) *)

  type t
  (** An incremental decoder. *)

  val create : thinking_mode -> t
  (** [create mode] is a fresh decoder. *)

  val feed : t -> string -> event list
  (** [feed d chunk] decodes the next [chunk] of generated text, in order.
      Partial markers spanning chunk boundaries are held back until complete. *)

  val finish : t -> event list
  (** [finish d] flushes buffered text at end of stream and emits {!Done}. *)
end

(** {1 Byte streams} *)

val encode_messages_to_writer :
  Bytesrw.Bytes.Writer.t ->
  ?context:message list ->
  ?drop_thinking:bool ->
  ?add_default_bos_token:bool ->
  ?reasoning_effort:reasoning_effort ->
  thinking_mode ->
  message list ->
  unit
(** [encode_messages_to_writer w mode messages] renders the conversation to byte
    stream [w]. *)

val parse_message_from_reader :
  thinking_mode -> Bytesrw.Bytes.Reader.t -> parsed_message
(** [parse_message_from_reader mode r] parses one reply from byte stream [r]. *)
