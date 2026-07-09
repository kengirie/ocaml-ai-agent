(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

let must name cond =
  Printf.printf "%s - %s\n" (if cond then "ok  " else "FAIL") name;
  if not cond then exit 1

let () =
  let args =
    let open Ocaml_ai_agent.Schema in
    let+ path = string "path" ~description:"the path"
    and+ count = int "count" in
    (path, count)
  in
  let schema = Ocaml_ai_agent.Schema.to_json_schema args in
  let open Yojson.Safe.Util in
  must "property path is a string"
    (schema |> member "properties" |> member "path" |> member "type" |> to_string
    = "string");
  must "property count is an integer"
    (schema |> member "properties" |> member "count" |> member "type"
    |> to_string = "integer");
  must "required lists both fields"
    (let r = schema |> member "required" |> to_list |> List.map to_string in
     List.mem "path" r && List.mem "count" r);
  (match
     Ocaml_ai_agent.Schema.decode args
       (`Assoc [ ("path", `String "/tmp/x"); ("count", `Int 3) ])
   with
  | Ok (p, c) -> must "decode roundtrips" (p = "/tmp/x" && c = 3)
  | Error e -> must ("decode roundtrips: " ^ e) false);
  (match
     Ocaml_ai_agent.Schema.decode args (`Assoc [ ("path", `String "/tmp/x") ])
   with
  | Error _ -> must "missing field is an error" true
  | Ok _ -> must "missing field is an error" false);
  print_endline "schema tests passed"
