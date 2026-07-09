(*---------------------------------------------------------------------------
   Copyright (c) 2026 Anil Madhavapeddy. All rights reserved.
   Copyright (c) 2026 kengirie. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

module Agent = Ocaml_ai_agent.Agent
module Anthropic = Ocaml_ai_agent.Anthropic
module Toolbox = Ocaml_ai_agent.Toolbox
module Params = Ocaml_ai_agent.Params

let truncate n s =
  if String.length s <= n then s else String.sub s 0 n ^ "\xe2\x80\xa6"

let on_event : Agent.event -> unit = function
  | Agent.Content c ->
      print_string c;
      flush stdout
  | Agent.Reasoning r ->
      Printf.eprintf "\027[2m%s\027[0m" r;
      flush stderr
  | Agent.Tool_call tc ->
      Printf.printf "\n\027[36m\xe2\x9a\x99 %s %s\027[0m\n%!" tc.name
        (truncate 120 (Yojson.Safe.to_string tc.input))
  | Agent.Tool_result (name, result) ->
      Printf.printf "\027[2m\xe2\x86\x92 %s: %s\027[0m\n%!" name (truncate 200 result)
  | Agent.Done -> print_newline ()

let guard f =
  try f () with
  | Failure m ->
      Printf.eprintf "ocaml-ai-agent: %s\n" m;
      exit 1
  | e ->
      Printf.eprintf "ocaml-ai-agent: %s\n" (Printexc.to_string e);
      exit 1

let chat model system no_stream temperature max_tokens prompt =
  guard @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let stdout = Eio.Stdenv.stdout env in
  let be = Anthropic.create ~sw ~env ~model ~stream:(not no_stream) () in
  let params = { Params.temperature; max_tokens } in
  let agent = Agent.create ~system ~params (module Anthropic) be in
  Agent.send agent prompt ~on_event:(function
    | Agent.Content c -> Eio.Flow.copy_string c stdout
    | _ -> ());
  Eio.Flow.copy_string "\n" stdout

let agent model system no_stream temperature max_tokens dir prompt_opt =
  guard @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  let proc = Eio.Stdenv.process_mgr env in
  let net = Eio.Stdenv.net env in
  let be = Anthropic.create ~sw ~env ~model ~stream:(not no_stream) () in
  let params = { Params.temperature; max_tokens } in
  Eio.Path.with_open_dir Eio.Path.(fs / dir) @@ fun ws ->
  let tools =
    [
      Toolbox.read ~dir:ws;
      Toolbox.write ~dir:ws;
      Toolbox.dns ~net;
      Toolbox.bash ~proc;
    ]
  in
  let agent = Agent.create ~system ~params ~tools (module Anthropic) be in
  Printf.printf
    "model: %s  (Anthropic cloud)\nworkspace: %s\ntools: read, write, dns, \
     bash.  Ctrl-D to exit.\n\n%!"
    model dir;
  match prompt_opt with
  | Some p -> Agent.send agent ~on_event p
  | None ->
      let stdin =
        Eio.Buf_read.of_flow (Eio.Stdenv.stdin env) ~max_size:1_000_000
      in
      let rec repl () =
        print_string "\027[1m> \027[0m";
        flush stdout;
        match Eio.Buf_read.line stdin with
        | exception End_of_file -> print_newline ()
        | "" -> repl ()
        | line ->
            Agent.send agent ~on_event line;
            repl ()
      in
      repl ()

open Cmdliner

let model_arg =
  Arg.(
    value & opt string Anthropic.default_model
    & info [ "m"; "model" ] ~docv:"MODEL" ~doc:"The Claude model name.")

let no_stream_arg =
  Arg.(
    value & flag
    & info [ "no-stream" ]
        ~doc:"Disable SSE streaming and take one response per turn.")

let temperature_arg =
  Arg.(
    value
    & opt float Params.default.temperature
    & info [ "t"; "temperature" ] ~docv:"T" ~doc:"The sampling temperature.")

let max_tokens_arg =
  Arg.(
    value
    & opt int Params.default.max_tokens
    & info [ "n"; "max-tokens" ] ~docv:"N"
        ~doc:"The maximum number of tokens to generate.")

let system_arg default =
  Arg.(
    value & opt string default
    & info [ "s"; "system" ] ~docv:"TEXT" ~doc:"The system prompt.")

let prompt_pos =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"PROMPT" ~doc:"The prompt to send.")

let dir_arg =
  Arg.(
    value & opt string "."
    & info [ "d"; "dir" ] ~docv:"DIR"
        ~doc:"The workspace directory the tools are confined to.")

let agent_prompt_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "p"; "prompt" ] ~docv:"PROMPT"
        ~doc:"Send a single PROMPT and exit instead of the interactive REPL.")

let chat_cmd =
  let doc = "Send one prompt to Claude and print the reply." in
  let term =
    Term.(
      const chat $ model_arg
      $ system_arg "You are a helpful assistant."
      $ no_stream_arg $ temperature_arg $ max_tokens_arg $ prompt_pos)
  in
  Cmd.v (Cmd.info "chat" ~doc) term

let agent_cmd =
  let doc = "Run a tool-using agent against Claude, confined to a workspace." in
  let term =
    Term.(
      const agent $ model_arg
      $ system_arg "You are a concise coding agent. Use tools when helpful."
      $ no_stream_arg $ temperature_arg $ max_tokens_arg $ dir_arg
      $ agent_prompt_arg)
  in
  Cmd.v (Cmd.info "agent" ~doc) term

let () =
  let doc = "Capability-confined tools for LLM agents (Anthropic Claude)." in
  let info = Cmd.info "ocaml-ai-agent" ~version:"0.1" ~doc in
  exit (Cmd.eval (Cmd.group info [ chat_cmd; agent_cmd ]))
