(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** A typed combinator for an LLM tool's arguments.

    One value of type ['a t] simultaneously describes a JSON object — the
    [input_schema] advertised to the model — and a decoder that turns the JSON
    the model sends into a typed OCaml ['a]. Build one with the applicative
    [let+] / [and+] operators, one field per property. *)

type 'a t

val string : ?description:string -> string -> string t
(** [string name] is a required string property [name]. *)

val int : ?description:string -> string -> int t
(** [int name] is a required integer property [name]. *)

val bool : ?description:string -> string -> bool t
(** [bool name] is a required boolean property [name]. *)

val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
(** map: adapt a schema's decoded value. *)

val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
(** combine two schemas (their properties and decoders). *)

val to_json_schema : _ t -> Yojson.Safe.t
(** [to_json_schema t] is the JSON Schema object
    [{"type":"object","properties":…,"required":…}] advertised to the model. *)

val decode : 'a t -> Yojson.Safe.t -> ('a, string) result
(** [decode t json] decodes the model-supplied arguments object [json] through
    [t], or returns an error message. *)
