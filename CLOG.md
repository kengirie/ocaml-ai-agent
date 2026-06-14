# CLOG — routing `csrc/` diagnostics through an interceptable callback

Goal: let the OCaml library (and its callers) intercept the textual diagnostics
the C core currently writes straight to `stderr`, so they can be captured,
redirected, structured, or colorized by the consumer instead of going to the
process's standard error. Genuine file output (`--dump-logits`, KV payloads,
expert-profile JSON, etc.) stays exactly as it is.

## Findings (investigation, 2026-06-14)

### What writes output

The split between "diagnostics" and "real files" is clean and mechanical: the
first argument is the crux.

| Sink | Count | What it is | Intercept? |
|---|---|---|---|
| `fprintf(stderr, …)` | ~864 | diagnostics, errors, progress, traces | **yes** |
| `printf(…)` (stdout) | 22 | `ds4_engine_summary` model-info dump | yes (stdout) |
| `fputs`/`fputc` → `stderr` | ~10 | color codes / log fragments | yes |
| `fprintf(fp, …)`, `fwrite`, `fputs(…, fp)` | ~30+ | real files opened via `fopen()`: `--dump-logits`/`--dump-logprobs` JSON, expert-profile JSON, token dumps, KV payloads | **no — leave alone** |

`fprintf(stderr, …)` per file: `ds4_metal.m` 497, `ds4.c` 318,
`ds4_distributed.c` 74, `ds4_ssd.c` 4.

**Heuristic for the migration:** intercept iff the first arg is the literal
`stderr` (or convert `printf(`/stdout). Anything passing a `FILE *fp` from
`fopen()` is real I/O and must not be touched. No real-file site uses `stderr`,
so a literal-`stderr` match has no false positives.

### Existing structure to build on

- `csrc/ds4.h:174-175` already exposes a logging seam:
  `ds4_log(FILE *fp, ds4_log_type type, const char *fmt, …)` with a
  `ds4_log_type` enum (`DEFAULT/PREFILL/GENERATION/KVCACHE/TOOL/WARNING/TIMING/OK/ERROR`).
  Implemented at `ds4.c:1222-1234` (`ds4_vlog`); colorizes via
  `ds4_log_is_tty(fp)` (`ds4.c:1217`). **Only 4 call sites** — 98% of output is
  raw `fprintf(stderr)` bypassing it.
- The public API already uses the callback pattern elsewhere:
  `ds4_token_emit_fn`, `ds4_generation_done_fn`, `ds4_session_progress_fn`,
  `ds4_session_cancel_fn` (`ds4.h:62-63,123-124`). Precedent + marshalling
  machinery in the stubs exists.
- Two debug macros wrap stderr: `DIST_DEBUG` (`ds4_distributed.c:1073`, ~42
  sites, compile-gated on `DS4_DIST_TRACE`) and `DIST_COORD_DEBUG`
  (`ds4_distributed.c:1843`, ~10 sites, runtime-gated on `state->debug`). Only
  their *definitions* need repointing, not their call sites.

### Threading (the decision that shaped the design)

Most diagnostics fire while the stub holds the work with the OCaml runtime lock
**released** (`ds4_stubs.c` calls `caml_release_runtime_system()` around
`engine_open` / `session_sync` / `eval`). A callback into OCaml from there must
re-acquire the lock.

Critically, **almost all** of these still run on the *calling* thread (the OCaml
thread that entered the stub). The only exception found:

- `ds4_gpu_stream_expert_pread_into` (`ds4_metal.m:7600`) logs on an I/O error
  path, and is reachable from the streaming-expert pread worker pools spawned
  with **raw `pthread_create`** (`ds4_metal.m:7714` and `:7863`). Those threads
  are *not* registered with the OCaml runtime.
- Metal uses only synchronous `[cb waitUntilCompleted]` (`:575,:1902,:6479`) —
  **no** `addCompletedHandler`/GCD async blocks — so there are no other
  off-thread logging contexts.
- The pool *init* / *spawn-loop* stderr sites (`:7719`, `:7868`) run on the
  spawning (calling) thread, not the workers.

**Conclusion:** exactly one reachable log line runs off the OCaml-registered
thread, and it is an error path. So we do **not** need a general thread-safe
async queue. We use a direct callback on the calling thread, and the
background-thread I/O-error site is a **settled exception: it goes straight to
`stderr`** (the consumer accepts that this one rare line is not captured). No
`caml_c_thread_register`/queue machinery needed.

## Design

### C core

1. Add a global sink in `ds4.c`:
   ```c
   typedef void (*ds4_log_fn)(void *ud, ds4_log_type type, const char *msg);
   void ds4_set_log_callback(ds4_log_fn fn, void *ud);   // NULL fn -> stderr fallback
   ```
   (declared in `ds4.h`). Store `fn`/`ud` in file-scope statics.

2. Add an internal formatter used by everything:
   ```c
   void ds4_logf(ds4_log_type type, const char *fmt, ...);   // + ds4_vlogf
   ```
   `vsnprintf` into a stack buffer (grow to heap if truncated); if a callback is
   registered, hand it the **uncolorized** string + `type`; otherwise fall back
   to today's behaviour (`fprintf(stderr, …)`, colorized when `stderr` is a tty).
   Colorization moves to the *consumer* — passing `type` (not a pre-colored
   string) is the contract, so OCaml decides.

3. Route the existing `ds4_log`/`ds4_vlog` (4 sites) through `ds4_vlogf`.

4. Repoint `DIST_DEBUG` and `DIST_COORD_DEBUG` macro *definitions* at `ds4_logf`
   (call sites unchanged).

5. Background-thread exception: leave `ds4_metal.m:7600` writing to `stderr`
   directly (comment it as deliberately not routed because it runs on an
   unregistered pthread). Optionally protect the sink statics with a mutex so a
   future off-thread caller can't race the pointer read; cheap, do it.

### Mechanical migration (~864 + 22 sites)

- `fprintf(stderr, FMT, …)` → `ds4_logf(DS4_LOG_DEFAULT, FMT, …)`.
- `printf(FMT, …)` (the `ds4_engine_summary` block) → `ds4_logf(DS4_LOG_DEFAULT, …)`.
- `fputs(s, stderr)` / `fputc(c, stderr)` fragments → fold into a `ds4_logf`.
- Do it with an automated transform + a manual review pass; **exclude**
  `fprintf(fp, …)`, `fwrite`, `vfprintf` (in `ds4_vlog`), and the one metal
  background site.
- Optional second pass: tag obvious `"ds4: … failed/error"` strings as
  `DS4_LOG_ERROR` / `DS4_LOG_WARNING` instead of `DEFAULT`.

### OCaml binding

- `lib/ds4_stubs.c`: a C trampoline registered via `ds4_set_log_callback`.
  Stores an OCaml closure as a GC root (`caml_register_global_root`). On
  callback: acquire the runtime lock if needed, `caml_callback2` the closure
  with `(type_as_variant_or_int, msg)`, release. Default = unset → C falls back
  to stderr, preserving current standalone behaviour.
- `lib/v4.ml{,i}`: expose `type log_type = …` mirroring `ds4_log_type`, and
  `val set_log_handler : (log_type -> string -> unit) -> unit`
  (plus `val clear_log_handler : unit -> unit`). Decide global vs per-session —
  global is simplest and matches the C global; revisit if the agent needs
  per-session routing.
- `lib/agent.ml`: optional convenience wiring so the agent can capture/redirect.

## Risks / open questions

- **Off-thread site:** *settled* — `ds4_metal.m:7600` stays on `stderr`. It runs
  on an unregistered worker pthread and is a rare I/O-failure line; the consumer
  is fine with it bypassing the handler. No thread-registration or queue needed.
- **Reentrancy:** a handler that itself logs (or raises) must not deadlock/loop.
  Guard with a per-thread "in callback" flag; on OCaml exception, fall back to
  stderr rather than propagating through C.
- **Buffering / line-boundaries:** some sites print partial lines (progress
  spinners, `fputc`). The callback gets whatever fragment was formatted; the
  consumer must tolerate non-line-delimited chunks, or we normalize to
  whole-message-per-call during migration.
- **stdout vs stderr semantics:** the 22 `printf` summary lines are user-facing
  *results*, not diagnostics. Confirm they should share the same handler or get
  a separate channel/`log_type`.

## Suggested order of work

1. Land the C sink + `ds4_logf` + reroute the 4 `ds4_log` sites and 2 debug
   macros. Build, no behaviour change (no callback registered).
2. Wire the OCaml trampoline + `V4.set_log_handler`; prove capture end-to-end on
   the already-routed sites.
3. Bulk-migrate the ~864 `fprintf(stderr)` + 22 `printf` sites (automated +
   review). Re-verify build and standalone stderr fallback.
4. Optional: log-type tagging pass; per-session handlers; off-thread capture.
