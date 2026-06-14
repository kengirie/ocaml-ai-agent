# ocaml-ds4

A barebones OCaml binding to the [DS4](../ds4) inference engine, specialised for
the **Metal** backend on macOS. Vendors the core C/Objective-C engine, links it
into an OCaml library via a small FFI, and ships a `cmdliner` CLI (`ds4`) over
[Eio](https://github.com/ocaml-multicore/eio) with subcommands: `chat` (single
prompt/response), `download` (fetch GGUF models from Hugging Face), and `list`
(show known models and which are downloaded).

This is deliberately minimal: one prompt in, streamed tokens out. No server, no
KV-cache persistence, no agent loop.

## Layout

```
csrc/         Vendored DS4 core (Metal only), built into libds4_core.a
  ds4.c             engine, session, tokenizer, sampling, KV payload
  ds4_distributed.c distributed layer-slice routing (linked, unused here)
  ds4_ssd.c         SSD expert streaming
  ds4_metal.m       Metal compute backend (Objective-C, -fobjc-arc)
  ds4.h ds4_gpu.h ds4_ssd.h ds4_distributed.h ds4_streaming_hotlist.inc
  metal/*.metal     19 Metal kernel sources (embedded at build time)
gen/          gen_shaders.ml: embeds metal/*.metal into the generated Shaders
lib/          The `ds4` OCaml library
  ds4_stubs.c       OCaml 5 FFI to ds4.h (custom blocks + runtime-lock release)
  ds4.ml ds4.mli    typed API: create / generate
bin/          ds4_chat.ml: the cmdliner + Eio CLI (chat + download subcommands)
```

Only the four objects in `csrc/` are needed: they are the complete
implementation of the public `ds4.h` surface. The CLI/server/help/kvstore code
from the upstream tree are clients of that boundary, not part of it.

## How the pieces fit

- **Vendored C → static archive.** `csrc/dune` compiles each source with the
  upstream flags (`ds4_metal.m` as Objective-C) and `ar`s them into
  `libds4_core.a`. `lib/` copies that archive in and links it via
  `(foreign_archives ds4_core)`, with the Metal link deps in `c_library_flags`
  (`-lm -pthread -framework Foundation -framework Metal`).

- **Metal kernels are loaded at runtime.** The C backend reads each kernel from
  a file at engine-open time (honouring `DS4_METAL_<NAME>_SOURCE` overrides). To
  keep the binary relocatable, `gen_shaders.ml` embeds the 19 kernels into the
  `Shaders` module; at startup `Ds4.create` writes them under the XDG cache dir
  and sets the override env vars to point there.

- **FFI / GC safety.** `engine` and `session` are OCaml custom blocks with
  finalizers (`ds4_engine_close` / `ds4_session_free`). The long calls — model
  load, prefill (`session_sync`), decode (`session_eval`) — release the OCaml
  runtime lock so the GC keeps running while Metal works; inputs are copied to C
  memory first, results read back after re-acquiring.

- **Model directory.** `chat` resolves the model via, in order: `--model PATH`,
  `$DS4_MODEL`, then the first `*.gguf` in `$XDG_DATA_HOME/ds4` (via `nox-xdg`).
  `download` fetches into that same dir, so a freshly downloaded model is found
  with no flags. The Metal kernel cache lives under `$XDG_CACHE_HOME/ds4/metal`.

- **Download.** `download` shells out to `uvx hf download` via Eio's process
  manager (inheriting stdio, so Hugging Face's progress bar shows through),
  mirroring the targets of the upstream `download_model.sh`. Requires `uv` on
  PATH.

## Build & run

Requires OCaml 5, `dune`, `eio`/`eio_main`, `cmdliner`, `nox-xdg`, and the Xcode
Metal toolchain (macOS, Apple Silicon).

```sh
dune build

# See known models and which are downloaded:
dune exec bin/ds4_chat.exe -- list

# Download a model into ~/.local/share/ds4 (needs `uv`; alias 'q4' works too):
dune exec bin/ds4_chat.exe -- download q4-imatrix

# Chat against the downloaded model (auto-discovered, no flags):
dune exec bin/ds4_chat.exe -- chat "Explain monads in one sentence."

# Or select by target name/alias, or an explicit path:
dune exec bin/ds4_chat.exe -- chat -m q4 "Hello?"
dune exec bin/ds4_chat.exe -- chat -m /path/to/model.gguf "Hello?"
```

`chat` flags: `--model|-m` (a download target name/alias like `q4`, or a path
to a `.gguf`; default: first model found in the data dir), `--max-tokens N`,
`--temperature T`, `--system TEXT`, `--think none|high|max`, `--seed N`
(0 = per-run random).

`download` accepts a target by canonical name or alias (run `list`, or
`download --help`, for the full table with sizes):

| Target | Alias | | Target | Alias |
|---|---|---|---|---|
| `q2-imatrix` | `q2` | | `pro-q4-layers00-30` | `pro-q4-a` |
| `q2-q4-imatrix` | `q2q4` | | `pro-q4-layers31-output` | `pro-q4-b` |
| `q4-imatrix` | `q4` | | `pro-q4-split` | `pro-q4` |
| `pro-q2-imatrix` | `pro-q2` | | `mtp` | — |

Use `--token TOKEN` (or `HF_TOKEN`, or a prior `hf` login) for gated access.

## Limits / next steps

- Inference runs as a blocking FFI call on the main Eio fiber. Fine for one
  prompt; for concurrency, run it in a separate domain via `Eio.Domain_manager`.
- `ctx_size` defaults to 4096 and generation is clamped to the remaining
  context (mirroring the C CLI); there is no KV-cache reuse between turns, so a
  long prompt leaves little room to generate. Raise it in `Ds4.generate`.
- `--think max` is downgraded to `high` below the engine's minimum MAX context
  (384K), exactly as the C CLI does.
- Artifacts are built with `-mcpu=native` and are not portable across Apple
  Silicon generations (see `csrc/dune`).
- Metal/macOS only; the CUDA/ROCm backends are not vendored.
