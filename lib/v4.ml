type engine
type session
type think = [ `None | `High | `Max ]

let think_to_int = function `None -> 0 | `High -> 1 | `Max -> 2

(* C FFI (ds4_stubs.c). *)
external engine_open : string -> engine = "caml_ds4_engine_open"
external model_name : engine -> string = "caml_ds4_engine_model_name"
external vocab_size : engine -> int = "caml_ds4_engine_vocab_size"
external token_eos : engine -> int = "caml_ds4_token_eos"

external encode_chat_prompt : engine -> string -> string -> int -> int array
  = "caml_ds4_encode_chat_prompt"

external think_mode_for_context : int -> int -> int
  = "caml_ds4_think_mode_for_context"

external session_create : engine -> int -> int64 -> session
  = "caml_ds4_session_create"

external session_sync : session -> int array -> unit = "caml_ds4_session_sync"
external session_ctx : session -> int = "caml_ds4_session_ctx"
external session_pos : session -> int = "caml_ds4_session_pos"

external session_sample : session -> float -> float -> float -> int
  = "caml_ds4_session_sample"

external session_eval : session -> int -> unit = "caml_ds4_session_eval"
external token_text : engine -> int -> string = "caml_ds4_token_text"

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

let create ~cache ~model =
  let metal_dir = Eio.Path.(cache / "ds4" / "metal") in
  materialize_shaders ~metal_dir;
  engine_open (Eio.Path.native_exn model)

let generate engine ?(system = "You are a helpful assistant") ?(ctx_size = 4096)
    ?(max_tokens = 2048) ?(temperature = 1.0) ?(top_p = 1.0) ?(min_p = 0.05)
    ?(think = `None) ?(seed = 0x2545F4914F6CDD1DL) ~on_token prompt =
  (* MAX effort is only valid at large context; downgrade as the engine's own
     CLI does, so the prompt token stream matches. *)
  let think_int = think_mode_for_context (think_to_int think) ctx_size in
  let toks = encode_chat_prompt engine system prompt think_int in
  let session = session_create engine ctx_size seed in
  session_sync session toks;
  (* Clamp generation to the remaining context, mirroring ds4_cli.c: never let
     decode advance the position to the context bound. *)
  let room = session_ctx session - session_pos session in
  let budget = if room <= 1 then 0 else min max_tokens (room - 1) in
  let eos = token_eos engine in
  let rec loop n =
    if n < budget then begin
      let tok = session_sample session temperature top_p min_p in
      if tok <> eos then begin
        (* Commit the token's KV state before showing it. *)
        session_eval session tok;
        on_token (token_text engine tok);
        loop (n + 1)
      end
    end
  in
  loop 0
