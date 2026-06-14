(* ds4-agent: a tiny interactive coding agent over the DS4 Metal engine.

   It wires a handful of filesystem/shell tools into {!Deepseek.Agent} and runs
   a read-eval loop on stdin. Model resolution mirrors `ds4 chat`: --model takes
   a path, else $DS4_MODEL, else the first *.gguf under $XDG_DATA_HOME/ds4. *)

module Agent = Deepseek.Agent
module Toolbox = Deepseek.Toolbox
module V4 = Deepseek.V4

(* ---- output ------------------------------------------------------------ *)

let truncate n s = if String.length s <= n then s else String.sub s 0 n ^ "…"

let on_event : Agent.event -> unit = function
  | Agent.Content c ->
      print_string c;
      flush stdout
  | Agent.Reasoning r ->
      Printf.eprintf "\027[2m%s\027[0m" r;
      flush stderr
  | Agent.Tool_call tc ->
      Printf.printf "\n\027[36m⚙ %s %s\027[0m\n%!" tc.name
        (truncate 120 tc.arguments)
  | Agent.Tool_result (name, result) ->
      Printf.printf "\027[2m→ %s: %s\027[0m\n%!" name (truncate 200 result)
  | Agent.Done -> print_newline ()

(* ---- main -------------------------------------------------------------- *)

let main model_opt workspace system think =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  let xdg = Xdge.create fs "ds4" in
  let proc = Eio.Stdenv.process_mgr env in
  let net = Eio.Stdenv.net env in
  let model_path =
    match
      Deepseek_cmd.Model.resolve ~dir:(Deepseek_cmd.Model.dir xdg) model_opt
    with
    | Ok p -> p
    | Error e ->
        prerr_endline e;
        exit 1
  in
  let cache = Xdge.cache_dir xdg in
  (* Run the engine on its own domain so the REPL domain stays responsive. *)
  let engine =
    V4.create ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~cache
      ~model:Eio.Path.(fs / model_path)
      ()
  in
  (* Sandbox the filesystem tools to [workspace]: the read/write tools receive
     only this directory capability, so they cannot reach outside it. *)
  Eio.Path.with_open_dir Eio.Path.(fs / workspace) @@ fun ws ->
  let agent =
    Agent.create engine ~system ~thinking:think
      ~tools:
        [
          Toolbox.read ~dir:ws;
          Toolbox.write ~dir:ws;
          Toolbox.dns ~net;
          Toolbox.bash ~proc;
        ]
  in
  Printf.printf "model: %s  (vocab %d)\n" (V4.model_name engine)
    (V4.vocab_size engine);
  Printf.printf
    "workspace: %s\ntools: read, write, dns, bash.  Ctrl-D to exit.\n\n%!"
    workspace;
  let stdin = Eio.Buf_read.of_flow (Eio.Stdenv.stdin env) ~max_size:1_000_000 in
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

(* ---- cmdliner ---------------------------------------------------------- *)

open Cmdliner

let model = Deepseek_cmd.Model.arg

let workspace =
  Arg.(
    value & opt string "."
    & info [ "d"; "dir" ] ~docv:"DIR"
        ~doc:"Workspace directory the read/write tools are sandboxed to.")

let system =
  Arg.(
    value
    & opt string "You are a concise coding agent. Use tools when helpful."
    & info [ "s"; "system" ] ~docv:"TEXT" ~doc:"System prompt.")

let think =
  Arg.(
    value
    & opt (enum [ ("chat", Dsml.Chat); ("thinking", Dsml.Thinking) ]) Dsml.Chat
    & info [ "think" ] ~docv:"MODE" ~doc:"Reply mode: chat or thinking.")

let () =
  let term = Term.(const main $ model $ workspace $ system $ think) in
  let info =
    Cmd.info "ds4-agent" ~version:"0.1"
      ~doc:"Interactive tool-using agent over DeepSeek V4 (Metal)."
  in
  exit (Cmd.eval (Cmd.v info term))
