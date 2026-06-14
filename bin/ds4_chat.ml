(* ds4: a small CLI over the DS4 Metal inference engine.

   Subcommands:
     chat      single prompt/response
     download  fetch GGUF model(s) from Hugging Face into the XDG data dir

   Models live under $XDG_DATA_HOME/ds4 (e.g. ~/.local/share/ds4); [chat] with
   no --model picks the first *.gguf found there. *)

module Ds4 = Deepseek.V4
module Model = Deepseek_cmd.Model

let model_dir = Model.dir

(* Run [f], turning any raised error into a clean CLI message (Cmd.eval_result
   prints it and exits nonzero) instead of an "internal error" backtrace. *)
let guard f =
  try Ok (f ()) with
  | Failure msg -> Error msg
  | e -> Error (Printexc.to_string e)

(* ---- chat -------------------------------------------------------------- *)

(* The model catalogue and the --model resolution policy live in
   {!Deepseek_cmd.Model}; surface its errors through [guard]. *)
let resolve_model ~xdg model_opt =
  match Model.resolve ~dir:(Model.dir xdg) model_opt with
  | Ok path -> path
  | Error e -> failwith e

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
  let engine = Ds4.create ~cache ~model () in
  Eio.Flow.copy_string
    (Printf.sprintf "model: %s  (vocab %d)\n\n" (Ds4.model_name engine)
       (Ds4.vocab_size engine))
    stdout;
  Ds4.generate engine ~system ~think ~max_tokens ~temperature
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
  List.iter
    (fun file ->
      Printf.eprintf
        "Downloading %s\n  from https://huggingface.co/%s\n  into %s\n%!" file
        Model.hf_repo dir;
      let args =
        [
          "uvx";
          "hf";
          "download";
          Model.hf_repo;
          file;
          "--repo-type";
          "model";
          "--local-dir";
          dir;
        ]
        @ match token with Some t -> [ "--token"; t ] | None -> []
      in
      (* Inherits stdin/stdout/stderr from us, so hf's progress bar shows. *)
      Eio.Process.run proc args)
    m.files;
  Printf.eprintf "\nDone. 'ds4 chat' will find models in %s\n%!" dir

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

(* ---- cmdliner ---------------------------------------------------------- *)

open Cmdliner

let model = Model.arg

let system =
  Arg.(
    value
    & opt string "You are a helpful assistant"
    & info [ "s"; "system" ] ~docv:"TEXT" ~doc:"System prompt.")

let think =
  Arg.(
    value
    & opt (enum [ ("none", `None); ("high", `High); ("max", `Max) ]) `None
    & info [ "think" ] ~docv:"MODE" ~doc:"Reasoning effort: none, high, or max.")

let max_tokens =
  Arg.(
    value & opt int 2048
    & info [ "n"; "max-tokens" ] ~docv:"N" ~doc:"Maximum tokens to generate.")

let temperature =
  Arg.(
    value & opt float 1.0
    & info [ "t"; "temperature" ] ~docv:"T" ~doc:"Sampling temperature.")

let seed =
  Arg.(
    value & opt int 0
    & info [ "seed" ] ~docv:"N" ~doc:"RNG seed (0 = per-run random).")

let prompt =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"PROMPT" ~doc:"The user prompt.")

let chat_cmd =
  let term =
    Term.(
      const chat $ model $ system $ think $ max_tokens $ temperature $ seed
      $ prompt)
  in
  Cmd.v (Cmd.info "chat" ~doc:"Single prompt/response.") term

let target = Model.target_arg

let token =
  Arg.(
    value
    & opt (some string) None
    & info [ "token" ] ~docv:"TOKEN"
        ~doc:
          "Hugging Face token (else the HF_TOKEN env var, else the local hf \
           login cache).")

let download_cmd =
  let doc = "Download GGUF model(s) from Hugging Face via 'uvx hf'." in
  let man =
    `S Manpage.s_description
    :: `P
         "Downloads into the XDG data dir, XDG_DATA_HOME/ds4 (e.g. \
          ~/.local/share/ds4), where 'ds4 chat' looks for models. Requires \
          'uv' (for 'uvx') on PATH." :: `S "TARGETS"
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
  let term = Term.(const download $ target $ token) in
  Cmd.v (Cmd.info "download" ~doc ~man) term

let list_cmd =
  let term = Term.(const list $ const ()) in
  Cmd.v
    (Cmd.info "list" ~doc:"List known models and which are downloaded.")
    term

let () =
  let info =
    Cmd.info "ds4" ~version:"0.1"
      ~doc:"DeepSeek V4 inference (Metal) — chat, download, and list."
  in
  exit (Cmd.eval_result (Cmd.group info [ chat_cmd; download_cmd; list_cmd ]))
