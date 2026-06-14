type raw_engine
type raw_session
type think = [ `None | `High | `Max ]

let think_to_int = function `None -> 0 | `High -> 1 | `Max -> 2

(* C FFI (ds4_stubs.c). The heavy calls release the OCaml runtime lock while
   Metal runs; they must never touch the engine concurrently, so all of them are
   funnelled through [run] onto the engine's worker domain (or run inline). *)
external c_engine_open : string -> raw_engine = "caml_ds4_engine_open"
external c_model_name : raw_engine -> string = "caml_ds4_engine_model_name"
external c_vocab_size : raw_engine -> int = "caml_ds4_engine_vocab_size"
external c_token_eos : raw_engine -> int = "caml_ds4_token_eos"

external c_encode_chat_prompt :
  raw_engine -> string -> string -> int -> int array
  = "caml_ds4_encode_chat_prompt"

external c_tokenize_rendered : raw_engine -> string -> int array
  = "caml_ds4_tokenize_rendered_chat"

external c_think_mode_for_context : int -> int -> int
  = "caml_ds4_think_mode_for_context"

external c_session_create : raw_engine -> int -> int64 -> raw_session
  = "caml_ds4_session_create"

external c_session_sync : raw_session -> int array -> unit
  = "caml_ds4_session_sync"

external c_session_ctx : raw_session -> int = "caml_ds4_session_ctx"
external c_session_pos : raw_session -> int = "caml_ds4_session_pos"

external c_session_sample : raw_session -> float -> float -> float -> int
  = "caml_ds4_session_sample"

external c_session_eval : raw_session -> int -> unit = "caml_ds4_session_eval"
external c_token_text : raw_engine -> int -> string = "caml_ds4_token_text"

(* An engine and its (optional) dedicated worker domain. When [worker] is set, a
   single domain owns every C call into the engine: [run] hands the work to that
   domain and blocks only the calling fiber, so the main domain stays free to
   schedule other fibers while Metal runs. The worker runs one job at a time, so
   the engine is never entered concurrently. *)
type job = Job : (unit -> 'a) * ('a, exn) result Eio.Promise.u -> job
type worker = job Eio.Stream.t
type engine = { raw : raw_engine; worker : worker option }

(* Hand [f] to the worker domain and wait for its result (re-raising on the
   calling domain if it failed). *)
let run_on (w : worker) f =
  let result, set = Eio.Promise.create () in
  Eio.Stream.add w (Job (f, set));
  match Eio.Promise.await result with Ok v -> v | Error e -> raise e

let run engine f =
  match engine.worker with None -> f () | Some w -> run_on w f

(* Host the engine's job loop on a fresh domain. It is a daemon fiber, so the
   switch closing cancels both the loop and its domain (Domain_manager.run
   propagates the cancellation). One [Domain_manager.run] keeps a single
   persistent domain — calling it per job would spawn a new domain each time. *)
let spawn_worker ~sw domain_mgr : worker =
  let stream = Eio.Stream.create 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Domain_manager.run domain_mgr (fun () ->
          let rec loop () =
            let (Job (f, set)) = Eio.Stream.take stream in
            (match f () with
            | v -> Eio.Promise.resolve set (Ok v)
            | exception e -> Eio.Promise.resolve set (Error e));
            loop ()
          in
          loop ()));
  stream

(* Write each embedded Metal kernel into [metal_dir] and point the engine at it
   via the per-kernel DS4_METAL_<NAME>_SOURCE override the C backend reads at
   open time. Makes the binary relocatable instead of cwd-relative. *)
let materialize_shaders ~metal_dir =
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 metal_dir;
  List.iter
    (fun (name, body) ->
      let path = Eio.Path.(metal_dir / (name ^ ".metal")) in
      Eio.Path.save ~create:(`Or_truncate 0o644) path body;
      let var = "DS4_METAL_" ^ String.uppercase_ascii name ^ "_SOURCE" in
      Unix.putenv var (Eio.Path.native_exn path))
    Shaders.sources

let create ?domain_mgr ?sw ~cache ~model () =
  (* Shader I/O and path resolution use the calling domain's filesystem
     capability, so they stay here; only [c_engine_open] is handed to the
     worker. *)
  let metal_dir = Eio.Path.(cache / "ds4" / "metal") in
  materialize_shaders ~metal_dir;
  let path = Eio.Path.native_exn model in
  let worker =
    match (domain_mgr, sw) with
    | Some dm, Some sw -> Some (spawn_worker ~sw dm)
    | Some _, None -> invalid_arg "V4.create: ~domain_mgr requires ~sw"
    | None, _ -> None
  in
  let raw =
    match worker with
    | Some w -> run_on w (fun () -> c_engine_open path)
    | None -> c_engine_open path
  in
  { raw; worker }

let model_name e = run e (fun () -> c_model_name e.raw)
let vocab_size e = run e (fun () -> c_vocab_size e.raw)
let token_eos e = run e (fun () -> c_token_eos e.raw)
let token_text e tok = run e (fun () -> c_token_text e.raw tok)

let generate engine ?(system = "You are a helpful assistant") ?(ctx_size = 4096)
    ?(max_tokens = 2048) ?(temperature = 1.0) ?(top_p = 1.0) ?(min_p = 0.05)
    ?(think = `None) ?(seed = 0x2545F4914F6CDD1DL) ~on_token prompt =
  (* MAX effort is only valid at large context; downgrade as the engine's own
     CLI does, so the prompt token stream matches. The loop and [on_token] run
     on the calling domain; only the C primitives hop to the worker. *)
  let think_int = c_think_mode_for_context (think_to_int think) ctx_size in
  let toks =
    run engine (fun () ->
        c_encode_chat_prompt engine.raw system prompt think_int)
  in
  let session =
    run engine (fun () -> c_session_create engine.raw ctx_size seed)
  in
  run engine (fun () -> c_session_sync session toks);
  (* Clamp generation to the remaining context, mirroring ds4_cli.c: never let
     decode advance the position to the context bound. *)
  let room =
    run engine (fun () -> c_session_ctx session)
    - run engine (fun () -> c_session_pos session)
  in
  let budget = if room <= 1 then 0 else min max_tokens (room - 1) in
  let eos = token_eos engine in
  let rec loop n =
    if n < budget then begin
      let tok =
        run engine (fun () -> c_session_sample session temperature top_p min_p)
      in
      if tok <> eos then begin
        (* Commit the token's KV state before showing it. *)
        run engine (fun () -> c_session_eval session tok);
        on_token (token_text engine tok);
        loop (n + 1)
      end
    end
  in
  loop 0

(* A persistent inference session: the building block for multi-turn agents.
   An agent drives a session directly so the KV cache survives across turns and
   tool round-trips. The conversation is rendered to a prompt by the Dsml
   library, tokenised verbatim with [tokenize], and synced; [sync] reuses the
   matching KV prefix, so re-syncing the grown conversation each turn prefills
   only the new tokens. Each call hops to the engine's worker domain via [run]. *)
module Session = struct
  type t = { s : raw_session; eng : engine }

  let create engine ~ctx_size ~seed =
    {
      s = run engine (fun () -> c_session_create engine.raw ctx_size seed);
      eng = engine;
    }

  let tokenize engine text =
    run engine (fun () -> c_tokenize_rendered engine.raw text)

  let sync t tokens = run t.eng (fun () -> c_session_sync t.s tokens)

  let sample t ~temperature ~top_p ~min_p =
    run t.eng (fun () -> c_session_sample t.s temperature top_p min_p)

  let eval t token = run t.eng (fun () -> c_session_eval t.s token)
  let ctx t = run t.eng (fun () -> c_session_ctx t.s)
  let pos t = run t.eng (fun () -> c_session_pos t.s)
end
