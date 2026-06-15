# ocaml-deepseek -- bindings to the Deepseek v4 open LLM

OCaml bindings and a command-line interface to the [DS4 inference
engine](https://github.com/antirez/ds4), specialised for the Metal backend on
macOS.

Requires OCaml 5, and (for the GPU backend) the Xcode Metal toolchain (macOS,
Apple Silicon). Downloading models needs either
[`uv`](https://github.com/astral-sh/uv) or `hf` on your `PATH` as the
`download` command shells out to fetch GGUF weights from Hugging Face.

## humpty

Everything ships as the `humpty` command (the name is a camel-hump pun on
DeepSeek), built in a GPU (Metal) and a CPU variant:

| Command        | Backend     | Notes                       |
| -------------- | ----------- | --------------------------- |
| `humpty-metal` | GPU (Metal) | macOS / Apple Silicon only  |
| `humpty-cpu`   | CPU         | portable, builds everywhere |

The GPU variant is only built on macOS; the CPU variant is built from the same
source on every platform. Swap `humpty-metal` for `humpty-cpu` in any command
below to run on the CPU backend.

Its subcommands are a guided tour of how a language-model agent is assembled,
meant to be run in order — `list` the models to pick one, `download` it, `chat`
with it, then turn that same model into an `agent`. Run `humpty-metal --help` (or
`humpty-metal <subcommand> --help`) for the full explanation.

## Usage

```sh
dune build

# See the known models and which are already downloaded:
dune exec -- humpty-metal list

# Download a model into ~/.local/share/ds4 (alias 'q4' works too):
dune exec -- humpty-metal download q4-imatrix

# Chat against the downloaded model (auto-discovered, no flags):
dune exec -- humpty-metal chat "Explain monads in one sentence."

# Or select by target name/alias, or an explicit path:
dune exec -- humpty-metal chat -m q4 "Hello?"
dune exec -- humpty-metal chat -m /path/to/model.gguf "Hello?"

# Run the interactive agent, sandboxed to a workspace directory:
dune exec -- humpty-metal agent -d ./workspace

# Same on the CPU backend (no Metal needed):
dune exec -- humpty-cpu chat "Explain monads in one sentence."
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
