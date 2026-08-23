# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

`ocaml-ai-agent` is a small, **cloud-only** tool-using LLM agent in OCaml 5,
built on [Eio](https://github.com/ocaml-multicore/eio) (effects-based
concurrency) and [piaf](https://github.com/anmonteiro/piaf) (HTTP client).
It ships a library (`ocaml_ai_agent`) and a `cmdliner` CLI (`bin/main.exe`)
with two subcommands: `chat` and `agent`.

Two ideas carry the design; preserve both when changing code:

1. **Capability confinement.** Every tool closes over exactly one Eio
   capability (a directory handle, the net, the process manager). What a tool
   can reach is fixed by the *call site*, not by what the model asks for. A
   `read` tool holding `~dir:ws` cannot escape that subtree.
2. **One schema, two uses.** `Schema.t` is an applicative combinator that
   simultaneously produces the JSON Schema advertised to the model *and* the
   decoder for the arguments it sends back, so the two can never drift apart
   and handlers receive typed OCaml values.

Derived from Anil Madhavapeddy's
[`ocaml-deepseek`](https://tangled.org/anil.recoil.org/ocaml-deepseek), trimmed
to cloud backends only (no GGUF weights, no native inference code). ISC.

## Build, test, format

```sh
dune build            # build everything (also typechecks)
dune test             # run both test executables (no network needed)
dune fmt              # apply ocamlformat (profile=default, version 0.29.0)
dune build @doc       # odoc docs from the .mli comments
dune exec bin/main.exe -- --help
```

The only system dependency is OpenSSL (piaf's TLS). No C toolchain, no model
weights. Runtime deps: `eio`, `piaf`, `yojson`, `uri`, `cmdliner`, `fmt`;
OCaml >= 5.2.0, dune >= 3.0.

There is **no CI configuration** in this repo and no lint step beyond the
compiler itself. Run `dune build`, `dune test`, and `dune fmt` before
committing.

> The container an AI session runs in may not have an OCaml toolchain
> installed at all. Check with `which dune` first; if it is missing, say so
> plainly rather than claiming a change was verified to compile.

## Layout

```
lib/            the ocaml_ai_agent library (public name ocaml-ai-agent)
  schema.ml     typed argument combinator -> JSON Schema + decoder
  tool.ml       one tool: name, description, schema, handler
  toolbox.ml    the four ready-made capability-confined tools
  message.ml    provider-independent conversation type
  params.ml     temperature / max_tokens
  llm.ml        the backend signature (Llm.S) and event type
  retry.ml      exponential-backoff retry policy
  agent.ml      the agent loop over a pluggable backend
  anthropic.ml  Claude Messages API backend  (native format)
  openai.ml     Chat Completions backend     (OpenAI/DeepSeek/Kimi/...)
bin/main.ml     cmdliner CLI: `chat` and `agent` subcommands
test/           two standalone test executables (no test framework)
```

### Dependency direction

`Schema` -> `Tool` -> `Toolbox`, and `Message`/`Params`/`Tool` -> `Llm` ->
`{Anthropic, Openai}` -> `Agent`. `Retry` is used by the two backends only.
Nothing in `lib/` depends on `bin/`. Keep it acyclic; there is no module that
knows about more than one provider except `bin/main.ml`.

## Architecture

### The agent loop (`lib/agent.ml`)

`Agent.send` appends the user prompt, then repeats: call the backend for one
assistant message, append it, run every tool the model called, append each
result as `Message.Tool_result`, and go again. It stops when the model replies
with text alone, or when `max_turns` (default 50) backend calls are spent —
in which case it emits `Turn_limit` and returns with history intact, so the
*next* `send` resumes cleanly. That invariant (history is always consistent at
the point of stopping) is deliberate; don't break it by capping before tool
results are folded in.

The backend is held existentially (`type backend = Backend : (module Llm.S with
type t = 'e) * 'e -> backend`) so `Agent.t` is not parameterised by the engine.

Tool output larger than `max_tool_output` (default 30_000 bytes) is
middle-truncated by `Agent.truncate_middle` — head and tail kept around an
omission marker, cut on UTF-8 character boundaries, because command output puts
the error at the *end*.

### Backends (`Llm.S`)

A backend implements one function:

```ocaml
val converse :
  t -> system:string -> tools:Tool.t list -> messages:Message.t list ->
  params:Params.t -> on_event:(event -> unit) -> Message.t
```

It is synchronous (Eio, direct style — no Lwt, no async monad) and reports
progress through `on_event`: `Content`, `Reasoning`, `Tool_call`,
`Tool_result`, `Retry`, `Turn_limit`, `Done`. The `Agent` — not the backend —
runs tools and emits `Tool_result`.

Both existing backends have the same shape, and a new one should follow it:
`request_body` -> `send_request` (wrapped in `Retry.run`) -> either
`parse_response` (non-streaming) or an SSE `feed`/`process_line` loop that
reassembles `data:` lines across chunk boundaries. `stream` defaults to `true`.

**Retries cover the request and status line only.** Once the response body or
SSE stream starts being consumed, events have already been emitted downstream,
so a failure there raises rather than replaying. Keep that boundary.

`Retry.retryable_status` treats 408, 429, and all 5xx (including Anthropic's
529 "overloaded") as retryable; other 4xx are fatal and raise `Failure` at
once.

### Providers

`anthropic` uses `lib/anthropic.ml` (native Messages API: content blocks,
`tool_use`/`tool_result`, `x-api-key` header). Everything else —
`openai`, `deepseek`, `kimi` — shares `lib/openai.ml`, differing only in base
URL, API-key env var, and default model. Those three values live in
`provider_endpoint` / `default_model` / `provider_label` in `bin/main.ml`.

| Provider  | `-P` value  | API key env var     | Default model     |
| --------- | ----------- | ------------------- | ----------------- |
| Anthropic | `anthropic` | `ANTHROPIC_API_KEY` | `claude-opus-4-8` |
| OpenAI    | `openai`    | `OPENAI_API_KEY`    | `gpt-4o`          |
| DeepSeek  | `deepseek`  | `DEEPSEEK_API_KEY`  | `deepseek-chat`   |
| Kimi      | `kimi`      | `MOONSHOT_API_KEY`  | `moonshot-v1-8k`  |

API keys are read from the environment at `create` time (raising `Failure`
with a clear message if unset) and go **only** into the auth header. Never log
a key, never put one in an error message, and never add a CLI flag that takes
one on the command line.

## Conventions

**`.mli` for every module, and it is the documentation.** Each `lib/*.ml` has a
matching `lib/*.mli`. Public API docs are odoc comments in the `.mli`
(`(** ... *)`, cross-references as `{!Module.thing}`). Implementation notes are
plain `(* ... *)` comments, usually one block at the top of the `.ml`
explaining *why*. When you change behaviour, update the `.mli` doc comment in
the same edit — a stale `.mli` here is a real bug, since it is the only prose
describing the contract.

**Copyright headers.** Every source file opens with the ISC header block.
Files inherited from upstream `ocaml-deepseek` (`tool`, `toolbox`, `llm`,
`agent`, and `bin/main.ml`, both `.ml` and `.mli`) carry **two** copyright
lines — Anil Madhavapeddy's first, then kengirie's. Files original to this
repo (`schema`, `message`, `params`, `retry`, `anthropic`, `openai`, the
tests) carry only kengirie's. New files get the single-line form; copy an
existing header verbatim rather than retyping it.

**Formatting.** `.ocamlformat` pins `profile = default`, `version = 0.29.0`.
Run `dune fmt`; do not hand-format against it.

**Dune module lists are explicit.** `lib/dune` names every module in
`(modules ...)`. *A new `lib/*.ml` will not be compiled until you add it
there.* `test/dune` declares one `(test ...)` stanza per executable, each with
its own `(modules ...)` — a new test file needs a new stanza.
`dune-project` sets `implicit_transitive_deps false`, so every library you use
must be listed in that target's `(libraries ...)`, even if a dependency
already pulls it in.

**opam file is generated.** `ocaml-ai-agent.opam` is produced by
`generate_opam_files` — edit `dune-project` and rebuild; never edit the
`.opam` by hand.

**Style.** Direct-style Eio, no Lwt/Async. `Yojson.Safe` for all JSON, with
`Yojson.Safe.Util` opened locally inside parsing functions. Errors surface as
`Failure` with a prefixed, human-readable message (`"Anthropic: ..."`), caught
once in `bin/main.ml`'s `guard`. Tool handler failures are *not* fatal: a
decode error or an exception becomes an `"Error: ..."` string result that goes
back to the model, so a bad tool call costs a turn rather than the session.

**READMEs come in pairs.** `README.md` (English) and `README.ja.md` (Japanese)
mirror each other. If a change alters user-visible behaviour — a flag, a
provider, a default — update **both**.

## Common tasks

### Add a tool

Add it to `lib/toolbox.ml` (and `lib/toolbox.mli`) if it is a general-purpose
one, taking its capability as a labelled argument:

```ocaml
let mytool ~dir =
  let args =
    let open Schema in
    let+ path = string "path" ~description:"..."
    and+ n = int "count" ~description:"..." in
    (path, n)
  in
  Tool.v ~name:"mytool" ~description:"One line the model reads." args
    (fun (path, n) -> ...)
```

Rules: take the narrowest capability that does the job and never widen it
inside the handler; description strings are prompt text the model actually
reads, so write them for the model; the handler returns a plain `string` and
may raise (the failure is turned into `"Error: ..."` automatically). Then
register it in the tool list in `bin/main.ml`'s `agent` function and in the
`tools:` line the CLI prints.

`Schema` currently supports `string`, `int`, and `bool`, all required. Adding
optional fields or arrays means extending `lib/schema.ml` — keep the invariant
that `to_json_schema` and `decode` are built from the same value.

### Add a provider

If it speaks OpenAI Chat Completions, no new module is needed: add a variant
to the polymorphic provider type in `bin/main.ml` and an entry to
`provider_endpoint`, `default_model`, `provider_label`, and `provider_arg`'s
enum list. If it has its own wire format, add `lib/newprovider.{ml,mli}`
implementing `Llm.S` following the `anthropic.ml` shape, add it to `lib/dune`'s
`(modules ...)`, then wire it into `make_agent`. Update both READMEs' provider
tables either way.

### Testing

`test/test_schema.ml` covers the schema/decoder pair; `test/test_agent.ml`
covers `truncate_middle`, the turn cap, tool-result folding and truncation, and
the `Retry` policy. There is no test framework: a local `must name cond` helper
prints `ok`/`FAIL` and calls `exit 1`. Follow that style.

**Tests must not touch the network.** `test_agent.ml` drives the agent with a
scripted `Fake` backend (`respond : int -> Message.t` keyed on call number) and
`Retry.run` is tested with an injected `~sleep` that only records delays —
that is why `sleep` is a parameter. Test new backend logic by factoring the
pure parts (body construction, response parsing) out of the HTTP call.

## Gotchas

- **`max_tokens` defaults to 1024** (`Params.default`), which truncates long
  agent turns. Pass `-n` when a task needs more.
- **Temperature defaults to 1.0.** Only `temperature` is sent to Anthropic;
  `top_p` is deliberately omitted because recent Claude models deprecate it.
- **`Tool_result` messages are batched.** The Anthropic backend coalesces a
  run of consecutive `Message.Tool_result`s into one `user` message with
  multiple `tool_result` blocks; the OpenAI backend emits one `role:"tool"`
  message each. Preserve tool-call ids in both directions or the round trip
  breaks.
- **The `bash` tool is not sandboxed to `--dir`.** It holds the process
  manager and runs `bash -c` with the session's full privileges; only `read`
  and `write` are confined to the workspace directory. Be explicit about that
  when documenting or extending it.
- **Streaming SSE parsing is hand-rolled** in both backends (`feed` /
  `process_line`), including `\r` stripping, `data:`-prefix handling, blank-line
  dispatch, and a `leftover` buffer for chunk boundaries. The two copies are
  near-identical but not shared; if you fix a bug in one, check the other.
- **OpenAI streaming tool calls arrive in fragments** keyed by `index` and are
  flushed only after the stream ends (sorted by index), so `Llm.Tool_call`
  events fire later there than in the Anthropic backend, which fires them at
  `content_block_stop`.

## Git

Work on the branch you were assigned; commit with a descriptive message body
explaining *why*, in the style of the existing history (a summary line, then
bullet points). Do not open a pull request unless asked.
