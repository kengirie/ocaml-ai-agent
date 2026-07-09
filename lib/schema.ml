(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Each leaf carries (1) its JSON Schema property entry and (2) a decoder that
   reads its own key out of the whole arguments object. [and+] concatenates the
   property lists and runs both decoders against the same object, so the schema
   and the decoder can never drift apart. JSON-only and decode-only — no
   bidirectional rendering — which is all an API tool call needs. *)

type 'a t = {
  props : (string * Yojson.Safe.t) list;
  required : string list;
  decode : Yojson.Safe.t -> ('a, string) result;
}

let prim ty ?description name conv =
  let schema =
    ("type", `String ty)
    :: (match description with Some d -> [ ("description", `String d) ] | None -> [])
  in
  {
    props = [ (name, `Assoc schema) ];
    required = [ name ];
    decode =
      (function
      | `Assoc kvs -> (
          match List.assoc_opt name kvs with
          | Some v -> conv v
          | None -> Error (Printf.sprintf "missing argument %S" name))
      | _ -> Error "expected a JSON object");
  }

let string ?description name =
  prim "string" ?description name (function
    | `String s -> Ok s
    | _ -> Error (Printf.sprintf "%S: expected a string" name))

let int ?description name =
  prim "integer" ?description name (function
    | `Int i -> Ok i
    | _ -> Error (Printf.sprintf "%S: expected an integer" name))

let bool ?description name =
  prim "boolean" ?description name (function
    | `Bool b -> Ok b
    | _ -> Error (Printf.sprintf "%S: expected a boolean" name))

let ( let+ ) t f =
  { t with decode = (fun o -> Result.map f (t.decode o)) }

let ( and+ ) a b =
  {
    props = a.props @ b.props;
    required = a.required @ b.required;
    decode =
      (fun o ->
        match (a.decode o, b.decode o) with
        | Ok x, Ok y -> Ok (x, y)
        | Error e, _ | _, Error e -> Error e);
  }

let to_json_schema t =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc t.props);
      ("required", `List (List.map (fun s -> `String s) t.required));
    ]

let decode t json = t.decode json
