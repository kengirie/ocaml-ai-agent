(* A typed tool: a Dsml invoke codec (schema + decoder) plus a handler over the
   decoded OCaml value. The codec hides the JSON layer from the handler. *)

module Json = Dsml.Json

type t = {
  name : string;
  description : string;
  schema : Json.t;
  invoke : Dsml.tool_call -> string;
}

let v ~description codec handler =
  {
    name = Dsml.Codec.name codec;
    description;
    schema = Dsml.Codec.schema codec;
    invoke =
      (fun call ->
        match Dsml.Codec.decode_arguments codec call.arguments with
        | Ok args -> (
            try handler args with e -> "Error: " ^ Printexc.to_string e)
        | Error msg -> "Error: " ^ msg);
  }

let name t = t.name
let description t = t.description
let schema t = t.schema
let invoke t call = t.invoke call
