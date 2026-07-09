(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** A typed tool an agent can offer to the model.

    A tool pairs a name and a {!Schema} of its arguments with a handler over the
    decoded OCaml value. The schema yields both the [input_schema] advertised to
    the model and the decoder; the handler therefore sees typed values, and a
    decode failure (or an exception it raises) becomes an ["Error: …"] result
    rather than aborting the turn. *)

type t

val v : name:string -> description:string -> 'a Schema.t -> ('a -> string) -> t
(** [v ~name ~description args handler] builds a tool. *)

val name : t -> string
val description : t -> string

val input_schema : t -> Yojson.Safe.t
(** The JSON Schema for the tool's arguments (provider-independent). *)

val run : t -> Yojson.Safe.t -> string
(** [run t input] decodes [input] through the tool's schema, runs the handler,
    and returns its result (or an ["Error: …"] string on failure). *)
