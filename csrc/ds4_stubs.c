/* =========================================================================
 * OCaml 5 FFI to the DS4 inference engine.
 *
 * Backend-agnostic: the backend (Metal/CUDA/CPU) is chosen at link time by
 * which engine archive this stub is bundled with, and passed in at open time as
 * a ds4_backend value (see caml_ds4_engine_open). One copy of this file is
 * compiled into each dune implementation library (lib_metal/, lib_cpu/).
 * ========================================================================= */

#include <stdlib.h>
#include <string.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/custom.h>
#include <caml/threads.h>

#include "ds4.h"

#define Engine_val(v) (*((ds4_engine **)Data_custom_val(v)))

static void finalize_engine(value v) {
    ds4_engine *e = Engine_val(v);
    if (e) {
        Engine_val(v) = NULL;
        ds4_engine_close(e);
    }
}

static struct custom_operations ds4_engine_ops = {
    "ds4.engine",
    finalize_engine,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default
};

typedef struct {
    ds4_session *s;
    uint64_t rng;
} ds4_session_box;

#define Session_box(v) (*((ds4_session_box **)Data_custom_val(v)))

static void finalize_session(value v) {
    ds4_session_box *box = Session_box(v);
    if (box) {
        Session_box(v) = NULL;
        if (box->s) ds4_session_free(box->s);
        free(box);
    }
}

static struct custom_operations ds4_session_ops = {
    "ds4.session",
    finalize_session,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default
};

CAMLprim value caml_ds4_engine_open(value v_backend, value v_model) {
    CAMLparam2(v_backend, v_model);
    CAMLlocal1(v_engine);

    /* Copy the path out before releasing the runtime lock; the GC may move the
     * OCaml string while we are blocked loading the model. */
    char *model_path = caml_stat_strdup(String_val(v_model));

    ds4_engine_options opt;
    memset(&opt, 0, sizeof(opt));
    opt.model_path = model_path;
    /* The id comes from the linked implementation's Backend.id and must match
     * the backend object compiled into this library's archive. */
    opt.backend = (ds4_backend)Int_val(v_backend);
    opt.mtp_draft_tokens = 1;
    opt.mtp_margin = 3.0f;

    ds4_engine *engine = NULL;
    caml_release_runtime_system();
    int rc = ds4_engine_open(&engine, &opt);
    caml_acquire_runtime_system();

    caml_stat_free(model_path);
    if (rc != 0 || engine == NULL)
        caml_failwith("ds4_engine_open failed");

    v_engine = caml_alloc_custom(&ds4_engine_ops, sizeof(ds4_engine *), 0, 1);
    Engine_val(v_engine) = engine;
    CAMLreturn(v_engine);
}

CAMLprim value caml_ds4_engine_model_name(value v_engine) {
    CAMLparam1(v_engine);
    const char *name = ds4_engine_model_name(Engine_val(v_engine));
    CAMLreturn(caml_copy_string(name ? name : ""));
}

CAMLprim value caml_ds4_engine_vocab_size(value v_engine) {
    CAMLparam1(v_engine);
    CAMLreturn(Val_int(ds4_engine_vocab_size(Engine_val(v_engine))));
}

CAMLprim value caml_ds4_token_eos(value v_engine) {
    CAMLparam1(v_engine);
    CAMLreturn(Val_int(ds4_token_eos(Engine_val(v_engine))));
}

/* Mirrors the CLI: MAX effort is downgraded to HIGH below the min context. */
CAMLprim value caml_ds4_think_mode_for_context(value v_mode, value v_ctx) {
    CAMLparam2(v_mode, v_ctx);
    ds4_think_mode m =
        ds4_think_mode_for_context((ds4_think_mode)Int_val(v_mode), Int_val(v_ctx));
    CAMLreturn(Val_int((int)m));
}

CAMLprim value caml_ds4_encode_chat_prompt(value v_engine, value v_system,
                                           value v_prompt, value v_think) {
    CAMLparam4(v_engine, v_system, v_prompt, v_think);
    CAMLlocal1(v_arr);

    ds4_tokens out;
    memset(&out, 0, sizeof(out));
    /* Tokenisation is fast and pure-CPU; keep the runtime lock. */
    ds4_encode_chat_prompt(Engine_val(v_engine),
                           String_val(v_system),
                           String_val(v_prompt),
                           (ds4_think_mode)Int_val(v_think),
                           &out);

    v_arr = caml_alloc(out.len, 0);
    for (int i = 0; i < out.len; i++)
        Field(v_arr, i) = Val_int(out.v[i]);
    ds4_tokens_free(&out);
    CAMLreturn(v_arr);
}

/* Tokenise an already-rendered prompt verbatim, WITHOUT re-applying the chat
 * template (unlike caml_ds4_encode_chat_prompt). The agent renders the whole
 * conversation with the Dsml library, so the template must not be applied a
 * second time here. */
CAMLprim value caml_ds4_tokenize_rendered_chat(value v_engine, value v_text) {
    CAMLparam2(v_engine, v_text);
    CAMLlocal1(v_arr);

    ds4_tokens out;
    memset(&out, 0, sizeof(out));
    ds4_tokenize_rendered_chat(Engine_val(v_engine), String_val(v_text), &out);

    v_arr = caml_alloc(out.len, 0);
    for (int i = 0; i < out.len; i++)
        Field(v_arr, i) = Val_int(out.v[i]);
    ds4_tokens_free(&out);
    CAMLreturn(v_arr);
}

CAMLprim value caml_ds4_session_create(value v_engine, value v_ctx,
                                       value v_seed) {
    CAMLparam3(v_engine, v_ctx, v_seed);
    CAMLlocal1(v_session);

    ds4_session *s = NULL;
    ds4_engine *e = Engine_val(v_engine);
    int ctx = Int_val(v_ctx);

    caml_release_runtime_system();
    int rc = ds4_session_create(&s, e, ctx);
    caml_acquire_runtime_system();

    if (rc != 0 || s == NULL)
        caml_failwith("ds4_session_create failed");

    ds4_session_box *box = malloc(sizeof(*box));
    if (!box) {
        ds4_session_free(s);
        caml_failwith("ds4_session_create: out of memory");
    }
    box->s = s;
    box->rng = (uint64_t)Int64_val(v_seed);

    v_session = caml_alloc_custom(&ds4_session_ops, sizeof(ds4_session_box *), 0, 1);
    Session_box(v_session) = box;
    CAMLreturn(v_session);
}

CAMLprim value caml_ds4_session_sync(value v_session, value v_tokens) {
    CAMLparam2(v_session, v_tokens);

    ds4_session_box *box = Session_box(v_session);
    int n = Wosize_val(v_tokens);

    /* Copy tokens into a C buffer before releasing the lock. */
    ds4_tokens prompt;
    memset(&prompt, 0, sizeof(prompt));
    for (int i = 0; i < n; i++)
        ds4_tokens_push(&prompt, Int_val(Field(v_tokens, i)));

    char err[256] = {0};
    caml_release_runtime_system();
    int rc = ds4_session_sync(box->s, &prompt, err, sizeof(err));
    caml_acquire_runtime_system();

    ds4_tokens_free(&prompt);
    if (rc != 0)
        caml_failwith(err[0] ? err : "ds4_session_sync failed");
    CAMLreturn(Val_unit);
}

CAMLprim value caml_ds4_session_ctx(value v_session) {
    CAMLparam1(v_session);
    CAMLreturn(Val_int(ds4_session_ctx(Session_box(v_session)->s)));
}

CAMLprim value caml_ds4_session_pos(value v_session) {
    CAMLparam1(v_session);
    CAMLreturn(Val_int(ds4_session_pos(Session_box(v_session)->s)));
}

CAMLprim value caml_ds4_session_sample(value v_session, value v_temp,
                                       value v_top_p, value v_min_p) {
    CAMLparam4(v_session, v_temp, v_top_p, v_min_p);
    ds4_session_box *box = Session_box(v_session);
    int tok = ds4_session_sample(box->s,
                                 (float)Double_val(v_temp),
                                 0, /* top_k */
                                 (float)Double_val(v_top_p),
                                 (float)Double_val(v_min_p),
                                 &box->rng);
    CAMLreturn(Val_int(tok));
}

CAMLprim value caml_ds4_session_eval(value v_session, value v_token) {
    CAMLparam2(v_session, v_token);
    ds4_session_box *box = Session_box(v_session);
    int token = Int_val(v_token);

    char err[256] = {0};
    caml_release_runtime_system();
    int rc = ds4_session_eval(box->s, token, err, sizeof(err));
    caml_acquire_runtime_system();

    if (rc != 0)
        caml_failwith(err[0] ? err : "ds4_session_eval failed");
    CAMLreturn(Val_unit);
}

CAMLprim value caml_ds4_token_text(value v_engine, value v_token) {
    CAMLparam2(v_engine, v_token);
    CAMLlocal1(v_str);
    size_t len = 0;
    char *piece = ds4_token_text(Engine_val(v_engine), Int_val(v_token), &len);
    v_str = caml_alloc_initialized_string(len, piece);
    free(piece); /* ds4_token_text returns malloc'd memory the caller owns */
    CAMLreturn(v_str);
}
