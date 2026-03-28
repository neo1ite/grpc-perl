#ifndef GRPC_PERL_UTIL_H
#define GRPC_PERL_UTIL_H

#include "compat.h"

grpc_byte_buffer *string_to_byte_buffer(char *string, size_t length);

void byte_buffer_to_string(grpc_byte_buffer *buffer, char **out_string,
                           size_t *out_length);

void grpc_perl_init();
void grpc_perl_destroy();

extern grpc_completion_queue *completion_queue;

void grpc_perl_init_completion_queue();
void grpc_perl_shutdown_completion_queue();

void perl_grpc_read_args_array(HV *hash, grpc_channel_args *args);
HV* grpc_parse_metadata_array(grpc_metadata_array *metadata_array);
bool create_metadata_array(HV *hash, grpc_metadata_array *metadata);

int plugin_get_metadata(void *ptr, grpc_auth_metadata_context context,
                        grpc_credentials_plugin_metadata_cb cb,
                        void *user_data,
                        grpc_metadata creds_md[GRPC_METADATA_CREDENTIALS_PLUGIN_SYNC_MAX],
                        size_t *num_creds_md, grpc_status_code *status,
                        const char **error_details);

void plugin_destroy_state(void *ptr);

#define grpc_slice_or_string_to_sv(slice) grpc_perl_sv_from_slice((slice))
#define grpc_slice_or_buffer_length_to_sv(slice) grpc_perl_sv_from_slice((slice))

static grpc_event
grpc_perl_call_pluck_seconds(grpc_completion_queue *cq, void *tag, int seconds) {
    return grpc_completion_queue_pluck(
        cq,
        tag,
        grpc_perl_deadline_seconds(seconds),
        NULL
    );
}

static void
grpc_perl_call_collect_results(
    pTHX_
    HV *result,
    grpc_op *ops,
    size_t op_num,
    grpc_metadata_array *recv_metadata,
    grpc_metadata_array *recv_trailing_metadata,
    grpc_byte_buffer **message,
    grpc_status_code *status,
    grpc_perl_recv_status_details *recv_status_details,
    int *cancelled
) {
    size_t i;
    char *message_str = NULL;
    size_t message_len = 0;
    grpc_byte_buffer *message_buf = NULL;

    if (message != NULL) {
        message_buf = *message;
    }

    for (i = 0; i < op_num; i++) {
        switch (ops[i].op) {
            case GRPC_OP_SEND_INITIAL_METADATA:
                hv_stores(result, "send_metadata", newSViv(TRUE));
                break;

            case GRPC_OP_SEND_MESSAGE:
                hv_stores(result, "send_message", newSViv(TRUE));
                break;

            case GRPC_OP_SEND_CLOSE_FROM_CLIENT:
                hv_stores(result, "send_close", newSViv(TRUE));
                break;

            case GRPC_OP_SEND_STATUS_FROM_SERVER:
                hv_stores(result, "send_status", newSViv(TRUE));
                break;

            case GRPC_OP_RECV_INITIAL_METADATA:
                hv_stores(
                    result,
                    "metadata",
                    newRV_noinc((SV *)grpc_parse_metadata_array(recv_metadata))
                );
                break;

            case GRPC_OP_RECV_MESSAGE:
                byte_buffer_to_string(message_buf, &message_str, &message_len);
                if (message_str == NULL) {
                    hv_stores(result, "message", newSV(0));
                } else {
                    hv_stores(result, "message", newSVpvn(message_str, message_len));
                }
                break;

            case GRPC_OP_RECV_STATUS_ON_CLIENT:
            {
                HV *recv_status = newHV();
                hv_stores(
                    recv_status,
                    "metadata",
                    newRV_noinc((SV *)grpc_parse_metadata_array(recv_trailing_metadata))
                );
                hv_stores(
                    recv_status,
                    "code",
                    newSViv(status ? *status : GRPC_STATUS_UNKNOWN)
                );
                hv_stores(
                    recv_status,
                    "details",
                    grpc_perl_recv_status_details_to_sv(recv_status_details)
                );
                hv_stores(result, "status", newRV_noinc((SV *)recv_status));
                break;
            }

            case GRPC_OP_RECV_CLOSE_ON_SERVER:
                hv_stores(
                    result,
                    "cancelled",
                    newSViv(cancelled ? *cancelled : 0)
                );
                break;

            default:
                break;
        }
    }
}

static int
grpc_perl_call_batch_is_metadata_only(grpc_op *ops, size_t op_num) {
    return op_num == 1 && ops[0].op == GRPC_OP_SEND_INITIAL_METADATA;
}

static void
grpc_perl_call_run_batch(
    pTHX_
    const char *phase,
    grpc_call *call,
    grpc_completion_queue *cq,
    grpc_op *ops,
    size_t op_num,
    HV *result,
    grpc_metadata_array *recv_metadata,
    grpc_metadata_array *recv_trailing_metadata,
    grpc_byte_buffer **message,
    grpc_status_code *status,
    grpc_perl_recv_status_details *recv_status_details,
    int *cancelled
) {
    grpc_call_error error;
    grpc_event ev;

    if (op_num == 0) {
        grpc_perl_debugf_call(phase, "skip empty batch");
        return;
    }

    if (grpc_perl_call_batch_is_metadata_only(ops, op_num)) {
        grpc_perl_debugf_call(phase, "compat no-op for SEND_INITIAL_METADATA only");
        hv_stores(result, "send_metadata", newSViv(TRUE));
        return;
    }

    grpc_perl_debug_batch("call", phase, ops, op_num);
    grpc_perl_debugf_call(
        phase,
        "before grpc_call_start_batch op_num=%lu cq=%p call=%p",
        (unsigned long)op_num,
        (void *)cq,
        (void *)call
    );

    error = grpc_call_start_batch(call, ops, op_num, call, NULL);

    grpc_perl_debugf_call(
        phase,
        "grpc_call_start_batch -> %d (%s)",
        (int)error,
        grpc_perl_call_error_name(error)
    );

    if (error != GRPC_CALL_OK) {
        croak("start_batch was called incorrectly, error = %d", (int)error);
    }

    if (cq == NULL) {
        croak("call has no completion queue");
    }

    ev = grpc_perl_call_pluck_seconds(cq, call, 10);

    grpc_perl_debugf_call(
        phase,
        "pluck -> type=%d(%s) success=%d tag=%p",
        (int)ev.type,
        grpc_perl_event_type_name(ev.type),
        (int)ev.success,
        ev.tag
    );

    if (ev.type == GRPC_QUEUE_TIMEOUT) {
        croak("startBatch timed out");
    }

    if (ev.type != GRPC_OP_COMPLETE) {
        croak("startBatch failed: event.type=%d success=%d", (int)ev.type, (int)ev.success);
    }

    if (!ev.success) {
        grpc_perl_debugf_call(
            phase,
            "non-fatal completion: success=0, continuing to collect results"
        );
    }

    grpc_perl_call_collect_results(
        aTHX_
        result,
        ops,
        op_num,
        recv_metadata,
        recv_trailing_metadata,
        message,
        status,
        recv_status_details,
        cancelled
    );
}

#endif
