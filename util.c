#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#define NEED_my_strlcpy
#include "ppport.h"

#include "util.h"

#include <grpc/byte_buffer_reader.h>
#include <string.h>

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

  SV* callback = (SV*)ptr;
  SV* err_tmp;
  int has_error = FALSE;
  char *error_details_out = NULL;
  grpc_metadata_array metadata;

  dSP;
  ENTER;

  HV* hash = newHV();
  hv_stores(hash,"service_url", newSVpv(context.service_url,0));
  hv_stores(hash,"method_name", newSVpv(context.method_name,0));

  SAVETMPS;
  PUSHMARK(sp);
  XPUSHs(sv_2mortal((SV*)newRV_noinc((SV*)hash)));
  PUTBACK;
  int count = perl_call_sv(callback, G_SCALAR|G_EVAL);
  SPAGAIN;

  err_tmp = ERRSV;
  if (SvTRUE(err_tmp)) {
    has_error = TRUE;
    my_strlcpy(error_details_buf, SvPV_nolen(err_tmp), sizeof(error_details_buf));
    error_details_out = error_details_buf;
    POPs;
  } else if (count!=1) {
    has_error = TRUE;
    error_details_out = "callback returned more/less than 1 value";
    POPs;
  } else {
    SV* retval = POPs;

    if (SvROK(retval)) {
      if (!create_metadata_array((HV*)SvRV(retval), &metadata)) {
        has_error = TRUE;
        error_details_out = "callback returned invalid metadata";
        grpc_metadata_array_destroy(&metadata);
      }
    } else {
      has_error = TRUE;
      error_details_out = "calback returned non-reference";
    }
  }

  PUTBACK;
  FREETMPS;
  LEAVE;

  if ( has_error ) {
    *status = GRPC_STATUS_INVALID_ARGUMENT;
    *error_details = error_details_out;
    *num_creds_md = 0;
  } else {
    size_t i;
    for (i = 0; i < metadata.count && i < GRPC_METADATA_CREDENTIALS_PLUGIN_SYNC_MAX; i++) {
      creds_md[i] = metadata.metadata[i];
    }
    *num_creds_md = metadata.count;
    *status = GRPC_STATUS_OK;
    *error_details = NULL;
  }

  (void)cb;
  (void)user_data;
  return 1;
}

void plugin_destroy_state(void *ptr) {
  SV *state = (SV *)ptr;
  SvREFCNT_dec(state);
}
