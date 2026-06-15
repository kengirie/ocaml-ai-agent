(** Cmdliner plumbing to expose DeepSeek config. *)

(** Choosing and locating a DeepSeek-V4 model.

    Models are distributed as one or more GGUF files under named download
    targets, each with short aliases. *)
module Model : sig
  type t = {
    name : string;  (** canonical target name *)
    aliases : string list;  (** short forms accepted on the CLI *)
    files : string list;  (** GGUF file(s) that make up the model *)
    descr : string;  (** one-line description *)
  }
  (** A known download target. *)

  val all : t list
  (** The catalogue of known targets. *)

  val hf_repo : string
  (** The Hugging Face repository the targets are downloaded from. *)

  val find : string -> t option
  (** [find s] is the target whose name or one of whose aliases is [s]. *)

  val dir : Xdge.t -> string
  (** [dir xdg] is the directory models are kept in ([XDG_DATA_HOME/ds4]). *)

  val present : dir:string -> t -> bool
  (** [present ~dir t] is [true] when every file of [t] exists under [dir]. *)

  val resolve :
    ?env:(string -> string option) ->
    dir:string ->
    string option ->
    (string, string) result
  (** [resolve ~dir override] is the path of the model to load, or an error
      message explaining how to supply one.

      [override] (typically from [--model]) may be a target name or alias, which
      is resolved to its single GGUF under [dir] — erroring if it is not
      downloaded, or if the target is split across several files — or any other
      string, which is taken as a filesystem path. When [override] is absent,
      [DS4_MODEL] is tried, then the first [*.gguf] under [dir] in lexical
      order.

      [env] reads environment variables (default {!Sys.getenv_opt}); [dir] is
      the model data directory, typically {!dir} applied to an xdge context. *)

  val arg : string option Cmdliner.Term.t
  (** [arg] is the [-m]/[--model] argument: a target name, alias, or path, or
      [None] to fall back to the environment and data directory. *)

  val target_arg : t Cmdliner.Term.t
  (** [target_arg] is a required positional [TARGET] argument naming a {!t} by
      its name or an alias, for commands that act on a catalogue entry (such as
      download and list). *)
end
