(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type t = {
  env : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
  api_key : string;
  model : string;
  base_url : string;
  version : string;
  stream : bool;
}

let default_model = "claude-opus-4-8"

let create ~sw ~env ?(base_url = "https://api.anthropic.com") ?api_key
    ?(model = default_model) ?(stream = true) () =
  let api_key =
    match api_key with
    | Some k when k <> "" -> k
    | _ -> (
        match Sys.getenv_opt "ANTHROPIC_API_KEY" with
        | Some k when k <> "" -> k
        | _ ->
            failwith
              "Anthropic backend: set the ANTHROPIC_API_KEY environment \
               variable")
  in
  { env; sw; api_key; model; base_url; version = "2023-06-01"; stream }

let tool_to_json (tl : Tool.t) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String (Tool.name tl));
      ("description", `String (Tool.description tl));
      ("input_schema", Tool.input_schema tl);
    ]

let assistant_blocks ~text ~tool_calls : Yojson.Safe.t list =
  let text_block =
    if text = "" then []
    else [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ]
  in
  let tool_blocks =
    List.map
      (fun (tc : Message.tool_call) ->
        `Assoc
          [
            ("type", `String "tool_use");
            ("id", `String tc.id);
            ("name", `String tc.name);
            ("input", tc.input);
          ])
      tool_calls
  in
  text_block @ tool_blocks

let messages_to_json (messages : Message.t list) : Yojson.Safe.t =
  let rec go acc = function
    | [] -> List.rev acc
    | Message.User s :: rest ->
        go (`Assoc [ ("role", `String "user"); ("content", `String s) ] :: acc) rest
    | Message.Assistant { text; tool_calls; _ } :: rest ->
        go
          (`Assoc
             [
               ("role", `String "assistant");
               ("content", `List (assistant_blocks ~text ~tool_calls));
             ]
          :: acc)
          rest
    | Message.Tool_result _ :: _ as l ->
        let rec take blocks = function
          | Message.Tool_result { id; content } :: tl ->
              take
                (`Assoc
                   [
                     ("type", `String "tool_result");
                     ("tool_use_id", `String id);
                     ("content", `String content);
                   ]
                :: blocks)
                tl
          | other -> (List.rev blocks, other)
        in
        let blocks, rest = take [] l in
        go
          (`Assoc [ ("role", `String "user"); ("content", `List blocks) ] :: acc)
          rest
  in
  `List (go [] messages)

(* Only [temperature] is sent; recent Claude models deprecate [top_p]. *)
let request_body t ~stream ~system ~tools ~messages ~(params : Params.t) :
    string =
  let base =
    [
      ("model", `String t.model);
      ("max_tokens", `Int params.max_tokens);
      ("system", `String system);
      ("messages", messages_to_json messages);
      ("temperature", `Float params.temperature);
    ]
    @ (if stream then [ ("stream", `Bool true) ] else [])
  in
  let fields =
    match tools with
    | [] -> base
    | _ -> base @ [ ("tools", `List (List.map tool_to_json tools)) ]
  in
  Yojson.Safe.to_string (`Assoc fields)

let send_request t ?(extra_headers = []) body_string =
  let uri = Uri.of_string (t.base_url ^ "/v1/messages") in
  let headers =
    [
      ("x-api-key", t.api_key);
      ("anthropic-version", t.version);
      ("content-type", "application/json");
    ]
    @ extra_headers
  in
  let body = Piaf.Body.of_string body_string in
  match Piaf.Client.Oneshot.post ~headers ~body ~sw:t.sw t.env uri with
  | Error e -> failwith ("Anthropic request failed: " ^ Piaf.Error.to_string e)
  | Ok response ->
      let status = Piaf.Response.status response in
      if Piaf.Status.is_successful status then response
      else
        let body_str =
          match Piaf.Body.to_string (Piaf.Response.body response) with
          | Ok s -> s
          | Error _ -> ""
        in
        failwith
          (Printf.sprintf "Anthropic API error (%s): %s"
             (Piaf.Status.to_string status) body_str)

let parse_response ~on_event body_str : Message.t =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body_str in
  let blocks = json |> member "content" |> to_list in
  let text = Buffer.create 256 and thinking = Buffer.create 64 in
  let calls = ref [] in
  List.iter
    (fun block ->
      match block |> member "type" |> to_string with
      | "text" ->
          let s = block |> member "text" |> to_string in
          Buffer.add_string text s;
          on_event (Llm.Content s)
      | "thinking" ->
          let s = block |> member "thinking" |> to_string in
          Buffer.add_string thinking s;
          on_event (Llm.Reasoning s)
      | "tool_use" ->
          let id = block |> member "id" |> to_string in
          let name = block |> member "name" |> to_string in
          let input = block |> member "input" in
          let tc : Message.tool_call = { id; name; input } in
          calls := tc :: !calls;
          on_event (Llm.Tool_call tc)
      | _ -> ())
    blocks;
  Message.Assistant
    {
      text = Buffer.contents text;
      thinking = Buffer.contents thinking;
      tool_calls = List.rev !calls;
    }

let converse_nonstream t ~system ~tools ~messages ~params ~on_event : Message.t =
  let body = request_body t ~stream:false ~system ~tools ~messages ~params in
  let response = send_request t body in
  let body_str =
    match Piaf.Body.to_string (Piaf.Response.body response) with
    | Ok s -> s
    | Error e ->
        failwith ("Anthropic: reading response body: " ^ Piaf.Error.to_string e)
  in
  parse_response ~on_event body_str

let converse_stream t ~system ~tools ~messages ~params ~on_event : Message.t =
  let body = request_body t ~stream:true ~system ~tools ~messages ~params in
  let response =
    send_request t ~extra_headers:[ ("accept", "text/event-stream") ] body
  in
  let text = Buffer.create 256 and thinking = Buffer.create 64 in
  let calls = ref [] in
  let tool_blocks : (int, string * string * Buffer.t) Hashtbl.t =
    Hashtbl.create 4
  in
  let handle_event json =
    let open Yojson.Safe.Util in
    match json |> member "type" |> to_string with
    | "content_block_start" -> (
        let idx = json |> member "index" |> to_int in
        let block = json |> member "content_block" in
        match block |> member "type" |> to_string with
        | "tool_use" ->
            let id = block |> member "id" |> to_string in
            let name = block |> member "name" |> to_string in
            Hashtbl.replace tool_blocks idx (id, name, Buffer.create 64)
        | _ -> ())
    | "content_block_delta" -> (
        let idx = json |> member "index" |> to_int in
        let delta = json |> member "delta" in
        match delta |> member "type" |> to_string with
        | "text_delta" ->
            let s = delta |> member "text" |> to_string in
            Buffer.add_string text s;
            on_event (Llm.Content s)
        | "thinking_delta" ->
            let s = delta |> member "thinking" |> to_string in
            Buffer.add_string thinking s;
            on_event (Llm.Reasoning s)
        | "input_json_delta" -> (
            let s = delta |> member "partial_json" |> to_string in
            match Hashtbl.find_opt tool_blocks idx with
            | Some (_, _, buf) -> Buffer.add_string buf s
            | None -> ())
        | _ -> ())
    | "content_block_stop" -> (
        let idx = json |> member "index" |> to_int in
        match Hashtbl.find_opt tool_blocks idx with
        | Some (id, name, buf) ->
            let raw = Buffer.contents buf in
            let input =
              if String.trim raw = "" then `Assoc []
              else try Yojson.Safe.from_string raw with _ -> `Assoc []
            in
            let tc : Message.tool_call = { id; name; input } in
            calls := tc :: !calls;
            on_event (Llm.Tool_call tc);
            Hashtbl.remove tool_blocks idx
        | None -> ())
    | _ -> ()
  in
  let leftover = Buffer.create 256 and data = Buffer.create 256 in
  let process_line line =
    let line =
      let n = String.length line in
      if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line
    in
    if String.length line = 0 then begin
      if Buffer.length data > 0 then begin
        let payload = Buffer.contents data in
        Buffer.clear data;
        match Yojson.Safe.from_string payload with
        | json -> handle_event json
        | exception _ -> ()
      end
    end
    else if String.length line >= 5 && String.sub line 0 5 = "data:" then begin
      let rest = String.sub line 5 (String.length line - 5) in
      let rest =
        if String.length rest > 0 && rest.[0] = ' ' then
          String.sub rest 1 (String.length rest - 1)
        else rest
      in
      Buffer.add_string data rest
    end
  in
  let feed chunk =
    Buffer.add_string leftover chunk;
    let s = Buffer.contents leftover in
    Buffer.clear leftover;
    let rec loop start =
      match String.index_from_opt s start '\n' with
      | Some nl ->
          process_line (String.sub s start (nl - start));
          loop (nl + 1)
      | None ->
          Buffer.add_string leftover
            (String.sub s start (String.length s - start))
    in
    loop 0
  in
  (match Piaf.Body.iter_string ~f:feed (Piaf.Response.body response) with
  | Ok () -> ()
  | Error e -> failwith ("Anthropic stream error: " ^ Piaf.Error.to_string e));
  if Buffer.length leftover > 0 then begin
    let rest = Buffer.contents leftover in
    Buffer.clear leftover;
    process_line rest
  end;
  process_line "";
  Message.Assistant
    {
      text = Buffer.contents text;
      thinking = Buffer.contents thinking;
      tool_calls = List.rev !calls;
    }

let converse t ~system ~tools ~messages ~params ~on_event : Message.t =
  if t.stream then converse_stream t ~system ~tools ~messages ~params ~on_event
  else converse_nonstream t ~system ~tools ~messages ~params ~on_event
