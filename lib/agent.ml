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
  | Done

type backend = Backend : (module Llm.S with type t = 'e) * 'e -> backend

type t = {
  backend : backend;
  system : string;
  params : Params.t;
  tools : Tool.t list;
  mutable messages : Message.t list;
}

let create ?(system = "You are a helpful assistant.") ?(params = Params.default)
    ?(tools = []) (type e) (module L : Llm.S with type t = e) (engine : e) =
  { backend = Backend ((module L), engine); system; params; tools; messages = [] }

let send t ~on_event prompt =
  let (Backend ((module L), engine)) = t.backend in
  t.messages <- t.messages @ [ Message.User prompt ];
  let rec turn () =
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
              match List.find_opt (fun tl -> Tool.name tl = tc.name) t.tools with
              | Some tl -> Tool.run tl tc.input
              | None -> "Error: unknown tool " ^ tc.name
            in
            on_event (Tool_result (tc.name, result));
            t.messages <-
              t.messages @ [ Message.Tool_result { id = tc.id; content = result } ])
          calls;
        turn ()
    | Message.Assistant { tool_calls = []; _ }
    | Message.User _ | Message.Tool_result _ ->
        on_event Done
  in
  turn ()
