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

## Providers

Pick a provider with `-P` / `--provider`. Each reads its own API key from an
environment variable (sent only in the auth header, never logged):

| Provider    | `--provider` | API key env var      | Default model        |
| ----------- | ------------ | -------------------- | -------------------- |
| Anthropic   | `anthropic`  | `ANTHROPIC_API_KEY`  | `claude-opus-4-8`    |
| OpenAI      | `openai`     | `OPENAI_API_KEY`     | `gpt-4o`             |
| DeepSeek    | `deepseek`   | `DEEPSEEK_API_KEY`   | `deepseek-chat`      |
| Kimi        | `kimi`       | `MOONSHOT_API_KEY`   | `moonshot-v1-8k`     |

`anthropic` uses the native Claude Messages API; `openai` / `deepseek` / `kimi`
all speak the OpenAI-compatible Chat Completions format and share one backend,
so any other OpenAI-compatible endpoint works too — override the model with
`-m`. Streaming, tool use, and (where the provider returns it) reasoning are
handled the same way across all of them.

## Use

```sh
export ANTHROPIC_API_KEY=sk-ant-...     # or OPENAI_API_KEY / DEEPSEEK_API_KEY / MOONSHOT_API_KEY
```

```sh
# One-shot chat (streams token-by-token), default provider (anthropic):
dune exec bin/main.exe -- chat "Explain monads in one sentence."

# Other providers (each uses its own default model unless -m is given):
dune exec bin/main.exe -- chat -P openai "Hello?"
dune exec bin/main.exe -- chat -P deepseek -m deepseek-chat "Hello?"
dune exec bin/main.exe -- chat -P kimi "Hello?"

# Pick a model explicitly:
dune exec bin/main.exe -- chat -m claude-opus-4-8 "Hello?"

# Tool-using agent, sandboxed to a workspace, single prompt then exit:
dune exec bin/main.exe -- agent -P deepseek -d ./workspace -p "read README.md and summarise it"

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
- `Llm.S` — backend abstraction (`converse`); the point to add more providers.
- `Anthropic` — the Claude backend over piaf (non-streaming + SSE, tool_use).
- `Openai` — one OpenAI-compatible Chat Completions backend for OpenAI,
  DeepSeek, Kimi, and any other endpoint that speaks the same format.
- `Agent` — drives a backend, runs tools, folds results back in.

## Credits & license

Derived from [`ocaml-deepseek`](https://tangled.org/anil.recoil.org/ocaml-deepseek)
by Anil Madhavapeddy, from which most of the code is derived. The original
vendored DeepSeek-V4 (DS4) inference engine — not included here — is by
[antirez](https://github.com/antirez/ds4). ISC licensed, as upstream.
