(* A minimal tool-using agent loop over the DeepSeek-V4 engine.

   The shape mirrors the reference C agent (ds4_agent.c). Two libraries do the
   heavy lifting: Dsml renders the conversation and parses the model's replies,
   and V4.Session keeps the KV cache across turns, so re-syncing the grown
   conversation each round prefills only the new tokens. *)

type event =
  | Reasoning of string
  | Content of string
  | Tool_call of Dsml.tool_call
  | Tool_result of string * string
  | Done

type t = {
  engine : V4.engine;
  session : V4.Session.t;
  thinking : Dsml.thinking_mode;
  temperature : float;
  top_p : float;
  min_p : float;
  max_tokens : int;
  tools : Tool.t list;
  eos : int;
  mutable messages : Dsml.message list; (* oldest first; head is system *)
}

let create ?(system = "You are a helpful assistant.") ?(thinking = Dsml.Chat)
    ?(ctx_size = 4096) ?(temperature = 1.0) ?(top_p = 1.0) ?(min_p = 0.05)
    ?(seed = 0x2545F4914F6CDD1DL) ?(max_tokens = 2048) ?(tools = []) engine =
  let session = V4.Session.create engine ~ctx_size ~seed in
  (* Advertise every tool inside the system turn, using the JSON Schema derived
     from each tool's argument codec. *)
  let tool_objs =
    List.map
      (fun t ->
        Dsml.Tool.v ~name:(Tool.name t) ~description:(Tool.description t)
          ~parameters:(Tool.schema t) ())
      tools
  in
  {
    engine;
    session;
    thinking;
    temperature;
    top_p;
    min_p;
    max_tokens;
    tools;
    eos = V4.token_eos engine;
    messages = [ Dsml.system ~tools:tool_objs system ];
  }

(* Give every call a stable id so the assistant turn and its tool results pair
   up when the conversation is re-rendered. *)
let with_ids calls =
  List.mapi
    (fun i (tc : Dsml.tool_call) ->
      match tc.id with
      | Some _ -> tc
      | None -> { tc with id = Some (Printf.sprintf "call_%d" i) })
    calls

(* One model turn: render the conversation, prefill, then sample/eval tokens,
   decoding each into events. Returns the collected tool calls (with ids). *)
let run_turn t ~on_event =
  let prompt = Dsml.encode_messages t.thinking t.messages in
  let tokens = V4.Session.tokenize t.engine prompt in
  V4.Session.sync t.session tokens;
  (* Never let decoding run into the context bound (mirrors V4.generate). *)
  let room = V4.Session.ctx t.session - V4.Session.pos t.session in
  let budget = if room <= 1 then 0 else min t.max_tokens (room - 1) in
  let dec = Dsml.Stream.create t.thinking in
  let content = Buffer.create 256 and reasoning = Buffer.create 256 in
  let calls = ref [] in
  let handle = function
    | Dsml.Stream.Content c ->
        Buffer.add_string content c;
        on_event (Content c)
    | Dsml.Stream.Reasoning r ->
        Buffer.add_string reasoning r;
        on_event (Reasoning r)
    | Dsml.Stream.Tool_call tc ->
        calls := tc :: !calls;
        on_event (Tool_call tc)
    | Dsml.Stream.Done -> ()
  in
  let rec loop n =
    if n >= budget then List.iter handle (Dsml.Stream.finish dec)
    else
      let tok =
        V4.Session.sample t.session ~temperature:t.temperature ~top_p:t.top_p
          ~min_p:t.min_p
      in
      if tok = t.eos then List.iter handle (Dsml.Stream.finish dec)
      else begin
        V4.Session.eval t.session tok;
        List.iter handle (Dsml.Stream.feed dec (V4.token_text t.engine tok));
        loop (n + 1)
      end
  in
  loop 0;
  let calls = with_ids (List.rev !calls) in
  (* Record what the model produced so the next render continues from it. *)
  t.messages <-
    t.messages
    @ [
        Dsml.assistant ~content:(Buffer.contents content)
          ~reasoning_content:(Buffer.contents reasoning)
          ~tool_calls:calls ();
      ];
  calls

let send t ~on_event prompt =
  t.messages <- t.messages @ [ Dsml.user prompt ];
  let rec turn () =
    match run_turn t ~on_event with
    | [] -> on_event Done
    | calls ->
        List.iter
          (fun (tc : Dsml.tool_call) ->
            let result =
              match
                List.find_opt (fun tl -> Tool.name tl = tc.name) t.tools
              with
              | Some tl -> Tool.invoke tl tc
              | None -> "Error: unknown tool " ^ tc.name
            in
            on_event (Tool_result (tc.name, result));
            let id = match tc.id with Some s -> s | None -> "" in
            t.messages <- t.messages @ [ Dsml.tool ~id result ])
          calls;
        turn ()
  in
  turn ()
