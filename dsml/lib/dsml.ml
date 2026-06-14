(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* DSML — DeepSeek-V4 prompt encoding (DeepSeek Markup Language).

   DSML is XML-flavored but not XML: tags embed the [｜DSML｜] token (U+FF5C
   bars) and [<｜DSML｜parameter>] bodies are raw text scanned for the
   [</｜DSML｜parameter>] sentinel.  JSON is handled with nox-json ({!Json}); the
   tool-call grammar is a bidirectional combinator codec ({!Codec}). *)

(* ===================================================================== *)
(* Special tokens                                                         *)
(* ===================================================================== *)

let bos_token =
  "<\xef\xbd\x9cbegin\xe2\x96\x81of\xe2\x96\x81sentence\xef\xbd\x9c>"

let eos_token =
  "<\xef\xbd\x9cend\xe2\x96\x81of\xe2\x96\x81sentence\xef\xbd\x9c>"

let thinking_start_token = "<think>"
let thinking_end_token = "</think>"
let dsml_token = "\xef\xbd\x9cDSML\xef\xbd\x9c" (* ｜DSML｜ *)
let user_token = "<\xef\xbd\x9cUser\xef\xbd\x9c>"
let assistant_token = "<\xef\xbd\x9cAssistant\xef\xbd\x9c>"
let latest_reminder_token = "<\xef\xbd\x9clatest_reminder\xef\xbd\x9c>"

let reasoning_effort_max =
  "Reasoning Effort: Absolute maximum with no shortcuts permitted.\n\
   You MUST be very thorough in your thinking and comprehensively decompose \
   the problem to resolve the root cause, rigorously stress-testing your logic \
   against all potential paths, edge cases, and adversarial scenarios.\n\
   Explicitly write out your entire deliberation process, documenting every \
   intermediate step, considered alternative, and rejected hypothesis to \
   ensure absolutely no assumption is left unchecked.\n\n"

exception Parse_error of string

(* ===================================================================== *)
(* Small helpers                                                          *)
(* ===================================================================== *)

let starts_with s ~prefix = String.starts_with ~prefix s
let ends_with s ~suffix = String.ends_with ~suffix s
let sub_from s i = String.sub s i (String.length s - i)

(* First index >= [start] at which [sub] occurs in [s], or None. *)
let find_from s start sub =
  let sl = String.length sub and n = String.length s in
  if sl = 0 then Some start
  else begin
    let matches_at i =
      let rec c j = j >= sl || (s.[i + j] = sub.[j] && c (j + 1)) in
      c 0
    in
    let last = n - sl in
    let rec loop i =
      if i > last then None else if matches_at i then Some i else loop (i + 1)
    in
    loop start
  end

let contains s sub = find_from s 0 sub <> None

(* Strip leading whitespace: space, tab, NL, CR, FF, VT. *)
let strip_left_ws s =
  let n = String.length s in
  let i = ref 0 in
  while
    !i < n
    &&
    match s.[!i] with
    | ' ' | '\t' | '\n' | '\r' | '\012' | '\011' -> true
    | _ -> false
  do
    incr i
  done;
  String.sub s !i (n - !i)

let json_member k = function
  | Json.Object (mems, _) -> Option.map snd (Json.Value.member_key k mems)
  | _ -> None

(* ===================================================================== *)
(* DSML markup scanner                                                    *)
(* ===================================================================== *)

let invoke_start = "<" ^ dsml_token ^ "invoke"
let invoke_end = "</" ^ dsml_token ^ "invoke"
let parameter_start = "<" ^ dsml_token ^ "parameter"
let parameter_slash = "/" ^ dsml_token ^ "parameter"
let tool_calls_open = "<" ^ dsml_token ^ "tool_calls"
let tool_calls_end = "</" ^ dsml_token ^ "tool_calls>"
let tool_calls_start = "\n\n" ^ tool_calls_open

(* Read from [index] until the earliest of [stops]; on a positional tie the
   first stop in the list wins.  Returns (index-after-stop, content-before-stop,
   matched-stop). *)
let read_until_stop text index stops =
  let n = String.length text in
  let min_pos = ref n and matched = ref None in
  List.iter
    (fun s ->
      match find_from text index s with
      | Some pos when pos < !min_pos ->
          min_pos := pos;
          matched := Some s
      | _ -> ())
    stops;
  match !matched with
  | Some s ->
      ( !min_pos + String.length s,
        String.sub text index (!min_pos - index),
        Some s )
  | None -> (n, String.sub text index (n - index), None)

(* Validate ' name="NAME">\n' (with optional leading whitespace). *)
let parse_tool_name content =
  let s = strip_left_ws content in
  let prefix = "name=\"" and suffix = "\">\n" in
  if
    starts_with s ~prefix && ends_with s ~suffix
    && String.length s >= String.length prefix + String.length suffix
  then
    String.sub s (String.length prefix)
      (String.length s - String.length prefix - String.length suffix)
  else
    raise (Parse_error (Printf.sprintf "Tool name format error: '%s'" content))

(* Validate ' name="K" string="true|false">VALUE<' -> (K, "true|false", VALUE). *)
let parse_param content =
  if not (ends_with content ~suffix:"<") then
    raise (Parse_error (Printf.sprintf "Parameter format error: '%s'" content));
  let body = String.sub content 0 (String.length content - 1) in
  let p1 = " name=\"" in
  if not (starts_with body ~prefix:p1) then
    raise (Parse_error (Printf.sprintf "Parameter format error: '%s'" content));
  let start = String.length p1 in
  let sep = "\" string=\"" in
  let rec find_sep from =
    match find_from body from sep with
    | None ->
        raise
          (Parse_error (Printf.sprintf "Parameter format error: '%s'" content))
    | Some pos ->
        let after = sub_from body (pos + String.length sep) in
        if starts_with after ~prefix:"true\">" then
          (String.sub body start (pos - start), "true", sub_from after 6)
        else if starts_with after ~prefix:"false\">" then
          (String.sub body start (pos - start), "false", sub_from after 7)
        else find_sep (pos + 1)
  in
  find_sep start

(* Read one invocation, positioned just after the [invoke_start] token.  Returns
   (tool name, parameters in order, index past [</｜DSML｜invoke>]). *)
let read_one_invoke text index =
  let j, name_content, st =
    read_until_stop text index [ parameter_start; invoke_end ]
  in
  let name = parse_tool_name name_content in
  let params = ref [] and i = ref j and st = ref st in
  while match !st with Some s -> s = parameter_start | None -> false do
    let k, param_content, _ = read_until_stop text !i [ parameter_slash ] in
    i := k;
    let pname, pflag, pval = parse_param param_content in
    if List.mem_assoc pname !params then
      raise
        (Parse_error (Printf.sprintf "Duplicate parameter name: '%s'" pname));
    params := (pname, (pval, pflag)) :: !params;
    let m, content2, st2 =
      read_until_stop text !i [ parameter_start; invoke_end ]
    in
    i := m;
    st := st2;
    if content2 <> ">\n" then
      raise
        (Parse_error
           (Printf.sprintf
              "Parameter format error: expected '>\\n' but got '%s'" content2))
  done;
  (name, List.rev !params, !i)

(* ===================================================================== *)
(* Types                                                                  *)
(* ===================================================================== *)

type thinking_mode = Chat | Thinking
type reasoning_effort = High | Max
type task = Action | Query | Authority | Domain | Title | Read_url

let task_token = function
  | Action -> "<\xef\xbd\x9caction\xef\xbd\x9c>"
  | Query -> "<\xef\xbd\x9cquery\xef\xbd\x9c>"
  | Authority -> "<\xef\xbd\x9cauthority\xef\xbd\x9c>"
  | Domain -> "<\xef\xbd\x9cdomain\xef\xbd\x9c>"
  | Title -> "<\xef\xbd\x9ctitle\xef\xbd\x9c>"
  | Read_url -> "<\xef\xbd\x9cread_url\xef\xbd\x9c>"

type tool_call = { id : string option; name : string; arguments : string }

type content_block =
  | Text of string
  | Tool_result of { tool_use_id : string; content : Json.t }

type role =
  | System
  | Developer
  | User
  | Tool_role
  | Latest_reminder
  | Assistant

type message = {
  role : role;
  content : string;
  reasoning_content : string;
  tools : Json.t list;
  response_format : Json.t option;
  tool_calls : tool_call list;
  wo_eos : bool;
  task : task option;
  tool_call_id : string option;
  content_blocks : content_block list option;
}

type parsed_message = {
  content : string;
  reasoning_content : string;
  tool_calls : tool_call list;
}

let base role =
  {
    role;
    content = "";
    reasoning_content = "";
    tools = [];
    response_format = None;
    tool_calls = [];
    wo_eos = false;
    task = None;
    tool_call_id = None;
    content_blocks = None;
  }

let system ?(tools = []) ?response_format content =
  { (base System) with content; tools; response_format }

let developer ?(tools = []) ?response_format content =
  if content = "" then invalid_arg "Dsml.developer: content must be non-empty";
  { (base Developer) with content; tools; response_format }

let user ?task content = { (base User) with content; task }

let assistant ?(content = "") ?(reasoning_content = "") ?(tool_calls = [])
    ?(wo_eos = false) ?task () =
  { (base Assistant) with content; reasoning_content; tool_calls; wo_eos; task }

let tool ~id content = { (base Tool_role) with content; tool_call_id = Some id }
let latest_reminder content = { (base Latest_reminder) with content }
let tool_call ?id ~name ~arguments () = { id; name; arguments }

(* ===================================================================== *)
(* Tool arguments <-> DSML parameters (dynamic / generic)                 *)
(* ===================================================================== *)

let tools_from_openai (tools : Json.t list) : Json.t list =
  List.map
    (fun t ->
      match json_member "function" t with
      | Some f -> f
      | None -> invalid_arg "Dsml: tool object missing \"function\"")
    tools

(* JSON [arguments] -> DSML <parameter> tags.  String members become raw text
   ([string="true"]); other members carry their compact JSON ([string="false"]).
   A non-object collapses to a single "arguments" string parameter. *)
let encode_arguments_to_dsml tc =
  let members =
    match Json.Value.of_string tc.arguments with
    | Ok (Json.Object (mems, _)) -> List.map (fun (nm, v) -> (fst nm, v)) mems
    | Ok _ | Error _ -> [ ("arguments", Json.Value.string tc.arguments) ]
  in
  String.concat "\n"
    (List.map
       (fun (k, v) ->
         let is_str, value =
           match v with
           | Json.String (s, _) -> (true, s)
           | other -> (false, Json.Value.to_string other)
         in
         Printf.sprintf
           "<%sparameter name=\"%s\" string=\"%s\">%s</%sparameter>" dsml_token
           k
           (if is_str then "true" else "false")
           value dsml_token)
       members)

(* Decoded <parameter>s -> OpenAI [arguments] JSON object string. *)
let decode_dsml_to_arguments name (args : (string * (string * string)) list) =
  let member_of (k, (v, is_string)) =
    let value =
      if is_string = "true" then Json.Value.string v
      else
        match Json.Value.of_string v with
        | Ok j -> j
        | Error _ ->
            raise
              (Parse_error
                 (Printf.sprintf "Invalid JSON parameter value: '%s'" v))
    in
    Json.Value.member (Json.Value.name k) value
  in
  {
    id = None;
    name;
    arguments =
      Json.Value.to_string (Json.Value.object' (List.map member_of args));
  }

(* ===================================================================== *)
(* Codec — bidirectional combinators for the tool-call grammar            *)
(* ===================================================================== *)

module Codec = struct
  (* A parameter value codec: raw text + the [string="..."] flag <-> ['a]. *)
  type 'a value = {
    v_dec : raw:string -> is_string:bool -> 'a;
    v_enc : 'a -> bool * string (* (is_string, raw text) *);
  }

  let string =
    { v_dec = (fun ~raw ~is_string:_ -> raw); v_enc = (fun s -> (true, s)) }

  let json =
    {
      v_dec =
        (fun ~raw ~is_string ->
          if is_string then Json.Value.string raw
          else
            match Json.Value.of_string raw with
            | Ok j -> j
            | Error _ ->
                raise
                  (Parse_error (Printf.sprintf "Invalid JSON value: '%s'" raw)));
      v_enc =
        (fun j ->
          match j with
          | Json.String (s, _) -> (true, s)
          | other -> (false, Json.Value.to_string other));
    }

  let bool =
    {
      v_dec =
        (fun ~raw ~is_string:_ ->
          match raw with
          | "true" -> true
          | "false" -> false
          | _ ->
              raise
                (Parse_error (Printf.sprintf "Invalid bool value: '%s'" raw)));
      v_enc = (fun b -> (false, if b then "true" else "false"));
    }

  let int =
    {
      v_dec =
        (fun ~raw ~is_string:_ ->
          match int_of_string_opt raw with
          | Some i -> i
          | None ->
              raise (Parse_error (Printf.sprintf "Invalid int value: '%s'" raw)));
      v_enc = (fun i -> (false, string_of_int i));
    }

  let float =
    {
      v_dec =
        (fun ~raw ~is_string:_ ->
          match float_of_string_opt raw with
          | Some f -> f
          | None ->
              raise
                (Parse_error (Printf.sprintf "Invalid float value: '%s'" raw)));
      v_enc = (fun f -> (false, Json.Value.to_string (Json.Value.number f)));
    }

  let map_value ~dec ~enc v =
    {
      v_dec = (fun ~raw ~is_string -> dec (v.v_dec ~raw ~is_string));
      v_enc = (fun b -> v.v_enc (enc b));
    }

  (* A codec for one invocation.  Scanning (name + parameters) is done by the
     block reader; a codec only interprets and renders an invoke, so codecs can
     be dispatched on the tool name (see {!choice}). *)
  type 'a t = {
    name : string; (* fixed tool name, or "" *)
    decode_invoke : string -> (string * (string * string)) list -> 'a;
    encode_invoke : 'a -> string;
  }

  let render_param name (is_string, raw) =
    Printf.sprintf "<%sparameter name=\"%s\" string=\"%s\">%s</%sparameter>"
      dsml_token name
      (if is_string then "true" else "false")
      raw dsml_token

  let render_invoke name body =
    Printf.sprintf "<%sinvoke name=\"%s\">\n%s\n</%sinvoke>" dsml_token name
      body dsml_token

  module Invoke = struct
    type ('o, 'dec) map = {
      iname : string;
      idec : (string * (string * string)) list -> 'dec;
      ienc : ('o -> string) list (* reversed *);
    }

    let map iname dec = { iname; idec = (fun _ -> dec); ienc = [] }

    let param ~enc name value m =
      let idec params =
        let f = m.idec params in
        let raw, is_string =
          match List.assoc_opt name params with
          | Some (raw, flag) -> (raw, flag = "true")
          | None ->
              raise
                (Parse_error (Printf.sprintf "Missing parameter: '%s'" name))
        in
        f (value.v_dec ~raw ~is_string)
      in
      let enc1 o = render_param name (value.v_enc (enc o)) in
      { iname = m.iname; idec; ienc = enc1 :: m.ienc }

    let seal m =
      {
        name = m.iname;
        decode_invoke = (fun _name params -> m.idec params);
        encode_invoke =
          (fun o ->
            render_invoke m.iname
              (String.concat "\n" (List.rev_map (fun e -> e o) m.ienc)));
      }
  end

  (* Any tool: parameters <-> JSON arguments. *)
  let dynamic =
    {
      name = "";
      decode_invoke = (fun name params -> decode_dsml_to_arguments name params);
      encode_invoke =
        (fun tc -> render_invoke tc.name (encode_arguments_to_dsml tc));
    }

  let map ~dec ~enc c =
    {
      name = c.name;
      decode_invoke = (fun n p -> dec (c.decode_invoke n p));
      encode_invoke = (fun b -> c.encode_invoke (enc b));
    }

  type 'b case = {
    cname : string;
    cdecode : string -> (string * (string * string)) list -> 'b;
    cencode : 'b -> string option;
  }

  let case ~inject ~project c =
    {
      cname = c.name;
      cdecode = (fun n p -> inject (c.decode_invoke n p));
      cencode = (fun b -> Option.map c.encode_invoke (project b));
    }

  let choice ?default cases =
    {
      name = "";
      decode_invoke =
        (fun n p ->
          match List.find_opt (fun c -> c.cname = n) cases with
          | Some c -> c.cdecode n p
          | None -> (
              match default with
              | Some d -> d.decode_invoke n p
              | None ->
                  raise
                    (Parse_error (Printf.sprintf "No codec for tool: '%s'" n))));
      encode_invoke =
        (fun b ->
          let rec go = function
            | c :: tl -> ( match c.cencode b with Some s -> s | None -> go tl)
            | [] -> (
                match default with
                | Some d -> d.encode_invoke b
                | None -> raise (Parse_error "No codec to encode tool call"))
          in
          go cases);
    }

  (* Read the invocations of a tool-call block; [index] is positioned just after
     the [tool_calls_open] token (at its '>'). *)
  let decode_block codec text index =
    let calls = ref [] and i = ref index and stop = ref false in
    while not !stop do
      let j, content, st =
        read_until_stop text !i [ invoke_start; tool_calls_end ]
      in
      i := j;
      if content <> ">\n" then
        raise
          (Parse_error
             (Printf.sprintf
                "Tool call format error: expected '>\\n' but got '%s'" content));
      match st with
      | Some s when s = tool_calls_end -> stop := true
      | None -> raise (Parse_error "Missing special token in tool calls")
      | Some _ ->
          let name, params, j = read_one_invoke text !i in
          i := j;
          calls := codec.decode_invoke name params :: !calls
    done;
    (List.rev !calls, !i)

  let encode_block codec calls =
    Printf.sprintf "<%stool_calls>\n%s\n</%stool_calls>" dsml_token
      (String.concat "\n" (List.map codec.encode_invoke calls))
      dsml_token

  let decode codec text =
    match find_from text 0 tool_calls_open with
    | None -> Error "no <｜DSML｜tool_calls> block"
    | Some p -> (
        try
          Ok (fst (decode_block codec text (p + String.length tool_calls_open)))
        with Parse_error m -> Error m)

  let encode = encode_block
end

(* ===================================================================== *)
(* Tool — OpenAI tool-schema construction                                 *)
(* ===================================================================== *)

module Tool = struct
  let v ~name ?(description = "") ?parameters () : Json.t =
    let fields =
      [ ("name", Json.Value.string name) ]
      @ (if description = "" then []
         else [ ("description", Json.Value.string description) ])
      @ match parameters with Some p -> [ ("parameters", p) ] | None -> []
    in
    let mem (k, v) = Json.Value.member (Json.Value.name k) v in
    Json.Value.object'
      [
        mem ("type", Json.Value.string "function");
        mem ("function", Json.Value.object' (List.map mem fields));
      ]
end

(* ===================================================================== *)
(* Stream — incremental completion decoding                               *)
(* ===================================================================== *)

module Stream = struct
  type event =
    | Reasoning of string
    | Content of string
    | Tool_call of tool_call
    | Done

  type phase =
    | In_reasoning
    | In_content
    | In_tool_calls
    | After_tool_calls
    | Ended

  type t = { mutable phase : phase; mutable buf : string; mutable tc : string }

  let create = function
    | Thinking -> { phase = In_reasoning; buf = ""; tc = "" }
    | Chat -> { phase = In_content; buf = ""; tc = "" }

  (* Earliest complete needle in [buf], if any. *)
  let earliest buf needles =
    List.fold_left
      (fun acc nd ->
        match find_from buf 0 nd with
        | Some p -> (
            match acc with
            | Some (bp, _, _) when bp <= p -> acc
            | _ -> Some (p, nd, String.length nd))
        | None -> acc)
      None needles

  (* Length of the longest suffix of [buf] that is a proper prefix of a needle:
     bytes we must hold back as a possible split token. *)
  let held buf needles =
    let n = String.length buf in
    List.fold_left
      (fun acc nd ->
        let maxk = min n (String.length nd - 1) in
        let rec try_k k =
          if k <= acc then acc
          else if String.sub buf (n - k) k = String.sub nd 0 k then k
          else try_k (k - 1)
        in
        try_k maxk)
      0 needles

  let feed t chunk =
    t.buf <- t.buf ^ chunk;
    let evs = ref [] in
    let emit e = evs := e :: !evs in
    let emit_text mk s = if s <> "" then emit (mk s) in
    let again = ref true in
    while !again do
      match t.phase with
      | Ended -> again := false
      | In_reasoning -> (
          match earliest t.buf [ thinking_end_token ] with
          | Some (p, _, l) ->
              emit_text (fun s -> Reasoning s) (String.sub t.buf 0 p);
              t.buf <- sub_from t.buf (p + l);
              t.phase <- In_content
          | None ->
              let h = held t.buf [ thinking_end_token ] in
              let n = String.length t.buf in
              emit_text (fun s -> Reasoning s) (String.sub t.buf 0 (n - h));
              t.buf <- String.sub t.buf (n - h) h;
              again := false)
      | In_content -> (
          match earliest t.buf [ tool_calls_start; eos_token ] with
          | Some (p, tok, l) ->
              emit_text (fun s -> Content s) (String.sub t.buf 0 p);
              t.buf <- sub_from t.buf (p + l);
              if tok = eos_token then (
                emit Done;
                t.phase <- Ended)
              else (
                t.tc <- tool_calls_open;
                t.phase <- In_tool_calls)
          | None ->
              let h = held t.buf [ tool_calls_start; eos_token ] in
              let n = String.length t.buf in
              emit_text (fun s -> Content s) (String.sub t.buf 0 (n - h));
              t.buf <- String.sub t.buf (n - h) h;
              again := false)
      | In_tool_calls -> (
          match earliest t.buf [ tool_calls_end ] with
          | Some (p, _, l) ->
              let block = t.tc ^ String.sub t.buf 0 p ^ tool_calls_end in
              t.buf <- sub_from t.buf (p + l);
              t.tc <- "";
              (match Codec.decode Codec.dynamic block with
              | Ok calls -> List.iter (fun c -> emit (Tool_call c)) calls
              | Error _ -> ());
              t.phase <- After_tool_calls
          | None ->
              let h = held t.buf [ tool_calls_end ] in
              let n = String.length t.buf in
              t.tc <- t.tc ^ String.sub t.buf 0 (n - h);
              t.buf <- String.sub t.buf (n - h) h;
              again := false)
      | After_tool_calls -> (
          match earliest t.buf [ eos_token ] with
          | Some (p, _, l) ->
              t.buf <- sub_from t.buf (p + l);
              emit Done;
              t.phase <- Ended
          | None ->
              let h = held t.buf [ eos_token ] in
              let n = String.length t.buf in
              t.buf <- String.sub t.buf (n - h) h;
              again := false)
    done;
    List.rev !evs

  let finish t =
    let evs = ref [] in
    (match t.phase with
    | In_reasoning -> if t.buf <> "" then evs := [ Reasoning t.buf ]
    | In_content -> if t.buf <> "" then evs := [ Content t.buf ]
    | _ -> ());
    let tail = if t.phase = Ended then [] else [ Done ] in
    t.buf <- "";
    t.phase <- Ended;
    !evs @ tail
end

(* ===================================================================== *)
(* Message rendering                                                      *)
(* ===================================================================== *)

let render_response_format rf =
  "## Response Format:\n\n\
   You MUST strictly adhere to the following schema to reply:\n"
  ^ Json.Value.to_string rf

let tools_template_head =
  "## Tools\n\n\
   You have access to a set of tools to help answer the user's question. You \
   can invoke tools by writing a \"<\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\" \
   block like the following:\n\n\
   <\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n\
   <\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"$TOOL_NAME\">\n\
   <\xef\xbd\x9cDSML\xef\xbd\x9cparameter name=\"$PARAMETER_NAME\" \
   string=\"true|false\">$PARAMETER_VALUE</\xef\xbd\x9cDSML\xef\xbd\x9cparameter>\n\
   ...\n\
   </\xef\xbd\x9cDSML\xef\xbd\x9cinvoke>\n\
   <\xef\xbd\x9cDSML\xef\xbd\x9cinvoke name=\"$TOOL_NAME2\">\n\
   ...\n\
   </\xef\xbd\x9cDSML\xef\xbd\x9cinvoke>\n\
   </\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls>\n\n\
   String parameters should be specified as is and set `string=\"true\"`. For \
   all other types (numbers, booleans, arrays, objects), pass the value in \
   JSON format and set `string=\"false\"`.\n\n\
   If thinking_mode is enabled (triggered by <think>), you MUST output your \
   complete reasoning inside <think>...</think> BEFORE any tool calls or final \
   response.\n\n\
   Otherwise, output directly after </think> with tool calls or final \
   response.\n\n\
   ### Available Tool Schemas\n\n"

let tools_template_tail =
  "\n\n\
   You MUST strictly follow the above defined tool name and parameter schemas \
   to invoke tool calls.\n"

let render_tools (functions : Json.t list) =
  tools_template_head
  ^ String.concat "\n" (List.map Json.Value.to_string functions)
  ^ tools_template_tail

let find_last_user_index msgs =
  let r = ref (-1) in
  Array.iteri
    (fun i m -> if m.role = User || m.role = Developer then r := i)
    msgs;
  !r

let render_tool_result_content = function
  | Json.String (s, _) -> s
  | Json.Array (items, _) ->
      String.concat "\n\n"
        (List.map
           (fun b ->
             match json_member "type" b with
             | Some (Json.String ("text", _)) -> (
                 match json_member "text" b with
                 | Some (Json.String (t, _)) -> t
                 | _ -> "")
             | Some (Json.String (ty, _)) ->
                 Printf.sprintf "[Unsupported %s]" ty
             | Some other ->
                 Printf.sprintf "[Unsupported %s]" (Json.Value.to_string other)
             | None -> "[Unsupported None]")
           items)
  | other -> Json.Value.to_string other

let render_message msgs index ~thinking_mode ~drop_thinking ~reasoning_effort =
  let n = Array.length msgs in
  let msg = msgs.(index) in
  let last_user_idx = find_last_user_index msgs in
  let b = Buffer.create 256 in
  if index = 0 && thinking_mode = Thinking && reasoning_effort = Some Max then
    Buffer.add_string b reasoning_effort_max;
  (match msg.role with
  | System -> (
      Buffer.add_string b msg.content;
      if msg.tools <> [] then (
        Buffer.add_string b "\n\n";
        Buffer.add_string b (render_tools (tools_from_openai msg.tools)));
      match msg.response_format with
      | Some rf -> Buffer.add_string b ("\n\n" ^ render_response_format rf)
      | None -> ())
  | Developer -> (
      Buffer.add_string b user_token;
      Buffer.add_string b msg.content;
      if msg.tools <> [] then (
        Buffer.add_string b "\n\n";
        Buffer.add_string b (render_tools (tools_from_openai msg.tools)));
      match msg.response_format with
      | Some rf -> Buffer.add_string b ("\n\n" ^ render_response_format rf)
      | None -> ())
  | User -> (
      Buffer.add_string b user_token;
      match msg.content_blocks with
      | Some blocks ->
          Buffer.add_string b
            (String.concat "\n\n"
               (List.map
                  (function
                    | Text t -> t
                    | Tool_result { content; _ } ->
                        "<tool_result>"
                        ^ render_tool_result_content content
                        ^ "</tool_result>")
                  blocks))
      | None -> Buffer.add_string b msg.content)
  | Latest_reminder ->
      Buffer.add_string b latest_reminder_token;
      Buffer.add_string b msg.content
  | Tool_role ->
      raise
        (Failure
           "Dsml: tool messages must be merged into user messages before \
            rendering (use encode_messages)")
  | Assistant ->
      let tc_content =
        if msg.tool_calls <> [] then
          "\n\n" ^ Codec.encode Codec.dynamic msg.tool_calls
        else ""
      in
      let prev_has_task = index - 1 >= 0 && msgs.(index - 1).task <> None in
      let thinking_part =
        if thinking_mode = Thinking && not prev_has_task then
          if (not drop_thinking) || index > last_user_idx then
            msg.reasoning_content ^ thinking_end_token
          else ""
        else ""
      in
      Buffer.add_string b thinking_part;
      Buffer.add_string b msg.content;
      Buffer.add_string b tc_content;
      if not msg.wo_eos then Buffer.add_string b eos_token);
  (* Transition tokens: skipped if the next message is a non-assistant,
     non-latest_reminder turn (it emits its own prefix). *)
  let early_return =
    index + 1 < n
    &&
    let r = msgs.(index + 1).role in
    r <> Assistant && r <> Latest_reminder
  in
  if not early_return then
    begin match msg.task with
    | Some t ->
        if t <> Action then Buffer.add_string b (task_token t)
        else begin
          Buffer.add_string b assistant_token;
          Buffer.add_string b
            (if thinking_mode <> Thinking then thinking_end_token
             else thinking_start_token);
          Buffer.add_string b (task_token t)
        end
    | None -> (
        match msg.role with
        | User | Developer ->
            Buffer.add_string b assistant_token;
            if (not drop_thinking) && thinking_mode = Thinking then
              Buffer.add_string b thinking_start_token
            else if
              drop_thinking && thinking_mode = Thinking
              && index >= last_user_idx
            then Buffer.add_string b thinking_start_token
            else Buffer.add_string b thinking_end_token
        | _ -> ())
    end;
  Buffer.contents b

(* ===================================================================== *)
(* Preprocessing                                                          *)
(* ===================================================================== *)

let merge_tool_messages (messages : message list) : message list =
  let merged = ref [] in
  List.iter
    (fun msg ->
      match msg.role with
      | Tool_role -> (
          let block =
            Tool_result
              {
                tool_use_id =
                  (match msg.tool_call_id with Some s -> s | None -> "");
                content = Json.Value.string msg.content;
              }
          in
          match !merged with
          | prev :: rest when prev.role = User && prev.content_blocks <> None ->
              let blocks =
                match prev.content_blocks with Some b -> b | None -> []
              in
              merged :=
                { prev with content_blocks = Some (blocks @ [ block ]) } :: rest
          | _ ->
              merged :=
                { (base User) with content_blocks = Some [ block ] } :: !merged)
      | User -> (
          let block = Text msg.content in
          match !merged with
          | prev :: rest
            when prev.role = User
                 && prev.content_blocks <> None
                 && prev.task = None ->
              let blocks =
                match prev.content_blocks with Some b -> b | None -> []
              in
              merged :=
                { prev with content_blocks = Some (blocks @ [ block ]) } :: rest
          | _ ->
              merged :=
                {
                  (base User) with
                  content = msg.content;
                  content_blocks = Some [ block ];
                  task = msg.task;
                  wo_eos = msg.wo_eos;
                }
                :: !merged)
      | _ -> merged := msg :: !merged)
    messages;
  List.rev !merged

let sort_tool_results_by_call_order (messages : message list) : message list =
  let last_order : (string, int) Hashtbl.t = Hashtbl.create 8 in
  let rec go acc = function
    | [] -> List.rev acc
    | msg :: tl ->
        let msg =
          match msg.role with
          | Assistant when msg.tool_calls <> [] ->
              Hashtbl.reset last_order;
              List.iteri
                (fun idx tc ->
                  match tc.id with
                  | Some id when id <> "" -> Hashtbl.replace last_order id idx
                  | _ -> ())
                msg.tool_calls;
              msg
          | User -> (
              match msg.content_blocks with
              | Some blocks ->
                  let tool_blocks =
                    List.filter
                      (function Tool_result _ -> true | _ -> false)
                      blocks
                  in
                  if
                    List.length tool_blocks > 1 && Hashtbl.length last_order > 0
                  then begin
                    let key = function
                      | Tool_result { tool_use_id; _ } -> (
                          match Hashtbl.find_opt last_order tool_use_id with
                          | Some i -> i
                          | None -> 0)
                      | _ -> 0
                    in
                    let sorted =
                      List.stable_sort
                        (fun a b -> compare (key a) (key b))
                        tool_blocks
                    in
                    let arr = Array.of_list sorted in
                    let i = ref 0 in
                    let new_blocks =
                      List.map
                        (function
                          | Tool_result _ ->
                              let blk = arr.(!i) in
                              incr i;
                              blk
                          | other -> other)
                        blocks
                    in
                    { msg with content_blocks = Some new_blocks }
                  end
                  else msg
              | None -> msg)
          | _ -> msg
        in
        go (msg :: acc) tl
  in
  go [] messages

let drop_thinking_messages (messages : message list) : message list =
  let arr = Array.of_list messages in
  let last_user_idx = find_last_user_index arr in
  let keep = function
    | User | System | Tool_role | Latest_reminder -> true
    | _ -> false
  in
  let out = ref [] in
  Array.iteri
    (fun idx msg ->
      if keep msg.role || idx >= last_user_idx then out := msg :: !out
      else
        match msg.role with
        | Assistant -> out := { msg with reasoning_content = "" } :: !out
        | _ -> ())
    arr;
  List.rev !out

(* ===================================================================== *)
(* Encode                                                                 *)
(* ===================================================================== *)

let drop_n k lst =
  let rec go k = function
    | l when k <= 0 -> l
    | _ :: tl -> go (k - 1) tl
    | [] -> []
  in
  go k lst

let encode_messages ?(context = []) ?(drop_thinking = true)
    ?(add_default_bos_token = true) ?reasoning_effort thinking_mode messages =
  let messages = merge_tool_messages messages in
  let messages =
    drop_n (List.length context)
      (sort_tool_results_by_call_order (context @ messages))
  in
  let context =
    if context <> [] then
      sort_tool_results_by_call_order (merge_tool_messages context)
    else context
  in
  let full_messages = context @ messages in
  let b = Buffer.create 1024 in
  if add_default_bos_token && context = [] then Buffer.add_string b bos_token;
  let effective_drop =
    if List.exists (fun m -> m.tools <> []) full_messages then false
    else drop_thinking
  in
  let full_arr, num_to_render, context_len =
    if thinking_mode = Thinking && effective_drop then begin
      let fm = drop_thinking_messages full_messages in
      let num = List.length fm - List.length (drop_thinking_messages context) in
      (Array.of_list fm, num, List.length fm - num)
    end
    else (Array.of_list full_messages, List.length messages, List.length context)
  in
  for idx = 0 to num_to_render - 1 do
    Buffer.add_string b
      (render_message full_arr (idx + context_len) ~thinking_mode
         ~drop_thinking:effective_drop ~reasoning_effort)
  done;
  Buffer.contents b

(* ===================================================================== *)
(* Parse                                                                  *)
(* ===================================================================== *)

let parse_message_from_completion_text thinking_mode text =
  let n = String.length text in
  let index = ref 0 and stop = ref None in
  let reasoning = ref "" and summary = ref "" and calls = ref [] in
  if thinking_mode = Thinking then begin
    let i, content, st =
      read_until_stop text !index [ thinking_end_token; tool_calls_start ]
    in
    index := i;
    reasoning := content;
    stop := st;
    if st <> Some thinking_end_token then
      raise (Parse_error "Invalid thinking format: missing </think>")
  end;
  let i, content, st =
    read_until_stop text !index [ eos_token; tool_calls_start ]
  in
  index := i;
  summary := content;
  stop := st;
  let is_tool_calling = st = Some tool_calls_start in
  if (not is_tool_calling) && st <> Some eos_token then
    raise (Parse_error "Invalid format: missing EOS token");
  if is_tool_calling then begin
    let tcs, j = Codec.decode_block Codec.dynamic text !index in
    index := j;
    calls := tcs;
    let k, tail, st3 = read_until_stop text !index [ eos_token ] in
    index := k;
    stop := st3;
    if tail <> "" then raise (Parse_error "Unexpected content after tool calls")
  end;
  if not (!index = n && (!stop = Some eos_token || !stop = None)) then
    raise (Parse_error "Unexpected content at end");
  List.iter
    (fun sp ->
      if contains !summary sp || contains !reasoning sp then
        raise (Parse_error "Unexpected special token in content"))
    [
      bos_token; eos_token; thinking_start_token; thinking_end_token; dsml_token;
    ];
  { content = !summary; reasoning_content = !reasoning; tool_calls = !calls }

(* ===================================================================== *)
(* bytesrw I/O boundary                                                   *)
(* ===================================================================== *)

let encode_messages_to_writer w ?context ?drop_thinking ?add_default_bos_token
    ?reasoning_effort thinking_mode messages =
  let s =
    encode_messages ?context ?drop_thinking ?add_default_bos_token
      ?reasoning_effort thinking_mode messages
  in
  Bytesrw.Bytes.Writer.write_string w s

let parse_message_from_reader thinking_mode r =
  parse_message_from_completion_text thinking_mode
    (Bytesrw.Bytes.Reader.to_string r)
