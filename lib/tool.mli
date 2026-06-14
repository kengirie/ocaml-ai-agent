(** A typed tool an agent can call.

    A tool pairs a name and a typed argument description with a handler over
    OCaml values. The argument description is a {!Dsml.Codec} invoke codec,
    which serves three roles at once: it derives the JSON Schema advertised to
    the model, decodes the arguments the model sends into a typed value, and
    (being bidirectional) can render that value back. The handler therefore
    receives plain OCaml types, and the JSON layer stays inside the codec.

    {[
    let touch =
      let open Dsml.Codec in
      Invoke.map "touch" (fun path -> path)
      |> Invoke.param ~enc:Fun.id "path" string ~description:"file to create"
      |> Invoke.seal
    in
    Tool.v ~description:"Create an empty file." touch (fun path ->
        Out_channel.with_open_text path ignore;
        "created " ^ path)
    ]} *)

type t
(** A tool: a name and parameter schema advertised to the model, with a handler
    run when the model calls it. *)

val v : description:string -> 'a Dsml.Codec.t -> ('a -> string) -> t
(** [v ~description args handler] builds a tool whose name and parameter schema
    come from the invoke codec [args]. When the model calls it, the arguments
    are decoded through [args] and passed to [handler], whose returned string is
    the tool result shown to the model. A decoding failure or an exception
    raised by [handler] becomes an ["Error: …"] result rather than aborting the
    turn. *)

val name : t -> string
(** [name t] is the name the model uses to call [t]. *)

val description : t -> string
(** [description t] is the one-line description shown to the model. *)

val schema : t -> Json.t
(** [schema t] is the JSON Schema for [t]'s arguments, derived from its codec.
*)

val invoke : t -> Dsml.tool_call -> string
(** [invoke t call] decodes [call]'s arguments, runs [t]'s handler, and returns
    the result (or an ["Error: …"] string on failure). *)
