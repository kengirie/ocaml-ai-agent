module Model = struct
  type t = {
    name : string;
    aliases : string list;
    files : string list;
    descr : string;
  }

  let hf_repo = "antirez/deepseek-v4-gguf"

  let all =
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
    ]

  let find s = List.find_opt (fun m -> m.name = s || List.mem s m.aliases) all

  (* xdge scopes paths to the app name ("ds4"), so its data dir is already
     XDG_DATA_HOME/ds4; render it to a plain path for the string-based helpers
     below. *)
  let dir xdg = Eio.Path.native_exn (Xdge.data_dir xdg)

  let present ~dir m =
    List.for_all (fun f -> Sys.file_exists (Filename.concat dir f)) m.files

  (* First *.gguf in [d] in lexical order, if any. *)
  let first_gguf d =
    match Sys.readdir d with
    | exception Sys_error _ -> None
    | entries -> (
        Array.to_list entries
        |> List.filter (fun f -> Filename.check_suffix f ".gguf")
        |> List.sort String.compare
        |> function
        | [] -> None
        | f :: _ -> Some (Filename.concat d f))

  let resolve ?(env = Sys.getenv_opt) ~dir:data override =
    match override with
    | Some s -> (
        match find s with
        | Some { files = [ f ]; _ } ->
            let path = Filename.concat data f in
            if Sys.file_exists path then Ok path
            else
              Error
                (Printf.sprintf
                   "model '%s' is not downloaded; run 'ds4 download %s'" s s)
        | Some { name; files; _ } ->
            Error
              (Printf.sprintf
                 "model '%s' is split across %d files (%s) and cannot be \
                  loaded as a single model"
                 name (List.length files) (String.concat ", " files))
        | None -> Ok s (* unknown name: treat as a filesystem path *))
    | None -> (
        match env "DS4_MODEL" with
        | Some m -> Ok m
        | None -> (
            match first_gguf data with
            | Some m -> Ok m
            | None ->
                Error
                  (Printf.sprintf
                     "no model found: pass --model PATH|ALIAS, set DS4_MODEL, \
                      run 'ds4 download <target>', or place a .gguf in %s"
                     data)))

  open Cmdliner

  let arg =
    Arg.(
      value
      & opt (some string) None
      & info [ "m"; "model" ] ~docv:"MODEL"
          ~doc:
            "GGUF model: a download target name or alias (e.g. 'q4'), or a \
             path to a .gguf file. When omitted, the DS4_MODEL environment \
             variable is used, then the first *.gguf in the data directory \
             (XDG_DATA_HOME/ds4).")

  let target_arg =
    let enum_assoc =
      List.concat_map
        (fun m -> (m.name, m) :: List.map (fun a -> (a, m)) m.aliases)
        all
    in
    let doc =
      "Model to download, by name or alias (run 'ds4 list' for the full table)."
    in
    Arg.(
      required
      & pos 0 (some (enum enum_assoc)) None
      & info [] ~docv:"TARGET" ~doc)
end
