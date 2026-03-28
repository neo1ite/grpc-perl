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

#endif
