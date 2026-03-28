#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#define NEED_my_strlcpy
#include "ppport.h"

#include "util.h"

#include <grpc/byte_buffer_reader.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

bool module_initialized = false;
grpc_completion_queue *completion_queue;

grpc_byte_buffer *string_to_byte_buffer(char *string, size_t length) {
  grpc_slice slice = grpc_slice_from_copied_buffer(string, length);
  grpc_byte_buffer *buffer = grpc_raw_byte_buffer_create(&slice, 1);
  grpc_slice_unref(slice);
  return buffer;
}

void byte_buffer_to_string(grpc_byte_buffer *buffer, char **out_string,
                           size_t *out_length) {
  if (buffer == NULL) {
    *out_string = NULL;
    *out_length = 0;
    return;
  }
  size_t length = grpc_byte_buffer_length(buffer);
  char *string = calloc(length + 1, sizeof(char));
  size_t offset = 0;
  grpc_byte_buffer_reader reader;
  grpc_byte_buffer_reader_init(&reader, buffer);
  grpc_slice next;
  while (grpc_byte_buffer_reader_next(&reader, &next) != 0) {
    memcpy(string + offset, GRPC_SLICE_START_PTR(next), GRPC_SLICE_LENGTH(next));
    offset += GRPC_SLICE_LENGTH(next);
    grpc_slice_unref(next);
  }
  *out_string = string;
  *out_length = length;
}

void grpc_perl_init() {
  if (module_initialized) {
    return;
  }
  module_initialized = true;
  grpc_init();
  grpc_perl_init_completion_queue();
}

void grpc_perl_destroy() {
  if (!module_initialized) {
    return;
  }
  grpc_perl_shutdown_completion_queue();
#if defined(GRPC_PERL_HAS_SHUTDOWN_BLOCKING)
  grpc_shutdown_blocking();
#else
  grpc_shutdown();
#endif
  module_initialized = false;
}

void grpc_perl_init_completion_queue() {
#if defined(GRPC_PERL_HAS_CQ_CREATE_FOR_PLUCK)
  completion_queue = grpc_completion_queue_create_for_pluck(NULL);
#else
  grpc_completion_queue_attributes attr;
  attr.version = 1;
  attr.cq_completion_type = GRPC_CQ_PLUCK;
  attr.cq_polling_type = GRPC_CQ_DEFAULT_POLLING;
  completion_queue = grpc_completion_queue_create(
      grpc_completion_queue_factory_lookup(&attr), &attr, NULL);
#endif
}

void grpc_perl_shutdown_completion_queue() {
  grpc_completion_queue_shutdown(completion_queue);
  while (grpc_completion_queue_pluck(completion_queue, NULL,
                                     gpr_inf_future(GPR_CLOCK_REALTIME),
                                     NULL).type != GRPC_QUEUE_SHUTDOWN);
  grpc_completion_queue_destroy(completion_queue);
  completion_queue = NULL;
}

void perl_grpc_read_args_array(HV *hash, grpc_channel_args *args) {
  if (SvTYPE(hash)!=SVt_PVHV) {
    croak("Expected hash for perl_grpc_read_args_array() args");
  }

  char* key;
  I32 keylen;
  SV* value;

  args->num_args = 0;
  hv_iterinit(hash);
  while((value = hv_iternextsv(hash,&key,&keylen))!=NULL) {
    args->num_args += 1;
  }

  args->args = calloc(args->num_args, sizeof(grpc_arg));

  int args_index = 0;
  hv_iterinit(hash);
  while((value = hv_iternextsv(hash,&key,&keylen))!=NULL) {
    if (SvOK(value)) {
      args->args[args_index].key = key;
      if (SvIOK(value)) {
        args->args[args_index].type = GRPC_ARG_INTEGER;
        args->args[args_index].value.integer = SvIV(value);
        args->args[args_index].value.string = NULL;
      } else {
        args->args[args_index].type = GRPC_ARG_STRING;
        args->args[args_index].value.string = SvPV_nolen(value);
      }
    } else {
      croak("args values must be int or string");
    }
    args_index++;
  }
}

HV* grpc_parse_metadata_array(grpc_metadata_array *metadata_array) {
  HV* hash = newHV();
  grpc_metadata *elements = metadata_array->metadata;
  grpc_metadata *elem;

  int i;
  int count = metadata_array->count;
  SV *inner_value;
  SV *key;
  HE *temp_fetch;

  for (i = 0; i < count; i++) {
    elem = &elements[i];
    key = sv_2mortal(grpc_perl_sv_from_slice(elem->key));
    temp_fetch = hv_fetch_ent(hash, key, 0, 0);
    inner_value = temp_fetch ? HeVAL(temp_fetch) : NULL;
    if (inner_value) {
      if(!SvROK(inner_value)) {
        croak("Metadata hash somehow contains wrong types.");
        return NULL;
      }
      av_push((AV*)SvRV(inner_value), grpc_slice_or_buffer_length_to_sv(elem->value));
    } else {
      AV* av = newAV();
      av_push(av, grpc_slice_or_buffer_length_to_sv(elem->value));
      hv_store_ent(hash, key, newRV_inc((SV*)av), 0);
    }
  }

  return hash;
}

bool create_metadata_array(HV *hash, grpc_metadata_array *metadata) {
  grpc_metadata_array_init(metadata);
  metadata->capacity = 0;
  metadata->metadata = NULL;

  if (SvTYPE(hash)!=SVt_PVHV) {
    warn("Expected hash for create_metadata_array() args");
    return FALSE;
  }

  int i;
  char* key;
  I32 keylen;
  SV* value;

  metadata->capacity = 0;
  hv_iterinit(hash);
  while((value = hv_iternextsv(hash,&key,&keylen))!=NULL) {
    if (!SvROK(value)) {
      warn("expected array ref in metadata value %s, ignoring...",key);
      continue;
    }
    value = SvRV(value);
    if (SvTYPE(value)!=SVt_PVAV) {
      warn("expected array ref in metadata value %s, ignoring...",key);
      continue;
    }
    metadata->capacity += av_len((AV*)value)+1;
  }

  if(metadata->capacity > 0) {
    metadata->metadata = gpr_malloc(metadata->capacity * sizeof(grpc_metadata));
  } else {
    metadata->metadata = NULL;
    return TRUE;
  }

  metadata->count = 0;
  hv_iterinit(hash);
  while((value = hv_iternextsv(hash,&key,&keylen))!=NULL) {
    if (!SvROK(value)) {
      continue;
    }
    value = SvRV(value);
    if (SvTYPE(value)!=SVt_PVAV) {
      continue;
    }
    for(i=0;i<av_len((AV*)value)+1;i++) {
      SV** inner_value = av_fetch((AV*)value,i,1);
      if (SvOK(*inner_value)) {
        metadata->metadata[metadata->count].key = grpc_perl_slice_from_cstring(key);
        metadata->metadata[metadata->count].value = grpc_perl_slice_from_sv(*inner_value);
        metadata->count += 1;
      } else {
        warn("args values must be int or string");
        return FALSE;
      }
    }
  }

  return TRUE;
}

int plugin_get_metadata(void *ptr, grpc_auth_metadata_context context,
                        grpc_credentials_plugin_metadata_cb cb,
                        void *user_data,
                        grpc_metadata creds_md[GRPC_METADATA_CREDENTIALS_PLUGIN_SYNC_MAX],
                        size_t *num_creds_md, grpc_status_code *status,
                        const char **error_details) {
  static char error_details_buf[1024];

  SV *callback_ref = (SV *)ptr;
  SV *callback = NULL;
  SV *err_tmp = NULL;
  int has_error = FALSE;
  char *error_details_out = NULL;
  grpc_metadata_array metadata;

  int trace =
    (getenv("GRPC_PERL_DEBUG_PLUGIN") != NULL) ||
    (getenv("GRPC_PERL_DEBUG_SERVER") != NULL);

#define PLUGIN_TRACE0(step)                                                   \
  do {                                                                        \
    if (trace) {                                                              \
      fprintf(stderr, "[grpc-perl][plugin][trace] %s\n", (step));             \
      fflush(stderr);                                                         \
    }                                                                         \
  } while (0)

#define PLUGIN_TRACE(fmt, ...)                                                \
  do {                                                                        \
    if (trace) {                                                              \
      fprintf(stderr, "[grpc-perl][plugin][trace] " fmt "\n", ##__VA_ARGS__); \
      fflush(stderr);                                                         \
    }                                                                         \
  } while (0)

  grpc_metadata_array_init(&metadata);

  grpc_perl_debugf_plugin(
      "get_metadata",
      "enter ptr=%p service_url=%s method_name=%s",
      ptr,
      context.service_url ? context.service_url : "(null)",
      context.method_name ? context.method_name : "(null)"
  );

  /*
   * Временный режим полной изоляции от Perl API.
   * Запускать так:
   *   GRPC_PERL_PLUGIN_STATIC_OK=1 GRPC_PERL_DEBUG_SERVER=1 TEST_VERBOSE=1 make test TEST_FILES=t/01-call_credentials.t
   *   GRPC_PERL_PLUGIN_STATIC_OK=1 GRPC_PERL_DEBUG_SERVER=1 TEST_VERBOSE=1 make test TEST_FILES=t/16-xs_secure_end_to_end.t
   */
  if (getenv("GRPC_PERL_PLUGIN_STATIC_OK") != NULL) {
    PLUGIN_TRACE0("static_ok branch entered");

    creds_md[0].key   = grpc_perl_slice_from_cstring("x-grpc-perl-debug");
    creds_md[0].value = grpc_perl_slice_from_cstring("static-ok");

    *num_creds_md = 1;
    *status = GRPC_STATUS_OK;
    *error_details = NULL;

    grpc_perl_debugf_plugin("get_metadata", "static_ok success num_creds_md=1");

    (void)cb;
    (void)user_data;
    return 1;
  }

  if (callback_ref == NULL) {
    has_error = TRUE;
    error_details_out = "plugin state is NULL";
    goto finalize;
  }

  PLUGIN_TRACE("after callback_ref null-check ptr=%p", (void *)callback_ref);

  if (!SvROK(callback_ref)) {
    has_error = TRUE;
    error_details_out = "plugin state is not a reference";
    goto finalize;
  }

  PLUGIN_TRACE("after SvROK callback_ref=%p rv=%p",
               (void *)callback_ref, (void *)SvRV(callback_ref));

  if (SvTYPE(SvRV(callback_ref)) != SVt_PVCV) {
    has_error = TRUE;
    error_details_out = "plugin state does not contain a code reference";
    goto finalize;
  }

  callback = SvRV(callback_ref);

  grpc_perl_debugf_plugin(
      "get_metadata",
      "callback_ref=%p callback_cv=%p",
      (void *)callback_ref,
      (void *)callback
  );

  PLUGIN_TRACE0("before dSP");
  dSP;
  PLUGIN_TRACE0("after dSP");

  PLUGIN_TRACE0("before ENTER");
  ENTER;
  PLUGIN_TRACE0("after ENTER");

  PLUGIN_TRACE0("before newHV");
  HV *hash = newHV();
  PLUGIN_TRACE("after newHV hash=%p", (void *)hash);

  PLUGIN_TRACE0("before hv_stores service_url");
  hv_stores(hash, "service_url",
            newSVpv(context.service_url ? context.service_url : "", 0));
  PLUGIN_TRACE0("after hv_stores service_url");

  PLUGIN_TRACE0("before hv_stores method_name");
  hv_stores(hash, "method_name",
            newSVpv(context.method_name ? context.method_name : "", 0));
  PLUGIN_TRACE0("after hv_stores method_name");

  PLUGIN_TRACE0("before SAVETMPS");
  SAVETMPS;
  PLUGIN_TRACE0("after SAVETMPS");

  PLUGIN_TRACE0("before PUSHMARK");
  PUSHMARK(sp);
  PLUGIN_TRACE0("after PUSHMARK");

  PLUGIN_TRACE0("before newRV_noinc");
  SV *hash_ref = newRV_noinc((SV *)hash);
  PLUGIN_TRACE("after newRV_noinc hash_ref=%p", (void *)hash_ref);

  PLUGIN_TRACE0("before XPUSHs");
  XPUSHs(sv_2mortal(hash_ref));
  PLUGIN_TRACE0("after XPUSHs");

  PLUGIN_TRACE0("before PUTBACK");
  PUTBACK;
  PLUGIN_TRACE0("after PUTBACK");

  grpc_perl_debugf_plugin("get_metadata", "before perl_call_sv callback=%p", (void *)callback);
  PLUGIN_TRACE("before perl_call_sv callback=%p", (void *)callback);

  int count = perl_call_sv(callback, G_SCALAR | G_EVAL);

  PLUGIN_TRACE("after perl_call_sv count=%d", count);
  grpc_perl_debugf_plugin("get_metadata", "after perl_call_sv count=%d", count);

  SPAGAIN;
  PLUGIN_TRACE0("after SPAGAIN");

  err_tmp = ERRSV;
  PLUGIN_TRACE("after ERRSV err_tmp=%p svtrue=%d",
               (void *)err_tmp, err_tmp ? (int)SvTRUE(err_tmp) : -1);

  if (SvTRUE(err_tmp)) {
    has_error = TRUE;
    my_strlcpy(error_details_buf, SvPV_nolen(err_tmp), sizeof(error_details_buf));
    error_details_out = error_details_buf;
    if (count > 0) {
      PLUGIN_TRACE0("before POPs on error");
      POPs;
      PLUGIN_TRACE0("after POPs on error");
    }
  }
  else if (count != 1) {
    has_error = TRUE;
    error_details_out = "callback returned more/less than 1 value";
    if (count > 0) {
      PLUGIN_TRACE0("before POPs on bad count");
      POPs;
      PLUGIN_TRACE0("after POPs on bad count");
    }
  }
  else {
    PLUGIN_TRACE0("before POPs retval");
    SV *retval = POPs;
    PLUGIN_TRACE("after POPs retval=%p rok=%d type=%d",
                 (void *)retval,
                 (int)SvROK(retval),
                 (int)SvTYPE(retval));

    grpc_perl_debugf_plugin(
        "get_metadata",
        "retval=%p rok=%d type=%d",
        (void *)retval,
        (int)SvROK(retval),
        (int)SvTYPE(retval)
    );

    if (SvROK(retval) && SvTYPE(SvRV(retval)) == SVt_PVHV) {
      PLUGIN_TRACE("before create_metadata_array hv=%p", (void *)SvRV(retval));

      if (!create_metadata_array((HV *)SvRV(retval), &metadata)) {
        has_error = TRUE;
        error_details_out = "callback returned invalid metadata";
        grpc_metadata_array_destroy(&metadata);
        grpc_metadata_array_init(&metadata);
      } else {
        PLUGIN_TRACE("after create_metadata_array count=%lu", (unsigned long)metadata.count);
        grpc_perl_debugf_plugin("get_metadata", "metadata.count=%lu",
                                (unsigned long)metadata.count);
      }
    }
    else {
      has_error = TRUE;
      error_details_out = "callback returned non-hash-reference";
    }
  }

  PLUGIN_TRACE0("before PUTBACK cleanup");
  PUTBACK;
  PLUGIN_TRACE0("after PUTBACK cleanup");

  PLUGIN_TRACE0("before FREETMPS");
  FREETMPS;
  PLUGIN_TRACE0("after FREETMPS");

  PLUGIN_TRACE0("before LEAVE");
  LEAVE;
  PLUGIN_TRACE0("after LEAVE");

finalize:
  if (has_error) {
    grpc_perl_debugf_plugin("get_metadata", "error=%s",
                            error_details_out ? error_details_out : "(null)");
    PLUGIN_TRACE("finalize error=%s",
                 error_details_out ? error_details_out : "(null)");
    *status = GRPC_STATUS_INVALID_ARGUMENT;
    *error_details = error_details_out;
    *num_creds_md = 0;
  }
  else {
    size_t i;
    for (i = 0; i < metadata.count && i < GRPC_METADATA_CREDENTIALS_PLUGIN_SYNC_MAX; i++) {
      creds_md[i] = metadata.metadata[i];
    }
    *num_creds_md = metadata.count;
    *status = GRPC_STATUS_OK;
    *error_details = NULL;
    grpc_perl_debugf_plugin("get_metadata", "success num_creds_md=%lu",
                            (unsigned long)*num_creds_md);
    PLUGIN_TRACE("finalize success num_creds_md=%lu",
                 (unsigned long)*num_creds_md);
  }

  (void)cb;
  (void)user_data;
  return 1;

#undef PLUGIN_TRACE
#undef PLUGIN_TRACE0
}

void plugin_destroy_state(void *ptr) {
  SV *state = (SV *)ptr;
  grpc_perl_debugf_plugin("destroy_state", "state=%p", ptr);
  if (state != NULL) {
    SvREFCNT_dec(state);
  }
}
