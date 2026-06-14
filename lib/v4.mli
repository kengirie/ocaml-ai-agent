(** Deepseek v4 inference engine.

    Single prompt/response: open a GGUF model, encode a chat prompt, and stream
    the generated tokens. The heavy C calls release the OCaml runtime lock while
    the backend runs, and {!create} can place the engine on its own Eio domain
    so the calling domain keeps running other fibers during inference.

    The backend (Apple Metal or CPU) is fixed at link time by the chosen
    implementation library; this interface is the same for all of them. *)

type engine
(** A loaded model *)

type think = [ `None | `High | `Max ]
(** Reasoning effort encoded into the chat prompt. *)

val create :
  ?domain_mgr:_ Eio.Domain_manager.t ->
  ?sw:Eio.Switch.t ->
  cache:_ Eio.Path.t ->
  model:_ Eio.Path.t ->
  unit ->
  engine
(** [create ~cache ~model ()] materialises the backend's embedded GPU kernels
    under [cache] (the Metal backend writes its [.metal] kernels there; the CPU
    backend has none, so this is a no-op) and opens the GGUF model at [model].
    [cache] is the application cache directory; kernels are written under
    [cache]/metal. Raises [Failure] if the model cannot be opened.

    [domain_mgr] runs the engine on a dedicated worker domain (one
    {!Eio.Domain_manager.run} hosting a job loop): every inference call is run
    there, so the calling domain stays free to run other fibers while Metal
    works. It requires [sw], whose lifetime bounds the worker, and raises
    [Invalid_argument] if given without it. Omit both to run inference inline on
    the calling domain.

    The engine must be used only from within [sw] when a worker is attached, and
    it is never entered concurrently — calls are serialised onto the worker. *)

val model_name : engine -> string
val vocab_size : engine -> int

val token_eos : engine -> int
(** [token_eos engine] is the end-of-sequence token id for [engine]'s model.
    Sampling returns it to signal that a turn is complete. *)

val token_text : engine -> int -> string
(** [token_text engine tok] is the decoded UTF-8 text piece for token [tok] in
    [engine]'s vocabulary. Concatenating the pieces of a sampled sequence yields
    the generated text. *)

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

(** A persistent inference session that retains its KV cache across turns.

    A session is the building block for multi-turn agents. The caller renders a
    whole conversation to a prompt, tokenises it with {!Session.tokenize}, feeds
    it with {!Session.sync}, and then alternates {!Session.sample} and
    {!Session.eval} to stream the reply. Because {!Session.sync} reuses the KV
    prefix shared with the previous prompt, re-feeding a conversation that has
    grown by one turn prefills only the new tokens. *)
module Session : sig
  type t
  (** A live inference session bound to one engine, holding the KV cache and the
      sampling RNG state. *)

  val create : engine -> ctx_size:int -> seed:int64 -> t
  (** [create engine ~ctx_size ~seed] opens a session on [engine] with a context
      window of [ctx_size] tokens and its sampling RNG initialised from [seed].
  *)

  val tokenize : engine -> string -> int array
  (** [tokenize engine prompt] tokenises [prompt] verbatim as an
      already-rendered chat string, leaving its markup as-is for the model. Pair
      it with a prompt produced by [Dsml.encode_messages]. *)

  val sync : t -> int array -> unit
  (** [sync t tokens] makes [tokens] the session's current prompt, keeping the
      longest prefix that matches what is already in the KV cache and prefilling
      the remaining tokens. *)

  val sample : t -> temperature:float -> top_p:float -> min_p:float -> int
  (** [sample t ~temperature ~top_p ~min_p] draws the next token from the
      current logits under the given sampling parameters and advances the RNG.
      Pass the result to {!eval} to commit it to the cache. *)

  val eval : t -> int -> unit
  (** [eval t tok] commits [tok] to the KV cache and advances the session
      position by one, so the next {!sample} conditions on it. *)

  val ctx : t -> int
  (** [ctx t] is the context window size [t] was created with, in tokens. *)

  val pos : t -> int
  (** [pos t] is the number of tokens currently committed to [t]'s KV cache. *)
end
