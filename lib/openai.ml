(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* One backend for every OpenAI-compatible Chat Completions API — OpenAI,
   DeepSeek, Kimi (Moonshot) and friends all speak the same wire format, so the
   only things that vary are the base URL, the API-key env var, and the model
   name. Those are all parameters of {!create}. *)

type t = {
  env : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
  api_key : string;
  model : string;
  base_url : string;
  stream : bool;
  retry : Retry.config;
}

let create ~sw ~env ~base_url ?api_key ?(api_key_env = "OPENAI_API_KEY") ~model
    ?(stream = true) ?(retry = Retry.default) () =
  let api_key =
    match api_key with
    | Some k when k <> "" -> k
    | _ -> (
        match Sys.getenv_opt api_key_env with
        | Some k when k <> "" -> k
        | _ ->
            failwith
              (Printf.sprintf
                 "OpenAI-compatible backend: set the %s environment variable"
                 api_key_env))
  in
  { env; sw; api_key; model; base_url; stream; retry }

let tool_to_json (tl : Tool.t) : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "function");
      ( "function",
        `Assoc
          [
            ("name", `String (Tool.name tl));
            ("description", `String (Tool.description tl));
            ("parameters", Tool.input_schema tl);
          ] );
    ]

(* One OpenAI message per {!Message.t}: an assistant turn with tool calls
   renders its calls as [tool_calls] (arguments as a JSON string), and each
   tool result is its own [{"role":"tool"}] message keyed by [tool_call_id]. *)
let message_to_json : Message.t -> Yojson.Safe.t = function
  | Message.User s ->
      `Assoc [ ("role", `String "user"); ("content", `String s) ]
  | Message.Assistant { text; tool_calls; _ } ->
      let content = if text = "" then `Null else `String text in
      let base = [ ("role", `String "assistant"); ("content", content) ] in
      let fields =
        match tool_calls with
        | [] -> base
        | _ ->
            let calls =
              List.map
                (fun (tc : Message.tool_call) ->
                  `Assoc
                    [
                      ("id", `String tc.id);
                      ("type", `String "function");
                      ( "function",
                        `Assoc
                          [
                            ("name", `String tc.name);
                            ("arguments", `String (Yojson.Safe.to_string tc.input));
                          ] );
                    ])
                tool_calls
            in
            base @ [ ("tool_calls", `List calls) ]
      in
      `Assoc fields
  | Message.Tool_result { id; content } ->
      `Assoc
        [
          ("role", `String "tool");
          ("tool_call_id", `String id);
          ("content", `String content);
        ]

let messages_to_json ~system (messages : Message.t list) : Yojson.Safe.t =
  let sys =
    if system = "" then []
    else [ `Assoc [ ("role", `String "system"); ("content", `String system) ] ]
  in
  `List (sys @ List.map message_to_json messages)

let request_body t ~stream ~system ~tools ~messages ~(params : Params.t) : string
    =
  let base =
    [
      ("model", `String t.model);
      ("messages", messages_to_json ~system messages);
      ("max_tokens", `Int params.max_tokens);
      ("temperature", `Float params.temperature);
    ]
    @ if stream then [ ("stream", `Bool true) ] else []
  in
  let fields =
    match tools with
    | [] -> base
    | _ -> base @ [ ("tools", `List (List.map tool_to_json tools)) ]
  in
  Yojson.Safe.to_string (`Assoc fields)

(* Retries cover the request and status line only: once we start consuming a
   response body (or SSE stream) events have already been emitted, so a failure
   there is not replayed. *)
let send_request t ~on_event ?(extra_headers = []) body_string =
  let uri = Uri.of_string (t.base_url ^ "/chat/completions") in
  let headers =
    [
      ("authorization", "Bearer " ^ t.api_key);
      ("content-type", "application/json");
    ]
    @ extra_headers
  in
  let attempt () =
    let body = Piaf.Body.of_string body_string in
    match Piaf.Client.Oneshot.post ~headers ~body ~sw:t.sw t.env uri with
    | Error e ->
        Error
          (`Retryable
             ("OpenAI-compatible request failed: " ^ Piaf.Error.to_string e))
    | Ok response ->
        let status = Piaf.Response.status response in
        if Piaf.Status.is_successful status then Ok response
        else
          let body_str =
            match Piaf.Body.to_string (Piaf.Response.body response) with
            | Ok s -> s
            | Error _ -> ""
          in
          let msg =
            Printf.sprintf "OpenAI-compatible API error (%s): %s"
              (Piaf.Status.to_string status) body_str
          in
          if Retry.retryable_status (Piaf.Status.to_code status) then
            Error (`Retryable msg)
          else Error (`Fatal msg)
  in
  Retry.run
    ~sleep:(Eio.Time.sleep (Eio.Stdenv.clock t.env))
    ~config:t.retry
    ~on_retry:(fun ~attempt ~max ~delay ~reason ->
      on_event (Llm.Retry { attempt; max; delay; reason }))
    attempt

let str_of = function `String s -> s | _ -> ""

let parse_arguments raw =
  if String.trim raw = "" then `Assoc []
  else try Yojson.Safe.from_string raw with _ -> `Assoc []

let parse_response ~on_event body_str : Message.t =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body_str in
  let message =
    match json |> member "choices" with
    | `List (choice :: _) -> choice |> member "message"
    | _ -> `Null
  in
  let text = str_of (message |> member "content") in
  if text <> "" then on_event (Llm.Content text);
  let thinking = str_of (message |> member "reasoning_content") in
  if thinking <> "" then on_event (Llm.Reasoning thinking);
  let calls =
    match message |> member "tool_calls" with
    | `List tcs ->
        List.map
          (fun tc ->
            let id = str_of (tc |> member "id") in
            let fn = tc |> member "function" in
            let name = str_of (fn |> member "name") in
            let input = parse_arguments (str_of (fn |> member "arguments")) in
            let tc : Message.tool_call = { id; name; input } in
            on_event (Llm.Tool_call tc);
            tc)
          tcs
    | _ -> []
  in
  Message.Assistant { text; thinking; tool_calls = calls }

let converse_nonstream t ~system ~tools ~messages ~params ~on_event : Message.t =
  let body = request_body t ~stream:false ~system ~tools ~messages ~params in
  let response = send_request t ~on_event body in
  let body_str =
    match Piaf.Body.to_string (Piaf.Response.body response) with
    | Ok s -> s
    | Error e ->
        failwith
          ("OpenAI-compatible: reading response body: " ^ Piaf.Error.to_string e)
  in
  parse_response ~on_event body_str

let converse_stream t ~system ~tools ~messages ~params ~on_event : Message.t =
  let body = request_body t ~stream:true ~system ~tools ~messages ~params in
  let response =
    send_request t ~on_event
      ~extra_headers:[ ("accept", "text/event-stream") ]
      body
  in
  let text = Buffer.create 256 and thinking = Buffer.create 64 in
  (* index -> (id, name, arguments) accumulated across delta chunks. *)
  let accs : (int, string ref * string ref * Buffer.t) Hashtbl.t =
    Hashtbl.create 4
  in
  let acc_get idx =
    match Hashtbl.find_opt accs idx with
    | Some a -> a
    | None ->
        let a = (ref "", ref "", Buffer.create 64) in
        Hashtbl.replace accs idx a;
        a
  in
  let handle_event json =
    let open Yojson.Safe.Util in
    match json |> member "choices" with
    | `List (choice :: _) ->
        let delta = choice |> member "delta" in
        (match delta |> member "content" with
        | `String s when s <> "" ->
            Buffer.add_string text s;
            on_event (Llm.Content s)
        | _ -> ());
        (match delta |> member "reasoning_content" with
        | `String s when s <> "" ->
            Buffer.add_string thinking s;
            on_event (Llm.Reasoning s)
        | _ -> ());
        (match delta |> member "tool_calls" with
        | `List tcs ->
            List.iter
              (fun tc ->
                let idx =
                  match tc |> member "index" with `Int i -> i | _ -> 0
                in
                let id, name, buf = acc_get idx in
                (match tc |> member "id" with
                | `String s when s <> "" -> id := s
                | _ -> ());
                let fn = tc |> member "function" in
                (match fn |> member "name" with
                | `String s when s <> "" -> name := s
                | _ -> ());
                match fn |> member "arguments" with
                | `String s -> Buffer.add_string buf s
                | _ -> ())
              tcs
        | _ -> ())
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
        if String.trim payload <> "[DONE]" then
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
  | Error e ->
      failwith ("OpenAI-compatible stream error: " ^ Piaf.Error.to_string e));
  if Buffer.length leftover > 0 then begin
    let rest = Buffer.contents leftover in
    Buffer.clear leftover;
    process_line rest
  end;
  process_line "";
  (* Flush accumulated tool calls in index order. *)
  let calls =
    Hashtbl.fold (fun idx entry acc -> (idx, entry) :: acc) accs []
    |> List.sort (fun (a, _) (b, _) -> compare a b)
    |> List.map (fun (_, (id, name, buf)) ->
           let tc : Message.tool_call =
             { id = !id; name = !name; input = parse_arguments (Buffer.contents buf) }
           in
           on_event (Llm.Tool_call tc);
           tc)
  in
  Message.Assistant
    {
      text = Buffer.contents text;
      thinking = Buffer.contents thinking;
      tool_calls = calls;
    }

let converse t ~system ~tools ~messages ~params ~on_event : Message.t =
  if t.stream then converse_stream t ~system ~tools ~messages ~params ~on_event
  else converse_nonstream t ~system ~tools ~messages ~params ~on_event
