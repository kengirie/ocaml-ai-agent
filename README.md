# ocaml-ai-agent — capability-confined tools for LLM agents in OCaml

> **Derived from Anil Madhavapeddy's [`ocaml-deepseek`](https://tangled.org/anil.recoil.org/ocaml-deepseek).**
> The agent loop, the capability-confined tool layer (`Tool` / `Toolbox`), the
> typed argument codec, and the conversation model all follow it closely. This
> repository trims that codebase down to a **cloud-only** reimplementation: no
> DeepSeek engine, no GGUF weights, no native code. It drives the Anthropic
> Claude API over Eio + piaf instead of a local model.
> Unofficial — not affiliated with or endorsed by the upstream authors.
> ISC, as upstream.

🇯🇵 日本語版は [README.ja.md](./README.ja.md) にあります。

A small, cloud-only tool-using agent for the [Anthropic Claude Messages
API](https://docs.anthropic.com/en/api/messages), written in OCaml on
[Eio](https://github.com/ocaml-multicore/eio) and [piaf](https://github.com/anmonteiro/piaf).

Its point is the **tools**: every tool is confined by an Eio capability, so it
can reach only what the caller hands it — not what the model asks for. A `read`
tool holds one directory handle and cannot escape that subtree; `dns` holds the
network; `bash` holds the process manager. Tool arguments are described by a
typed `Schema` combinator that yields both the JSON Schema advertised to the
model and a decoder, so the handler receives typed OCaml values.

## Build

```sh
dune build
```

Pure OCaml; the only system dependency is OpenSSL (via piaf's TLS). No model
weights and no C toolchain.

## Use

Set your API key (sent only in the `x-api-key` header, never logged):

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

```sh
# One-shot chat (streams token-by-token):
dune exec bin/main.exe -- chat "Explain monads in one sentence."

# Pick a model (default: claude-opus-4-8):
dune exec bin/main.exe -- chat -m claude-opus-4-8 "Hello?"

# Tool-using agent, sandboxed to a workspace, single prompt then exit:
dune exec bin/main.exe -- agent -d ./workspace -p "read README.md and summarise it"

# Interactive agent (Ctrl-D to exit):
dune exec bin/main.exe -- agent -d ./workspace

# Disable streaming (one response per turn):
dune exec bin/main.exe -- chat --no-stream "hello"
```

The agent advertises `read` / `write` / `dns` / `bash`, each confined to the
`--dir` workspace (filesystem tools) or its granted capability.

## Architecture

- `Schema` — typed argument combinator: one description yields the JSON Schema
  and the decoder.
- `Tool` / `Toolbox` — capability-confined tools built from a `Schema`.
- `Message` — provider-independent conversation (keeps tool-call ids).
- `Llm.S` — backend abstraction (`converse`); the point to add OpenAI/Gemini.
- `Anthropic` — the Claude backend over piaf (non-streaming + SSE, tool_use).
- `Agent` — drives a backend, runs tools, folds results back in.

## Credits & license

Derived from [`ocaml-deepseek`](https://tangled.org/anil.recoil.org/ocaml-deepseek)
by Anil Madhavapeddy, from which most of the code is derived. The original
vendored DeepSeek-V4 (DS4) inference engine — not included here — is by
[antirez](https://github.com/antirez/ds4). ISC licensed, as upstream.
