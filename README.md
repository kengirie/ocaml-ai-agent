# ocaml-deepseek -- bindings to the Deepseek v4 open LLM

OCaml bindings and a command-line interface to the DS4 inference engine,
specialised for the Metal backend on macOS.

Requires OCaml 5, `dune`, `eio`, `cmdliner`, `nox-xdg`, and the Xcode
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
