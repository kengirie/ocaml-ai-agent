(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

type event = Llm.event =
  | Reasoning of string
  | Content of string
  | Tool_call of Message.tool_call
  | Tool_result of string * string
  | Retry of { attempt : int; max : int; delay : float; reason : string }
  | Turn_limit of int
  | Done

type backend = Backend : (module Llm.S with type t = 'e) * 'e -> backend

type t = {
  backend : backend;
  system : string;
  params : Params.t;
  tools : Tool.t list;
  max_turns : int;
  max_tool_output : int;
  mutable messages : Message.t list;
}

let create ?(system = "You are a helpful assistant.") ?(params = Params.default)
    ?(tools = []) ?(max_turns = 50) ?(max_tool_output = 30_000) (type e)
    (module L : Llm.S with type t = e) (engine : e) =
  {
    backend = Backend ((module L), engine);
    system;
    params;
    tools;
    max_turns;
    max_tool_output;
    messages = [];
  }

(* The nearest UTF-8 character boundary at or before [i]: continuation bytes
   are 0b10xxxxxx. *)
let rec boundary_back s i =
  if i <= 0 then 0
  else if Char.code s.[i] land 0xC0 = 0x80 then boundary_back s (i - 1)
  else i

let rec boundary_fwd s i =
  if i >= String.length s then String.length s
  else if Char.code s.[i] land 0xC0 = 0x80 then boundary_fwd s (i + 1)
  else i

(* Keep the head and tail of an oversized string — command output tends to put
   the error at the end — with an omission marker in between. *)
let truncate_middle ~max s =
  let len = String.length s in
  if len <= max then s
  else
    let keep = Stdlib.max 1 (max / 2) in
    let head_end = boundary_back s keep in
    let tail_start = boundary_fwd s (len - keep) in
    Printf.sprintf "%s\n[... output truncated: %d of %d bytes omitted ...]\n%s"
      (String.sub s 0 head_end)
      (tail_start - head_end) len
      (String.sub s tail_start (len - tail_start))

let send t ~on_event prompt =
  let (Backend ((module L), engine)) = t.backend in
  t.messages <- t.messages @ [ Message.User prompt ];
  (* One [turn] is one backend call. Tool results are folded into history
     before the limit check, so a capped conversation stays consistent and the
     next send resumes where this one stopped. *)
  let rec turn n =
    if n > t.max_turns then begin
      on_event (Turn_limit t.max_turns);
      on_event Done
    end
    else
      let assistant =
        L.converse engine ~system:t.system ~tools:t.tools ~messages:t.messages
          ~params:t.params ~on_event
      in
      t.messages <- t.messages @ [ assistant ];
      match assistant with
      | Message.Assistant { tool_calls = _ :: _ as calls; _ } ->
          List.iter
            (fun (tc : Message.tool_call) ->
              let result =
                match
                  List.find_opt (fun tl -> Tool.name tl = tc.name) t.tools
                with
                | Some tl -> Tool.run tl tc.input
                | None -> "Error: unknown tool " ^ tc.name
              in
              let result = truncate_middle ~max:t.max_tool_output result in
              on_event (Tool_result (tc.name, result));
              t.messages <-
                t.messages
                @ [ Message.Tool_result { id = tc.id; content = result } ])
            calls;
          turn (n + 1)
      | Message.Assistant { tool_calls = []; _ }
      | Message.User _ | Message.Tool_result _ ->
          on_event Done
  in
  turn 1
