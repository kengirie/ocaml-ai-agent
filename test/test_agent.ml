(*---------------------------------------------------------------------------
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

module Agent = Ocaml_ai_agent.Agent
module Message = Ocaml_ai_agent.Message
module Retry = Ocaml_ai_agent.Retry
module Tool = Ocaml_ai_agent.Tool
module Schema = Ocaml_ai_agent.Schema

let must name cond =
  Printf.printf "%s - %s\n" (if cond then "ok  " else "FAIL") name;
  if not cond then exit 1

(* A scripted backend: [respond n] is the assistant message for the n-th call. *)
module Fake = struct
  type t = { mutable calls : int; respond : int -> Message.t }

  let converse t ~system:_ ~tools:_ ~messages:_ ~params:_ ~on_event:_ =
    t.calls <- t.calls + 1;
    t.respond t.calls
end

let call_echo = { Message.id = "1"; name = "echo"; input = `Assoc [ ("s", `String "hi") ] }

let echo_tool ~result =
  let args =
    let open Schema in
    let+ s = string "s" in
    s
  in
  Tool.v ~name:"echo" ~description:"test tool" args (fun _ -> result)

let assistant_calling_tool =
  Message.Assistant { text = ""; thinking = ""; tool_calls = [ call_echo ] }

let assistant_text s = Message.Assistant { text = s; thinking = ""; tool_calls = [] }

let () =
  (* truncate_middle *)
  must "short string is unchanged" (Agent.truncate_middle ~max:10 "hello" = "hello");
  let big = String.make 500 'a' ^ String.make 500 'z' in
  let cut = Agent.truncate_middle ~max:100 big in
  must "long string is cut" (String.length cut < 200);
  must "head is kept" (String.sub cut 0 10 = String.make 10 'a');
  must "tail is kept" (String.sub cut (String.length cut - 10) 10 = String.make 10 'z');
  let contains s marker =
    let rec find i =
      i + String.length marker <= String.length s
      && (String.sub s i (String.length marker) = marker || find (i + 1))
    in
    find 0
  in
  must "marker mentions omitted bytes" (contains cut "output truncated");
  (* UTF-8: cuts never split a multibyte character *)
  let jp = ref "" in
  for _ = 1 to 400 do jp := !jp ^ "\xe3\x81\x82" done;
  let cut_jp = Agent.truncate_middle ~max:101 !jp in
  let valid_utf8 s =
    let rec go i =
      if i >= String.length s then true
      else
        let c = Char.code s.[i] in
        let n =
          if c < 0x80 then 1
          else if c land 0xE0 = 0xC0 then 2
          else if c land 0xF0 = 0xE0 then 3
          else if c land 0xF8 = 0xF0 then 4
          else -1
        in
        n > 0
        && i + n <= String.length s
        && (let ok = ref true in
            for j = i + 1 to i + n - 1 do
              if Char.code s.[j] land 0xC0 <> 0x80 then ok := false
            done;
            !ok)
        && go (i + n)
    in
    go 0
  in
  must "utf-8 boundaries are respected" (valid_utf8 cut_jp);

  (* max_turns: a model that always calls a tool is stopped after the cap *)
  let fake = { Fake.calls = 0; respond = (fun _ -> assistant_calling_tool) } in
  let agent =
    Agent.create ~tools:[ echo_tool ~result:"ok" ] ~max_turns:3 (module Fake) fake
  in
  let events = ref [] in
  Agent.send agent ~on_event:(fun e -> events := e :: !events) "go";
  must "backend called exactly max_turns times" (fake.Fake.calls = 3);
  must "turn limit is announced"
    (List.exists (function Agent.Turn_limit 3 -> true | _ -> false) !events);
  must "send still finishes with Done"
    (match !events with Agent.Done :: _ -> true | _ -> false);

  (* a finishing model does not hit the limit *)
  let fake2 =
    {
      Fake.calls = 0;
      respond = (fun n -> if n = 1 then assistant_calling_tool else assistant_text "done");
    }
  in
  let agent2 =
    Agent.create ~tools:[ echo_tool ~result:"ok" ] ~max_turns:3 (module Fake) fake2
  in
  let events2 = ref [] in
  Agent.send agent2 ~on_event:(fun e -> events2 := e :: !events2) "go";
  must "no turn limit when the model finishes"
    (not (List.exists (function Agent.Turn_limit _ -> true | _ -> false) !events2));
  must "tool result is reported"
    (List.exists (function Agent.Tool_result ("echo", "ok") -> true | _ -> false)
       !events2);

  (* oversized tool output is truncated before it reaches history and events *)
  let huge = String.make 1000 'x' ^ "END" in
  let fake3 =
    {
      Fake.calls = 0;
      respond = (fun n -> if n = 1 then assistant_calling_tool else assistant_text "done");
    }
  in
  let agent3 =
    Agent.create ~tools:[ echo_tool ~result:huge ] ~max_tool_output:100
      (module Fake) fake3
  in
  let seen = ref "" in
  Agent.send agent3
    ~on_event:(function Agent.Tool_result (_, r) -> seen := r | _ -> ())
    "go";
  must "tool result is truncated" (String.length !seen < 300);
  must "truncated result keeps the tail"
    (String.sub !seen (String.length !seen - 3) 3 = "END");

  (* Retry: backoff schedule *)
  let cfg = { Retry.default with max_attempts = 5; min_wait = 1.0; max_wait = 4.0 } in
  must "first delay is min_wait" (Retry.delay_after cfg ~attempt:1 = 1.0);
  must "delays double" (Retry.delay_after cfg ~attempt:2 = 2.0);
  must "delays are capped" (Retry.delay_after cfg ~attempt:4 = 4.0);
  must "retryable statuses"
    (Retry.retryable_status 429 && Retry.retryable_status 500
    && Retry.retryable_status 529
    && (not (Retry.retryable_status 400))
    && not (Retry.retryable_status 401));

  (* Retry: run retries transient failures then succeeds *)
  let slept = ref [] and retried = ref [] in
  let tries = ref 0 in
  let v =
    Retry.run
      ~sleep:(fun d -> slept := d :: !slept)
      ~config:cfg
      ~on_retry:(fun ~attempt ~max:_ ~delay:_ ~reason:_ -> retried := attempt :: !retried)
      (fun () ->
        incr tries;
        if !tries < 3 then Error (`Retryable "429") else Ok 42)
  in
  must "run returns the eventual success" (v = 42);
  must "run slept between attempts" (List.rev !slept = [ 1.0; 2.0 ]);
  must "run reported each retry" (List.rev !retried = [ 1; 2 ]);

  (* Retry: fatal errors fail at once, exhaustion fails with context *)
  let fatal =
    match
      Retry.run
        ~sleep:(fun _ -> ())
        ~config:cfg
        ~on_retry:(fun ~attempt:_ ~max:_ ~delay:_ ~reason:_ -> ())
        (fun () -> Error (`Fatal "401"))
    with
    | exception Failure m -> m = "401"
    | _ -> false
  in
  must "fatal errors are not retried" fatal;
  let exhausted =
    match
      Retry.run
        ~sleep:(fun _ -> ())
        ~config:{ cfg with max_attempts = 3 }
        ~on_retry:(fun ~attempt:_ ~max:_ ~delay:_ ~reason:_ -> ())
        (fun () -> Error (`Retryable "503"))
    with
    | exception Failure m -> contains m "giving up after 3 attempts"
    | _ -> false
  in
  must "exhausted retries raise with context" exhausted;

  print_endline "agent tests passed"
