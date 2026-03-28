#ifndef GRPC_PERL_COMPAT_H
#define GRPC_PERL_COMPAT_H

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <grpc/grpc.h>
#include <grpc/credentials.h>
#include <grpc/grpc_security.h>
#include <grpc/slice.h>
#include <grpc/support/alloc.h>

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

static inline int
grpc_perl_debug_enabled(void) {
    const char *v = getenv("GRPC_PERL_DEBUG_SERVER");
    return v && *v;
}

static inline void
grpc_perl_debugf_component(const char *component, const char *where, const char *fmt, ...) {
    va_list ap;
    if (!grpc_perl_debug_enabled()) return;

    fprintf(stderr, "[grpc-perl][%s][%s] ", component, where);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    fflush(stderr);
}

#define grpc_perl_debugf(where, fmt, ...) \
    grpc_perl_debugf_component("server", (where), (fmt), ##__VA_ARGS__)
#define grpc_perl_debugf_call(where, fmt, ...) \
    grpc_perl_debugf_component("call", (where), (fmt), ##__VA_ARGS__)
#define grpc_perl_debugf_server_credentials(where, fmt, ...) \
    grpc_perl_debugf_component("server_credentials", (where), (fmt), ##__VA_ARGS__)
#define grpc_perl_debugf_plugin(where, fmt, ...) \
    grpc_perl_debugf_component("plugin", (where), (fmt), ##__VA_ARGS__)

static inline const char *
grpc_perl_op_name(grpc_op_type op) {
    switch (op) {
        case GRPC_OP_SEND_INITIAL_METADATA: return "SEND_INITIAL_METADATA";
        case GRPC_OP_SEND_MESSAGE: return "SEND_MESSAGE";
        case GRPC_OP_SEND_CLOSE_FROM_CLIENT: return "SEND_CLOSE_FROM_CLIENT";
        case GRPC_OP_SEND_STATUS_FROM_SERVER: return "SEND_STATUS_FROM_SERVER";
        case GRPC_OP_RECV_INITIAL_METADATA: return "RECV_INITIAL_METADATA";
        case GRPC_OP_RECV_MESSAGE: return "RECV_MESSAGE";
        case GRPC_OP_RECV_STATUS_ON_CLIENT: return "RECV_STATUS_ON_CLIENT";
        case GRPC_OP_RECV_CLOSE_ON_SERVER: return "RECV_CLOSE_ON_SERVER";
        default: return "UNKNOWN_OP";
    }
}

static inline const char *
grpc_perl_call_error_name(grpc_call_error err) {
    switch (err) {
        case GRPC_CALL_OK: return "GRPC_CALL_OK";
        case GRPC_CALL_ERROR: return "GRPC_CALL_ERROR";
        case GRPC_CALL_ERROR_NOT_ON_SERVER: return "GRPC_CALL_ERROR_NOT_ON_SERVER";
        case GRPC_CALL_ERROR_NOT_ON_CLIENT: return "GRPC_CALL_ERROR_NOT_ON_CLIENT";
        case GRPC_CALL_ERROR_ALREADY_ACCEPTED: return "GRPC_CALL_ERROR_ALREADY_ACCEPTED";
        case GRPC_CALL_ERROR_ALREADY_INVOKED: return "GRPC_CALL_ERROR_ALREADY_INVOKED";
        case GRPC_CALL_ERROR_NOT_INVOKED: return "GRPC_CALL_ERROR_NOT_INVOKED";
        case GRPC_CALL_ERROR_ALREADY_FINISHED: return "GRPC_CALL_ERROR_ALREADY_FINISHED";
        case GRPC_CALL_ERROR_TOO_MANY_OPERATIONS: return "GRPC_CALL_ERROR_TOO_MANY_OPERATIONS";
        case GRPC_CALL_ERROR_INVALID_FLAGS: return "GRPC_CALL_ERROR_INVALID_FLAGS";
        case GRPC_CALL_ERROR_INVALID_METADATA: return "GRPC_CALL_ERROR_INVALID_METADATA";
        default: return "GRPC_CALL_ERROR_UNKNOWN";
    }
}

static inline const char *
grpc_perl_event_type_name(grpc_completion_type type) {
    switch (type) {
        case GRPC_QUEUE_SHUTDOWN: return "GRPC_QUEUE_SHUTDOWN";
        case GRPC_QUEUE_TIMEOUT: return "GRPC_QUEUE_TIMEOUT";
        case GRPC_OP_COMPLETE: return "GRPC_OP_COMPLETE";
        default: return "GRPC_QUEUE_UNKNOWN";
    }
}

static inline void
grpc_perl_debug_batch(const char *component, const char *where, grpc_op *ops, size_t op_num) {
    size_t i;
    if (!grpc_perl_debug_enabled()) return;

    for (i = 0; i < op_num; i++) {
        grpc_perl_debugf_component(
            component,
            where,
            "op[%lu]=%s flags=%u",
            (unsigned long)i,
            grpc_perl_op_name(ops[i].op),
            (unsigned)ops[i].flags
        );
    }
}

static inline gpr_timespec
grpc_perl_deadline_seconds(int seconds) {
    return gpr_time_add(
        gpr_now(GPR_CLOCK_REALTIME),
        gpr_time_from_seconds(seconds, GPR_TIMESPAN)
    );
}

static inline grpc_slice
grpc_perl_slice_from_buffer(const char *buffer, STRLEN length) {
    return grpc_slice_from_copied_buffer(buffer, length);
}

static inline grpc_slice
grpc_perl_slice_from_cstring(const char *string) {
    if (string == NULL) {
        return grpc_empty_slice();
    }
    return grpc_slice_from_copied_string(string);
}

static inline grpc_slice
grpc_perl_slice_from_sv_impl(pTHX_ SV *sv) {
    STRLEN length = 0;
    const char *buffer = SvPV(sv, length);
    return grpc_perl_slice_from_buffer(buffer, length);
}

#define grpc_perl_slice_from_sv(sv) \
    grpc_perl_slice_from_sv_impl(aTHX_ (sv))

static inline SV *
grpc_perl_sv_from_slice_impl(pTHX_ grpc_slice slice) {
    return newSVpvn(
        (const char *)GRPC_SLICE_START_PTR(slice),
        GRPC_SLICE_LENGTH(slice)
    );
}

#define grpc_perl_sv_from_slice(slice) \
    grpc_perl_sv_from_slice_impl(aTHX_ (slice))

static inline grpc_call *
grpc_perl_channel_create_call(
    grpc_channel *channel,
    grpc_completion_queue *completion_queue,
    const char *method,
    const char *host_override,
    gpr_timespec deadline
) {
    grpc_slice method_slice = grpc_slice_from_static_string(method);
    grpc_slice host_slice;
    const grpc_slice *host_ptr = NULL;
    grpc_call *call;

    if (host_override != NULL) {
        host_slice = grpc_slice_from_static_string(host_override);
        host_ptr = &host_slice;
    }

    call = grpc_channel_create_call(
        channel,
        NULL,
        GRPC_PROPAGATE_DEFAULTS,
        completion_queue,
        method_slice,
        host_ptr,
        deadline,
        NULL
    );

    if (host_ptr != NULL) {
        grpc_slice_unref(host_slice);
    }
    grpc_slice_unref(method_slice);

    return call;
}

static inline void
grpc_perl_call_release(grpc_call *call) {
    if (call != NULL) {
        grpc_call_unref(call);
    }
}

typedef struct {
    grpc_slice slice;
} grpc_perl_send_status_details;

static inline void
grpc_perl_send_status_details_init(grpc_perl_send_status_details *details) {
    details->slice = grpc_empty_slice();
}

static inline void
grpc_perl_send_status_details_set_impl(pTHX_ grpc_perl_send_status_details *details, SV *sv) {
    details->slice = grpc_perl_slice_from_sv_impl(aTHX_ sv);
}

#define grpc_perl_send_status_details_set(details, sv) \
    grpc_perl_send_status_details_set_impl(aTHX_ (details), (sv))

static inline void
grpc_perl_send_status_details_attach(grpc_op *op, grpc_perl_send_status_details *details) {
    op->data.send_status_from_server.status_details = &details->slice;
}

static inline void
grpc_perl_send_status_details_cleanup(grpc_perl_send_status_details *details) {
    grpc_slice_unref(details->slice);
}

typedef struct {
    grpc_slice slice;
} grpc_perl_recv_status_details;

static inline void
grpc_perl_recv_status_details_init(grpc_perl_recv_status_details *details) {
    details->slice = grpc_empty_slice();
}

static inline void
grpc_perl_recv_status_details_attach(grpc_op *op, grpc_perl_recv_status_details *details) {
    op->data.recv_status_on_client.status_details = &details->slice;
    op->data.recv_status_on_client.error_string = NULL;
}

static inline SV *
grpc_perl_recv_status_details_to_sv_impl(pTHX_ grpc_perl_recv_status_details *details) {
    return grpc_perl_sv_from_slice_impl(aTHX_ details->slice);
}

#define grpc_perl_recv_status_details_to_sv(details) \
    grpc_perl_recv_status_details_to_sv_impl(aTHX_ (details))

static inline void
grpc_perl_recv_status_details_cleanup(grpc_perl_recv_status_details *details) {
    grpc_slice_unref(details->slice);
}

static inline grpc_channel_credentials *
grpc_perl_google_default_credentials_create(void) {
    grpc_google_default_credentials_options options;
    Zero(&options, 1, grpc_google_default_credentials_options);
    return grpc_google_default_credentials_create(NULL, &options);
}

static inline grpc_call_credentials *
grpc_perl_metadata_credentials_create_from_plugin(grpc_metadata_credentials_plugin plugin) {
    return grpc_metadata_credentials_create_from_plugin(
        plugin,
        GRPC_PRIVACY_AND_INTEGRITY,
        NULL
    );
}

static inline grpc_channel_credentials *
grpc_perl_ssl_credentials_create(
    const char *pem_root_certs,
    grpc_ssl_pem_key_cert_pair *pem_key_cert_pair
) {
    return grpc_ssl_credentials_create(
        pem_root_certs,
        pem_key_cert_pair,
        NULL,
        NULL
    );
}

static inline grpc_channel *
grpc_perl_insecure_channel_create(const char *target, const grpc_channel_args *args) {
    grpc_channel_credentials *insecure_cred = grpc_insecure_credentials_create();
    grpc_channel *channel = grpc_channel_create(target, insecure_cred, args);
    grpc_channel_credentials_release(insecure_cred);
    return channel;
}

static inline grpc_completion_queue *
grpc_perl_completion_queue_create_for_pluck(void) {
#if defined(GRPC_PERL_HAS_CQ_CREATE_FOR_PLUCK)
    return grpc_completion_queue_create_for_pluck(NULL);
#else
    grpc_completion_queue_attributes attr;
    attr.version = 1;
    attr.cq_completion_type = GRPC_CQ_PLUCK;
    attr.cq_polling_type = GRPC_CQ_DEFAULT_POLLING;
    return grpc_completion_queue_create(
        grpc_completion_queue_factory_lookup(&attr), &attr, NULL);
#endif
}

static inline void
grpc_perl_completion_queue_shutdown_and_destroy(grpc_completion_queue *cq) {
    if (cq == NULL) {
        return;
    }
    grpc_completion_queue_shutdown(cq);
    while (grpc_completion_queue_pluck(
        cq,
        NULL,
        gpr_inf_future(GPR_CLOCK_REALTIME),
        NULL
    ).type != GRPC_QUEUE_SHUTDOWN) {
    }
    grpc_completion_queue_destroy(cq);
}

static inline grpc_server_credentials *
grpc_perl_insecure_server_credentials_create(void) {
#if defined(GRPC_PERL_HAS_INSECURE_SERVER_CREDENTIALS_CREATE)
    return grpc_insecure_server_credentials_create();
#else
    return NULL;
#endif
}

static inline int
grpc_perl_server_add_http2_port(
    grpc_server *server,
    const char *addr,
    grpc_server_credentials *creds
) {
#if defined(GRPC_PERL_HAS_SERVER_ADD_HTTP2_PORT)
    return grpc_server_add_http2_port(server, addr, creds);
#else
    (void)server;
    (void)addr;
    (void)creds;
    return 0;
#endif
}

static inline grpc_server_credentials *
grpc_perl_ssl_server_credentials_create(
    const char *pem_root_certs,
    grpc_ssl_pem_key_cert_pair *pem_key_cert_pair
) {
#if defined(GRPC_PERL_HAS_SSL_SERVER_CREDENTIALS_CREATE_EX)
    return grpc_ssl_server_credentials_create_ex(
        pem_root_certs,
        pem_key_cert_pair,
        pem_key_cert_pair ? 1 : 0,
        GRPC_SSL_DONT_REQUEST_CLIENT_CERTIFICATE,
        NULL
    );
#else
    return grpc_ssl_server_credentials_create(
        pem_root_certs,
        pem_key_cert_pair,
        pem_key_cert_pair ? 1 : 0,
        0,
        NULL
    );
#endif
}

#endif
