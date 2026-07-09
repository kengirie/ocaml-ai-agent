(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type t = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  run : Yojson.Safe.t -> string;
}

let v ~name ~description args handler =
  {
    name;
    description;
    input_schema = Schema.to_json_schema args;
    run =
      (fun input ->
        match Schema.decode args input with
        | Ok a -> ( try handler a with e -> "Error: " ^ Printexc.to_string e)
        | Error e -> "Error: " ^ e);
  }

let name t = t.name
let description t = t.description
let input_schema t = t.input_schema
let run t input = t.run input
