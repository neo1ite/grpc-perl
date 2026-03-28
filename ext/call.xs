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
    // Params:
    //    * channel       - channel object
    //    * method        - string
    //    * deadline      - timeval object
    //    * host_override - string (optional)
    ctx->wrapped = NULL;

    if (items > 5) {
      croak("Too many variables for constructor Grpc::XS::Call");
    }

    if (items == 5) {
      host_override = SvPV_nolen(ST(4));
    }

    ctx->wrapped = grpc_perl_channel_create_call(
      channel->wrapped, completion_queue,
      method, host_override, deadline->wrapped
    );

    RETVAL = ctx;
  OUTPUT: RETVAL

SV*
startBatch(Grpc::XS::Call self, ...)
  CODE:
    if ( items > 1 && ( items - 1 ) % 2 ) {
      croak("Expecting a hash as input to constructor");
    }

    /**
     * Start a batch of RPC actions.
     * @param array batch Array of actions to take
     * @return object Object with results of all actions
    */

    HV *result = newHV();
    grpc_perl_send_status_details send_status_details;
    grpc_perl_recv_status_details recv_status_details;
    grpc_op ops[8];

    size_t op_num = 0;

    grpc_byte_buffer *message = NULL;
    grpc_status_code status = GRPC_STATUS_OK;
    grpc_call_error error;
    int cancelled = 0;

    char *message_str = NULL;
    size_t message_len = 0;

    grpc_metadata_array metadata;
    grpc_metadata_array trailing_metadata;
    grpc_metadata_array recv_metadata;
    grpc_metadata_array recv_trailing_metadata;

    grpc_metadata_array_init(&metadata);
    grpc_metadata_array_init(&trailing_metadata);
    grpc_metadata_array_init(&recv_metadata);
    grpc_metadata_array_init(&recv_trailing_metadata);
    grpc_perl_send_status_details_init(&send_status_details);
    grpc_perl_recv_status_details_init(&recv_status_details);

    if (items < 2) goto cleanup;

    int i;
    for (i = 1; i < items; i += 2 ) {
      SV *key = ST(i);
      SV *value = ST(i+1);

      if (!looks_like_number(key)) {
        croak("Expected an int for message flags");
        goto cleanup;
      }

      switch ((grpc_op_type)SvIV(key)) {
        case GRPC_OP_SEND_INITIAL_METADATA:
          value = SvRV(value);
          if (SvTYPE(value) != SVt_PVHV) {
            croak("Expected a hash for GRPC_OP_SEND_INITIAL_METADATA");
            goto cleanup;
          }
          if (!create_metadata_array((HV*)value, &metadata)) {
            croak("Bad metadata value given");
            goto cleanup;
          }
          ops[op_num].data.send_initial_metadata.maybe_compression_level.is_set = 0;
          ops[op_num].data.send_initial_metadata.count =
            metadata.count;
          ops[op_num].data.send_initial_metadata.metadata =
            metadata.metadata;
          break;

        case GRPC_OP_SEND_MESSAGE:
          value = SvRV(value);
          if (SvTYPE(value) != SVt_PVHV) {
            croak("Expected a hash for send message");
            goto cleanup;
          }
          {
            // ops[op_num].flags = hash->{flags} & GRPC_WRITE_USED_MASK;// int
            SV **flags = hv_fetchs((HV*)value, "flags", 0);
            if (flags) {
              if (!looks_like_number(*flags) || !SvIOK(*flags)) {
                croak("Expected an int for message flags");
                goto cleanup;
              }
              ops[op_num].flags = SvIV(*flags) & GRPC_WRITE_USED_MASK;
            }
            // ops[op_num].data.send_message = hash->{message}; // string
          }
          {
            SV **message_sv = hv_fetchs((HV*)value,"message",0);
            if (!message_sv) {
              croak("Missing send message");
              goto cleanup;
            }
            if (!SvOK(*message_sv)) {
              croak("Expected a string for send message");
              goto cleanup;
            }
            message_str = SvPV(*message_sv, message_len);
            ops[op_num].data.send_message.send_message =
              string_to_byte_buffer(message_str, message_len);
          }
          break;

        case GRPC_OP_SEND_CLOSE_FROM_CLIENT:
          break;

        case GRPC_OP_SEND_STATUS_FROM_SERVER:
          if (SvROK(value)) value = SvRV(value);
          if (SvTYPE(value) != SVt_PVHV) {
            croak("Expected a hash for send status from server");
            goto cleanup;
          }

          // hash->{metadata}
          if (hv_exists((HV*)value, "metadata", strlen("metadata"))) {
            SV **inner_value = hv_fetchs((HV*)value, "metadata", 0);
            if (!create_metadata_array((HV*)SvRV(*inner_value), &trailing_metadata)) {
              croak("Bad trailing metadata value given");
              goto cleanup;
            }
            ops[op_num].data.send_status_from_server.trailing_metadata =
                trailing_metadata.metadata;
            ops[op_num].data.send_status_from_server.trailing_metadata_count =
                trailing_metadata.count;
          }
          // hash->{code}
          if (hv_exists((HV*)value, "code", strlen("code"))) {
            SV **inner_value = hv_fetchs((HV*)value, "code", 0);
            if (!SvIOK(*inner_value)) {
              croak("Status code must be an integer");
              goto cleanup;
            }
            ops[op_num].data.send_status_from_server.status =
                SvIV(*inner_value);
          } else {
            croak("Integer status code is required");
            goto cleanup;
          }
          // hash->{details}
          if (hv_exists((HV*)value, "details", strlen("details"))) {
            SV **inner_value = hv_fetchs((HV*)value, "details", 0);
            if (!SvOK(*inner_value)) {
              croak("Status details must be a string");
              goto cleanup;
            }
            grpc_perl_send_status_details_set(&send_status_details, *inner_value);
            grpc_perl_send_status_details_attach(&ops[op_num], &send_status_details);
          } else {
            croak("String status details is required");
            goto cleanup;
          }
          break;

        case GRPC_OP_RECV_INITIAL_METADATA:
          ops[op_num].data.recv_initial_metadata.recv_initial_metadata =
            &recv_metadata;
          break;

        case GRPC_OP_RECV_MESSAGE:
          ops[op_num].data.recv_message.recv_message =
            &message;
          break;

        case GRPC_OP_RECV_STATUS_ON_CLIENT:
          ops[op_num].data.recv_status_on_client.trailing_metadata =
            &recv_trailing_metadata;
          ops[op_num].data.recv_status_on_client.status = &status;
          grpc_perl_recv_status_details_attach(&ops[op_num], &recv_status_details);
          break;

        case GRPC_OP_RECV_CLOSE_ON_SERVER:
          ops[op_num].data.recv_close_on_server.cancelled = &cancelled;
          break;

        default:
          croak("Unrecognized key in batch");
          goto cleanup;
      }
      ops[op_num].op = (grpc_op_type)SvIV(key);
      if (ops[op_num].op != GRPC_OP_SEND_MESSAGE) {
        ops[op_num].flags = 0;
      }
      ops[op_num].reserved = NULL;
      op_num++;
    }

    error = grpc_call_start_batch(self->wrapped, ops, op_num, self->wrapped,
                                  NULL);
    if (error != GRPC_CALL_OK) {
      croak("start_batch was called incorrectly, error = %d", error);
      goto cleanup;
    }

    grpc_completion_queue_pluck(completion_queue, self->wrapped,
                                gpr_inf_future(GPR_CLOCK_REALTIME), NULL);

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
          hv_stores(result, "metadata",
            newRV_noinc((SV *)grpc_parse_metadata_array(&recv_metadata)));
          break;
        case GRPC_OP_RECV_MESSAGE:
          byte_buffer_to_string(message, &message_str, &message_len);
          if (message_str == NULL) {
            hv_stores(result, "message", newSV(0));
          } else {
            hv_stores(result, "message", newSVpvn(message_str, message_len));
          }
          break;
        case GRPC_OP_RECV_STATUS_ON_CLIENT: {
          HV *recv_status = newHV();
          hv_stores(recv_status, "metadata",
            newRV_noinc((SV *)grpc_parse_metadata_array(&recv_trailing_metadata)));
          hv_stores(recv_status, "code", newSViv(status));
          hv_stores(recv_status, "details",
            grpc_perl_recv_status_details_to_sv(&recv_status_details));
          hv_stores(result, "status", newRV_noinc((SV *)recv_status));
          break;
        }
        case GRPC_OP_RECV_CLOSE_ON_SERVER:
          hv_stores(result, "cancelled", newSViv(cancelled));
          break;
        default:
          break;
      }
    }

  cleanup:
    grpc_metadata_array_destroy(&metadata);
    grpc_metadata_array_destroy(&trailing_metadata);
    grpc_metadata_array_destroy(&recv_metadata);
    grpc_metadata_array_destroy(&recv_trailing_metadata);
    grpc_perl_recv_status_details_cleanup(&recv_status_details);
    grpc_perl_send_status_details_cleanup(&send_status_details);

    for (i = 0; i < op_num; i++) {
      if (ops[i].op == GRPC_OP_SEND_MESSAGE) {
        grpc_byte_buffer_destroy(ops[i].data.send_message.send_message);
      }
    }
    if (message != NULL) {
      grpc_byte_buffer_destroy(message);
    }
    RETVAL = (SV*)newRV_noinc((SV *)result);
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
    grpc_perl_call_release(self->wrapped);
    Safefree(self);
