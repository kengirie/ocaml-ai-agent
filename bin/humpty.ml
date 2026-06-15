(* humpty: a single CLI over the DS4 inference engine that doubles as a guided
   tour of how a language-model agent is assembled.

   The subcommands are meant to be read in order:
     download  fetch a model's weights onto this machine
     chat      send one prompt to the model and print the reply
     agent     wrap that same model in a tool-using loop
     list      show which models are available

   Models live under $XDG_DATA_HOME/ds4 (e.g. ~/.local/share/ds4); commands
   with no --model pick the first *.gguf found there. *)

module V4 = Deepseek.V4
module Agent = Deepseek.Agent
module Toolbox = Deepseek.Toolbox
module Model = Deepseek_cmd.Model

let model_dir = Model.dir

let guard f =
  try Ok (f ()) with
  | Failure msg -> Error msg
  | e -> Error (Printexc.to_string e)

(* The model catalogue and the --model resolution policy live in
   {!Deepseek_cmd.Model}; surface its errors through [guard]. *)
let resolve_model ~xdg model_opt =
  match Model.resolve ~dir:(Model.dir xdg) model_opt with
  | Ok path -> path
  | Error e -> failwith e

(* ---- chat -------------------------------------------------------------- *)

(* The DS4 RNG is degenerate at state 0, so a 0 request becomes a per-run seed
   derived from the clock and pid. *)
let resolve_seed = function
  | 0 ->
      let t = Int64.of_float (Unix.gettimeofday () *. 1_000_000.) in
      let p = Int64.shift_left (Int64.of_int (Unix.getpid ())) 32 in
      let s = Int64.logxor t p in
      if s = 0L then 0x2545F4914F6CDD1DL else s
  | n -> Int64.of_int n

let chat model_opt system think max_tokens temperature seed prompt =
  guard @@ fun () ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let xdg = Xdge.create fs "ds4" in
  let model_path = resolve_model ~xdg model_opt in
  let stdout = Eio.Stdenv.stdout env in
  let cache = Xdge.cache_dir xdg in
  let model = Eio.Path.(fs / model_path) in
  let engine = V4.create ~cache ~model () in
  Eio.Flow.copy_string
    (Printf.sprintf "model: %s  (vocab %d)\n\n" (V4.model_name engine)
       (V4.vocab_size engine))
    stdout;
  V4.generate engine ~system ~think ~max_tokens ~temperature
    ~seed:(resolve_seed seed)
    ~on_token:(fun s -> Eio.Flow.copy_string s stdout)
    prompt;
  Eio.Flow.copy_string "\n" stdout

(* ---- download ---------------------------------------------------------- *)

let download (m : Model.t) token_opt =
  guard @@ fun () ->
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let xdg = Xdge.create fs "ds4" in
  let proc = Eio.Stdenv.process_mgr env in
  let dir = model_dir xdg in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 Eio.Path.(fs / dir);
  let token =
    match token_opt with
    | Some _ -> token_opt
    | None -> Sys.getenv_opt "HF_TOKEN"
  in
  (* [hf] arguments after the command word, shared by both invocations. The
     process inherits our stdin/stdout/stderr, so hf's progress bar shows. *)
  let hf_args file =
    [ "download"; Model.hf_repo; file; "--repo-type"; "model"; "--local-dir"; dir ]
    @ match token with Some t -> [ "--token"; t ] | None -> []
  in
  List.iter
    (fun file ->
      Printf.eprintf
        "Downloading %s\n  from https://huggingface.co/%s\n  into %s\n%!" file
        Model.hf_repo dir;
      (* Prefer a directly-installed [hf]; if that is missing or fails, fall
         back to running it through [uvx], which fetches it on demand. *)
      try Eio.Process.run proc ("hf" :: hf_args file)
      with _ ->
        Printf.eprintf "  ('hf' unavailable or failed; retrying via 'uvx hf')\n%!";
        Eio.Process.run proc ("uvx" :: "hf" :: hf_args file))
    m.files;
  Printf.eprintf "\nDone. 'humpty chat' will find models in %s\n%!" dir

(* ---- list -------------------------------------------------------------- *)

let list () =
  guard @@ fun () ->
  Eio_main.run @@ fun env ->
  let xdg = Xdge.create (Eio.Stdenv.fs env) "ds4" in
  let dir = model_dir xdg in
  Printf.printf "Models (download dir: %s)\n\n" dir;
  Printf.printf "  %-3s %-22s %-9s %s\n" "" "TARGET" "ALIASES" "DESCRIPTION";
  List.iter
    (fun (m : Model.t) ->
      Printf.printf "  %-3s %-22s %-9s %s\n"
        (if Model.present ~dir m then "[*]" else "[ ]")
        m.name
        (String.concat "," m.aliases)
        m.descr)
    Model.all;
  (* Any other GGUFs sitting in the dir that aren't known targets. *)
  let known =
    List.concat_map (fun (m : Model.t) -> m.files) Model.all
    |> List.sort_uniq String.compare
  in
  let others =
    match Sys.readdir dir with
    | exception Sys_error _ -> []
    | entries ->
        Array.to_list entries
        |> List.filter (fun f ->
            Filename.check_suffix f ".gguf" && not (List.mem f known))
        |> List.sort String.compare
  in
  if others <> [] then begin
    Printf.printf "\nOther GGUF files present (not download targets):\n";
    List.iter (fun f -> Printf.printf "  [*] %s\n" f) others
  end;
  Printf.printf "\n[*] = present, [ ] = not downloaded\n"

(* ---- agent ------------------------------------------------------------- *)

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

let agent model_opt workspace system think =
  guard @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  let xdg = Xdge.create fs "ds4" in
  let proc = Eio.Stdenv.process_mgr env in
  let net = Eio.Stdenv.net env in
  let model_path = resolve_model ~xdg model_opt in
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

let log =
  let setup style_renderer level =
    Fmt_tty.setup_std_outputs ?style_renderer ();
    Logs.set_level level;
    Logs.set_reporter (Logs_fmt.reporter ());
    Logs_threaded.enable ();
    V4.forward_logs ()
  in
  Term.(const setup $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let with_log t = Term.(const (fun () v -> v) $ log $ t)
let model = Model.arg

(* ---- list command ---- *)

let list_cmd =
  let doc = "List the known models and show which are already downloaded." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "This is the starting point of the tour: it shows every model humpty \
         knows how to download, together with a marker for the ones whose \
         weights are already present on this machine. Use it to decide which \
         model to pass to $(b,humpty download).";
    ]
  in
  Cmd.v (Cmd.info "list" ~doc ~man) Term.(const list $ const ())

(* ---- download command ---- *)

let target = Model.target_arg

let token =
  Arg.(
    value
    & opt (some string) None
    & info [ "token" ] ~docv:"TOKEN"
        ~doc:
          "A Hugging Face access token, used for models that require one. When \
           omitted, the HF_TOKEN environment variable and then the local \
           Hugging Face login are tried in turn.")

let download_cmd =
  let doc = "Download a model's weights onto this machine." in
  let man =
    `S Manpage.s_description
    :: `P
         "Before you can chat with a model or run the agent, the model's \
          weights must be present locally. Having chosen a model with \
          $(b,humpty list), this step fetches its GGUF files from Hugging Face \
          and stores them where the other subcommands look for them."
    :: `P
         "Either the $(b,uv) tool or the Hugging Face command-line tool must be \
          installed and on your PATH, because the download is performed by \
          invoking the Hugging Face downloader."
    :: `P "Choose one of the following targets by name or alias:"
    :: `S "TARGETS"
    :: List.map
         (fun (m : Model.t) ->
           let label =
             match m.aliases with
             | [] -> m.name
             | a -> Printf.sprintf "%s (%s)" m.name (String.concat ", " a)
           in
           `I (label, m.descr))
         Model.all
  in
  Cmd.v (Cmd.info "download" ~doc ~man) Term.(const download $ target $ token)

(* ---- chat command ---- *)

let chat_system =
  Arg.(
    value
    & opt string "You are a helpful assistant"
    & info [ "s"; "system" ] ~docv:"TEXT"
        ~doc:"The system prompt that sets the model's role and behaviour.")

let chat_think =
  Arg.(
    value
    & opt (enum [ ("none", `None); ("high", `High); ("max", `Max) ]) `None
    & info [ "think" ] ~docv:"MODE"
        ~doc:
          "How much the model reasons before answering, one of none, high, or \
           max.")

let max_tokens =
  Arg.(
    value & opt int 2048
    & info [ "n"; "max-tokens" ] ~docv:"N"
        ~doc:"The maximum number of tokens to generate.")

let temperature =
  Arg.(
    value & opt float 1.0
    & info [ "t"; "temperature" ] ~docv:"T"
        ~doc:"The sampling temperature; higher values give more varied replies.")

let seed =
  Arg.(
    value & opt int 0
    & info [ "seed" ] ~docv:"N"
        ~doc:
          "The seed for the random sampler; 0 chooses a fresh seed on each run.")

let prompt =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"PROMPT" ~doc:"The prompt to send to the model.")

let chat_cmd =
  let doc = "Send a single prompt to a model and print its reply." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "This is the simplest way to use a model and the building block that \
         every agent rests on. It sends one prompt, streams back the model's \
         reply, and exits.";
      `P
        "The model keeps no memory between runs and cannot take any action on \
         your behalf; it only turns your prompt into text. The agent \
         subcommand is what turns this single step into something that can act.";
    ]
  in
  let term =
    with_log
      Term.(
        const chat $ model $ chat_system $ chat_think $ max_tokens $ temperature
        $ seed $ prompt)
  in
  Cmd.v (Cmd.info "chat" ~doc ~man) term

(* ---- agent command ---- *)

let workspace =
  Arg.(
    value & opt string "."
    & info [ "d"; "dir" ] ~docv:"DIR"
        ~doc:
          "The workspace directory the agent's file and shell tools are \
           confined to.")

let agent_system =
  Arg.(
    value
    & opt string "You are a concise coding agent. Use tools when helpful."
    & info [ "s"; "system" ] ~docv:"TEXT"
        ~doc:"The system prompt that sets the agent's role and behaviour.")

let agent_think =
  Arg.(
    value
    & opt (enum [ ("chat", Dsml.Chat); ("thinking", Dsml.Thinking) ]) Dsml.Chat
    & info [ "think" ] ~docv:"MODE"
        ~doc:
          "Whether the agent replies directly (chat) or reasons step by step \
           before acting (thinking).")

let agent_cmd =
  let doc = "Run an interactive agent that uses tools to act on your requests." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "An agent is a model placed in a loop and given tools. This is the \
         final step of the tour: it starts an interactive session in which the \
         model can read and write files, resolve host names, and run shell \
         commands in order to carry out your requests across several turns.";
      `P
        "The file and shell tools are confined to the workspace directory \
         given by $(b,--dir), so the agent cannot touch anything outside it. \
         Type a request at the prompt and press Enter; press Ctrl-D to exit.";
    ]
  in
  let term =
    with_log Term.(const agent $ model $ workspace $ agent_system $ agent_think)
  in
  Cmd.v (Cmd.info "agent" ~doc ~man) term

(* ---- top-level group ---- *)

let backend_name =
  match V4.backend with `Metal -> "Metal" | `Cuda -> "CUDA" | `Cpu -> "CPU"

let () =
  let doc = "Run the DeepSeek V4 model and learn how an agent is built." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "humpty runs the DeepSeek V4 language model on your own machine and, \
         one subcommand at a time, shows how an autonomous agent is assembled \
         from simpler parts.";
      `P
        "Work through the subcommands in order. $(b,list) shows the available \
         models so that you can decide which one to use. $(b,download) fetches \
         the model you chose onto this machine. $(b,chat) sends a single prompt \
         to that model and prints the reply, which is the one operation every \
         agent is built on. $(b,agent) wraps the same model in a loop and gives \
         it tools, so that it can read files, run commands, and act on your \
         requests over many turns.";
      `P
        (Printf.sprintf "This build runs the model on the %s backend."
           backend_name);
    ]
  in
  let info = Cmd.info "humpty" ~version:"0.1" ~doc ~man in
  exit
    (Cmd.eval_result
       (Cmd.group info [ download_cmd; chat_cmd; agent_cmd; list_cmd ]))
