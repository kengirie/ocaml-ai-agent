(** Deepseek v4 inference engine (Metal).

    Single prompt/response: open a GGUF model, encode a chat prompt,
    and stream the generated tokens. The heavy C calls
    release the OCaml runtime lock while Metal runs. *)

type engine
(** A loaded model *)

type think = [ `None | `High | `Max ]
(** Reasoning effort encoded into the chat prompt. *)

val create : cache:_ Eio.Path.t -> model:_ Eio.Path.t -> engine
(** [create ~cache ~model] materialises the embedded Metal kernels under
    and opens the GGUF model at [model].

    [cache] is a base cache directory.
    Raises [Failure] if the model cannot be opened. *)

val model_name : engine -> string

val vocab_size : engine -> int

val generate :
  engine ->
  ?system:string ->
  ?ctx_size:int ->
  ?max_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?min_p:float ->
  ?think:think ->
  ?seed:int64 ->
  on_token:(string -> unit) ->
  string ->
  unit
(** [generate engine ~on_token prompt] encodes [prompt] as a chat turn, runs
    prefill, then samples tokens one at a time, passing each decoded piece of
    text to [on_token], until the end-of-sequence token or [max_tokens] (default
    2048). [temperature]/[top_p]/[min_p] control sampling (DS4 defaults: 1.0 /
    1.0 / 0.05); [ctx_size] defaults to 4096. *)
