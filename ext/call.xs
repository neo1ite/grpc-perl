Grpc::XS::Call
new(class, channel, method, deadline, ...)
    const char *class
    Grpc::XS::Channel channel
    const char *method
    Grpc::XS::Timeval deadline
  PREINIT:
    CallCTX *ctx = (CallCTX *)malloc(sizeof(CallCTX));
    const char *host_override = NULL;
  CODE:
    ctx->wrapped = NULL;
    ctx->cq = completion_queue;

    if (items > 5) {
      croak("Too many variables for constructor Grpc::XS::Call");
    }

    if (items == 5) {
      host_override = SvPV_nolen(ST(4));
    }

    ctx->wrapped = grpc_perl_channel_create_call(
      channel->wrapped,
      completion_queue,
      method,
      host_override,
      deadline->wrapped
    );

    grpc_perl_debugf_call(
      "new",
      "call=%p cq=%p method=%s host_override=%s",
      (void *)ctx->wrapped,
      (void *)ctx->cq,
      method,
      host_override ? host_override : "(null)"
    );

    RETVAL = ctx;
  OUTPUT: RETVAL

SV*
startBatch(Grpc::XS::Call self, ...)
  PREINIT:
    HV *result = newHV();
    grpc_perl_send_status_details send_status_details;
    grpc_perl_recv_status_details recv_status_details;
    grpc_op ops[8];
    grpc_op phase1_ops[8];
    grpc_op phase2_ops[8];
    grpc_op close_ops[1];
    size_t op_num = 0;
    size_t phase1_num = 0;
    size_t phase2_num = 0;
    grpc_byte_buffer *message = NULL;
    grpc_status_code status = GRPC_STATUS_OK;
    int cancelled = 0;
    char *message_str = NULL;
    size_t message_len = 0;
    grpc_metadata_array metadata;
    grpc_metadata_array trailing_metadata;
    grpc_metadata_array recv_metadata;
    grpc_metadata_array recv_trailing_metadata;
    int i;
    int has_send_close_from_client = 0;
    int has_send_status_from_server = 0;
    int has_send_message = 0;
    int has_recv_message = 0;
    int has_recv_close_on_server = 0;
    int split_send_close_from_client = 0;
    int split_server_status_recv_message = 0;
    int seen_send_message = 0;
  CODE:
    if (items > 1 && (items - 1) % 2) {
      croak("Expecting a hash as input to constructor");
    }

    Zero(ops, 8, grpc_op);
    Zero(phase1_ops, 8, grpc_op);
    Zero(phase2_ops, 8, grpc_op);
    Zero(close_ops, 1, grpc_op);

    grpc_metadata_array_init(&metadata);
    grpc_metadata_array_init(&trailing_metadata);
    grpc_metadata_array_init(&recv_metadata);
    grpc_metadata_array_init(&recv_trailing_metadata);
    grpc_perl_send_status_details_init(&send_status_details);
    grpc_perl_recv_status_details_init(&recv_status_details);

    if (items < 2) goto cleanup;

    for (i = 1; i < items; i += 2) {
      SV *key = ST(i);
      SV *value = ST(i + 1);
      grpc_op_type op_type;

      if (!looks_like_number(key)) {
        croak("Expected an int for message flags");
      }

      op_type = (grpc_op_type)SvIV(key);
      ops[op_num].op = op_type;
      ops[op_num].flags = 0;
      ops[op_num].reserved = NULL;

      grpc_perl_debugf_call(
        "parse",
        "input op[%lu]=%s",
        (unsigned long)op_num,
        grpc_perl_op_name(op_type)
      );

      switch (op_type) {
        case GRPC_OP_SEND_INITIAL_METADATA:
          value = SvRV(value);
          if (SvTYPE(value) != SVt_PVHV) {
            croak("Expected a hash for GRPC_OP_SEND_INITIAL_METADATA");
          }
          if (!create_metadata_array((HV *)value, &metadata)) {
            croak("Bad metadata value given");
          }
          ops[op_num].data.send_initial_metadata.maybe_compression_level.is_set = 0;
          ops[op_num].data.send_initial_metadata.count = metadata.count;
          ops[op_num].data.send_initial_metadata.metadata = metadata.metadata;
          grpc_perl_debugf_call("parse", "send metadata count=%lu", (unsigned long)metadata.count);
          break;

        case GRPC_OP_SEND_MESSAGE:
          has_send_message = 1;
          value = SvRV(value);
          if (SvTYPE(value) != SVt_PVHV) {
            croak("Expected a hash for send message");
          }
          {
            SV **flags = hv_fetchs((HV *)value, "flags", 0);
            if (flags) {
              if (!looks_like_number(*flags) || !SvIOK(*flags)) {
                croak("Expected an int for message flags");
              }
              ops[op_num].flags = SvIV(*flags) & GRPC_WRITE_USED_MASK;
            }
          }
          {
            SV **message_sv = hv_fetchs((HV *)value, "message", 0);
            if (!message_sv) {
              croak("Missing send message");
            }
            if (!SvOK(*message_sv)) {
              croak("Expected a string for send message");
            }
            message_str = SvPV(*message_sv, message_len);
            ops[op_num].data.send_message.send_message = string_to_byte_buffer(message_str, message_len);
            grpc_perl_debugf_call(
              "parse",
              "send message len=%lu flags=%u",
              (unsigned long)message_len,
              (unsigned)ops[op_num].flags
            );
          }
          break;

        case GRPC_OP_SEND_CLOSE_FROM_CLIENT:
          has_send_close_from_client = 1;
          grpc_perl_debugf_call("parse", "send close from client");
          break;

        case GRPC_OP_SEND_STATUS_FROM_SERVER:
          has_send_status_from_server = 1;
          if (SvROK(value)) value = SvRV(value);
          if (SvTYPE(value) != SVt_PVHV) {
            croak("Expected a hash for send status from server");
          }

          if (hv_exists((HV *)value, "metadata", strlen("metadata"))) {
            SV **inner_value = hv_fetchs((HV *)value, "metadata", 0);
            if (!create_metadata_array((HV *)SvRV(*inner_value), &trailing_metadata)) {
              croak("Bad trailing metadata value given");
            }
            ops[op_num].data.send_status_from_server.trailing_metadata = trailing_metadata.metadata;
            ops[op_num].data.send_status_from_server.trailing_metadata_count = trailing_metadata.count;
          }

          if (hv_exists((HV *)value, "code", strlen("code"))) {
            SV **inner_value = hv_fetchs((HV *)value, "code", 0);
            if (!SvIOK(*inner_value)) {
              croak("Status code must be an integer");
            }
            ops[op_num].data.send_status_from_server.status = SvIV(*inner_value);
          }
          else {
            croak("Integer status code is required");
          }

          if (hv_exists((HV *)value, "details", strlen("details"))) {
            SV **inner_value = hv_fetchs((HV *)value, "details", 0);
            if (!SvOK(*inner_value)) {
              croak("Status details must be a string");
            }
            grpc_perl_send_status_details_set(&send_status_details, *inner_value);
            grpc_perl_send_status_details_attach(&ops[op_num], &send_status_details);
            grpc_perl_debugf_call(
              "parse",
              "send status code=%d trailing_count=%lu details_len=%lu",
              (int)ops[op_num].data.send_status_from_server.status,
              (unsigned long)trailing_metadata.count,
              (unsigned long)SvCUR(*inner_value)
            );
          }
          else {
            croak("String status details is required");
          }
          break;

        case GRPC_OP_RECV_INITIAL_METADATA:
          ops[op_num].data.recv_initial_metadata.recv_initial_metadata = &recv_metadata;
          break;

        case GRPC_OP_RECV_MESSAGE:
          has_recv_message = 1;
          ops[op_num].data.recv_message.recv_message = &message;
          break;

        case GRPC_OP_RECV_STATUS_ON_CLIENT:
          ops[op_num].data.recv_status_on_client.trailing_metadata = &recv_trailing_metadata;
          ops[op_num].data.recv_status_on_client.status = &status;
          grpc_perl_recv_status_details_attach(&ops[op_num], &recv_status_details);
          break;

        case GRPC_OP_RECV_CLOSE_ON_SERVER:
          has_recv_close_on_server = 1;
          ops[op_num].data.recv_close_on_server.cancelled = &cancelled;
          break;

        default:
          croak("Unrecognized key in batch");
      }

      op_num++;
    }

    /*
     * Split SEND_CLOSE_FROM_CLIENT only when it appears BEFORE SEND_MESSAGE.
     *
     * Why:
     * - [SEND_INITIAL_METADATA, SEND_CLOSE_FROM_CLIENT] must stay a single batch.
     *   If we split it, phase1 becomes SEND_INITIAL_METADATA-only, and util.h
     *   currently treats that as compat no-op, so nothing is actually sent.
     *   Then SEND_CLOSE_FROM_CLIENT alone times out.
     *
     * - [SEND_INITIAL_METADATA, SEND_CLOSE_FROM_CLIENT, SEND_MESSAGE] is invalid
     *   as-is because CLOSE comes before MESSAGE; that case still needs split.
     *
     * - [SEND_INITIAL_METADATA, SEND_MESSAGE, SEND_CLOSE_FROM_CLIENT] is already
     *   ordered correctly and should not be split.
     */
    if (has_send_close_from_client && has_send_message) {
      for (i = 0; i < (int)op_num; i++) {
        if (ops[i].op == GRPC_OP_SEND_MESSAGE) {
          seen_send_message = 1;
        }
        else if (ops[i].op == GRPC_OP_SEND_CLOSE_FROM_CLIENT && !seen_send_message) {
          split_send_close_from_client = 1;
          break;
        }
      }
    }

    split_server_status_recv_message = has_send_status_from_server && has_recv_message;

    grpc_perl_debugf_call(
      "plan",
      "op_num=%lu has_send_message=%d split_send_close=%d split_send_status_recv_message=%d has_recv_close=%d",
      (unsigned long)op_num,
      has_send_message,
      split_send_close_from_client,
      split_server_status_recv_message,
      has_recv_close_on_server
    );

    if (split_send_close_from_client) {
      grpc_perl_debugf_call("plan", "reordered SEND_CLOSE_FROM_CLIENT to separate phase because it appears before SEND_MESSAGE");
      for (i = 0; i < (int)op_num; i++) {
        if (ops[i].op == GRPC_OP_SEND_CLOSE_FROM_CLIENT) {
          continue;
        }
        phase1_ops[phase1_num++] = ops[i];
      }

      grpc_perl_call_run_batch(
        aTHX_
        "startBatch.phase1",
        self->wrapped,
        self->cq,
        phase1_ops,
        phase1_num,
        result,
        &recv_metadata,
        &recv_trailing_metadata,
        &message,
        &status,
        &recv_status_details,
        &cancelled
      );

      close_ops[0].op = GRPC_OP_SEND_CLOSE_FROM_CLIENT;
      close_ops[0].flags = 0;
      close_ops[0].reserved = NULL;

      grpc_perl_call_run_batch(
        aTHX_
        "startBatch.phase_close",
        self->wrapped,
        self->cq,
        close_ops,
        1,
        result,
        &recv_metadata,
        &recv_trailing_metadata,
        &message,
        &status,
        &recv_status_details,
        &cancelled
      );
    }
    else if (split_server_status_recv_message) {
      grpc_perl_debugf_call(
        "plan",
        "splitting RECV_MESSAGE away from SEND_STATUS_FROM_SERVER; RECV_CLOSE_ON_SERVER stays with status phase=%d",
        has_recv_close_on_server
      );

      for (i = 0; i < (int)op_num; i++) {
        if (ops[i].op == GRPC_OP_SEND_STATUS_FROM_SERVER) {
          phase2_ops[phase2_num++] = ops[i];
          continue;
        }
        if (ops[i].op == GRPC_OP_RECV_CLOSE_ON_SERVER) {
          phase2_ops[phase2_num++] = ops[i];
          continue;
        }
        phase1_ops[phase1_num++] = ops[i];
      }

      grpc_perl_call_run_batch(
        aTHX_
        "startBatch.phase_recv_before_status",
        self->wrapped,
        self->cq,
        phase1_ops,
        phase1_num,
        result,
        &recv_metadata,
        &recv_trailing_metadata,
        &message,
        &status,
        &recv_status_details,
        &cancelled
      );

      grpc_perl_call_run_batch(
        aTHX_
        "startBatch.phase_status",
        self->wrapped,
        self->cq,
        phase2_ops,
        phase2_num,
        result,
        &recv_metadata,
        &recv_trailing_metadata,
        &message,
        &status,
        &recv_status_details,
        &cancelled
      );
    }
    else {
      grpc_perl_call_run_batch(
        aTHX_
        "startBatch.single",
        self->wrapped,
        self->cq,
        ops,
        op_num,
        result,
        &recv_metadata,
        &recv_trailing_metadata,
        &message,
        &status,
        &recv_status_details,
        &cancelled
      );
    }

  cleanup:
    grpc_metadata_array_destroy(&metadata);
    grpc_metadata_array_destroy(&trailing_metadata);
    grpc_metadata_array_destroy(&recv_metadata);
    grpc_metadata_array_destroy(&recv_trailing_metadata);
    grpc_perl_recv_status_details_cleanup(&recv_status_details);
    grpc_perl_send_status_details_cleanup(&send_status_details);

    for (i = 0; i < (int)op_num; i++) {
      if (ops[i].op == GRPC_OP_SEND_MESSAGE) {
        grpc_byte_buffer_destroy(ops[i].data.send_message.send_message);
      }
    }

    if (message != NULL) {
      grpc_byte_buffer_destroy(message);
    }

    RETVAL = (SV *)newRV_noinc((SV *)result);
  OUTPUT: RETVAL

const char*
getPeer(Grpc::XS::Call self)
  CODE:
    RETVAL = grpc_call_get_peer(self->wrapped);
  OUTPUT: RETVAL

void
cancel(Grpc::XS::Call self)
  CODE:
    grpc_call_cancel(self->wrapped, NULL);
  OUTPUT:

int
setCredentials(Grpc::XS::Call self, Grpc::XS::CallCredentials creds)
  CODE:
    RETVAL = grpc_call_set_credentials(self->wrapped, creds->wrapped);
  OUTPUT: RETVAL

void
DESTROY(Grpc::XS::Call self)
  CODE:
    grpc_perl_debugf_call("DESTROY", "call=%p cq=%p", (void *)self->wrapped, (void *)self->cq);
    grpc_perl_call_release(self->wrapped);
    Safefree(self);
