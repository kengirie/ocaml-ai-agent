(* ds4: a small CLI over the DS4 Metal inference engine.

   Subcommands:
     chat      single prompt/response
     download  fetch GGUF model(s) from Hugging Face into the XDG data dir

   Models live under $XDG_DATA_HOME/ds4 (e.g. ~/.local/share/ds4); [chat] with
   no --model picks the first *.gguf found there. *)

let model_dir xdg = Filename.concat (Xdg.data_dir xdg) "ds4"

(* Run [f], turning any raised error into a clean CLI message (Cmd.eval_result
   prints it and exits nonzero) instead of an "internal error" backtrace. *)
let guard f =
  try Ok (f ()) with
  | Failure msg -> Error msg
  | e -> Error (Printexc.to_string e)

(* ---- models ------------------------------------------------------------ *)

let hf_repo = "antirez/deepseek-v4-gguf"

type model = {
  name : string;  (** canonical download_model.sh target *)
  aliases : string list;  (** short forms accepted on the CLI *)
  files : string list;  (** GGUF file(s) in the HF repo *)
  descr : string;
}

(* Targets mirror download_model.sh; aliases are short hands for the CLI. *)
let models =
  [
    {
      name = "q2-imatrix";
      aliases = [ "q2" ];
      files =
        [
          "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf";
        ];
      descr = "2-bit Flash routed experts (~81 GB); for 96-128 GB RAM.";
    };
    {
      name = "q2-q4-imatrix";
      aliases = [ "q2q4" ];
      files =
        [
          "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed.gguf";
        ];
      descr = "Mixed Flash quant (~98 GB); higher quality for 128 GB.";
    };
    {
      name = "q4-imatrix";
      aliases = [ "q4" ];
      files =
        [
          "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf";
        ];
      descr = "4-bit Flash routed experts (~153 GB); for 256 GB+ RAM.";
    };
    {
      name = "pro-q2-imatrix";
      aliases = [ "pro-q2" ];
      files =
        [
          "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf";
        ];
      descr = "PRO q2 single file (~430 GB); for 512 GB RAM.";
    };
    {
      name = "pro-q4-layers00-30";
      aliases = [ "pro-q4-a" ];
      files = [ "DeepSeek-V4-Pro-Q4K-Layers00-30.gguf" ];
      descr = "PRO Q4 layers 0..30 (~426 GB); distributed coordinator.";
    };
    {
      name = "pro-q4-layers31-output";
      aliases = [ "pro-q4-b" ];
      files = [ "DeepSeek-V4-Pro-Q4K-Layers-31-output.gguf" ];
      descr = "PRO Q4 layers 31..output (~412 GB); distributed worker.";
    };
    {
      name = "pro-q4-split";
      aliases = [ "pro-q4" ];
      files =
        [
          "DeepSeek-V4-Pro-Q4K-Layers00-30.gguf";
          "DeepSeek-V4-Pro-Q4K-Layers-31-output.gguf";
        ];
      descr = "Both PRO Q4 split files (~838 GB total).";
    };
    {
      name = "mtp";
      aliases = [];
      files = [ "DeepSeek-V4-Flash-MTP-Q4K-Q8_0-F32.gguf" ];
      descr = "Optional speculative-decoding component (~3.5 GB).";
    };
  ]

(* A model is "present" when every one of its files exists in [dir]. *)
let model_present dir m =
  List.for_all (fun f -> Sys.file_exists (Filename.concat dir f)) m.files

(* Look up a model by canonical name or alias. *)
let find_model s =
  List.find_opt (fun m -> m.name = s || List.mem s m.aliases) models

(* ---- chat -------------------------------------------------------------- *)

let find_gguf dir =
  match Sys.is_directory dir with
  | exception Sys_error _ -> None
  | false -> None
  | true -> (
      Sys.readdir dir |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".gguf")
      |> List.sort String.compare
      |> function
      | [] -> None
      | f :: _ -> Some (Filename.concat dir f))

(* --model accepts a known name/alias (resolved to its single GGUF in the data
   dir) or an explicit filesystem path. *)
let resolve_model ~xdg = function
  | Some s -> (
      match find_model s with
      | Some { files = [ f ]; _ } ->
          let path = Filename.concat (model_dir xdg) f in
          if Sys.file_exists path then path
          else
            failwith
              (Printf.sprintf
                 "model '%s' is not downloaded; run 'ds4 download %s'" s s)
      | Some { name; files; _ } ->
          failwith
            (Printf.sprintf
               "model '%s' has %d files (%s); not usable for chat, pass an \
                explicit --model PATH"
               name (List.length files) (String.concat ", " files))
      | None -> s (* treat as a filesystem path *))
  | None -> (
      match Sys.getenv_opt "DS4_MODEL" with
      | Some m -> m
      | None -> (
          let data = model_dir xdg in
          match find_gguf data with
          | Some m -> m
          | None ->
              failwith
                (Printf.sprintf
                   "no model found: pass --model PATH|ALIAS, set DS4_MODEL, \
                    run 'ds4 download <target>', or place a .gguf in %s"
                   data)))

(* The DS4 RNG is degenerate at state 0, so a 0 request becomes a per-run seed
   derived from the clock and pid (matching the C CLI default). *)
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
  let xdg = Xdg.v ~env:Sys.getenv_opt () in
  let model_path = resolve_model ~xdg model_opt in
  let fs = Eio.Stdenv.fs env in
  let stdout = Eio.Stdenv.stdout env in
  let cache = Eio.Path.(fs / Xdg.cache_dir xdg) in
  let model = Eio.Path.(fs / model_path) in
  let engine = Ds4.create ~cache ~model in
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

let download m token_opt =
  guard @@ fun () ->
  Eio_main.run @@ fun env ->
  let xdg = Xdg.v ~env:Sys.getenv_opt () in
  let fs = Eio.Stdenv.fs env in
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
        hf_repo dir;
      let args =
        [
          "uvx";
          "hf";
          "download";
          hf_repo;
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
  let xdg = Xdg.v ~env:Sys.getenv_opt () in
  let dir = model_dir xdg in
  Printf.printf "Models (download dir: %s)\n\n" dir;
  Printf.printf "  %-3s %-22s %-9s %s\n" "" "TARGET" "ALIASES" "DESCRIPTION";
  List.iter
    (fun m ->
      Printf.printf "  %-3s %-22s %-9s %s\n"
        (if model_present dir m then "[*]" else "[ ]")
        m.name
        (String.concat "," m.aliases)
        m.descr)
    models;
  (* Any other GGUFs sitting in the dir that aren't known targets. *)
  let known =
    List.concat_map (fun m -> m.files) models |> List.sort_uniq String.compare
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

let model =
  Arg.(
    value
    & opt (some string) None
    & info [ "m"; "model" ] ~docv:"MODEL"
        ~doc:
          "GGUF model: a download target name or alias (e.g. 'q4'), or a path \
           to a .gguf file.")

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

(* Reusable term: a model target accepted by canonical name or any alias. *)
let target =
  let enum_assoc =
    List.concat_map
      (fun m -> (m.name, m) :: List.map (fun a -> (a, m)) m.aliases)
      models
  in
  let doc =
    "Model to download, by name or alias (run 'ds4 list' for the full table)."
  in
  Arg.(
    required & pos 0 (some (enum enum_assoc)) None & info [] ~docv:"TARGET" ~doc)

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
         (fun m ->
           let label =
             match m.aliases with
             | [] -> m.name
             | a -> Printf.sprintf "%s (%s)" m.name (String.concat ", " a)
           in
           `I (label, m.descr))
         models
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
