Grpc::XS::Server
new(const char *class, ...)
  PREINIT:
    ServerCTX *ctx = (ServerCTX *)malloc(sizeof(ServerCTX));
    HV *hash = NULL;
    grpc_channel_args args;
    int i;
  CODE:
    ctx->wrapped = NULL;
    ctx->call_cq = NULL;
    ctx->shutdown_cq = NULL;
    ctx->started = 0;
    ctx->has_listener = 0;

    if (items > 1 && (items - 1) % 2) {
      Safefree(ctx);
      croak("Expecting a hash as input to constructor");
    }

    if (items > 1) {
      hash = newHV();
      for (i = 1; i < items; i += 2) {
        SV *key = ST(i);
        SV *value = newSVsv(ST(i + 1));
        hv_store_ent(hash, key, value, 0);
      }
      perl_grpc_read_args_array(hash, &args);
      ctx->wrapped = grpc_server_create(&args, NULL);
      free(args.args);
      SvREFCNT_dec((SV *)hash);
    }
    else {
      ctx->wrapped = grpc_server_create(NULL, NULL);
    }

    if (ctx->wrapped == NULL) {
      Safefree(ctx);
      croak("grpc_server_create failed");
    }

    ctx->call_cq = grpc_perl_completion_queue_create_for_pluck();
    ctx->shutdown_cq = grpc_perl_completion_queue_create_for_pluck();

    if (ctx->call_cq == NULL || ctx->shutdown_cq == NULL) {
      if (ctx->call_cq != NULL) {
        grpc_perl_completion_queue_shutdown_and_destroy(ctx->call_cq);
      }
      if (ctx->shutdown_cq != NULL) {
        grpc_perl_completion_queue_shutdown_and_destroy(ctx->shutdown_cq);
      }
      grpc_server_destroy(ctx->wrapped);
      Safefree(ctx);
      croak("failed to create server completion queues");
    }

    grpc_server_register_completion_queue(ctx->wrapped, ctx->call_cq, NULL);
    grpc_server_register_completion_queue(ctx->wrapped, ctx->shutdown_cq, NULL);

    grpc_perl_debugf(
      "new",
      "server=%p call_cq=%p shutdown_cq=%p",
      (void *)ctx->wrapped,
      (void *)ctx->call_cq,
      (void *)ctx->shutdown_cq
    );

    RETVAL = ctx;
  OUTPUT: RETVAL

SV*
requestCall(Grpc::XS::Server self)
  PREINIT:
    grpc_call_error error_code;
    grpc_call *call = NULL;
    grpc_call_details details;
    grpc_metadata_array metadata;
    grpc_event event;
    void *tag = NULL;
    int tag_token = 0;
    HV *result = NULL;
    CallCTX *call_ctx = NULL;
    TimevalCTX *timeval_ctx = NULL;
    SV *retval = &PL_sv_undef;
  CODE:
    grpc_call_details_init(&details);
    grpc_metadata_array_init(&metadata);

    tag = &tag_token;

    grpc_perl_debugf("requestCall", "before grpc_server_request_call");

    error_code = grpc_server_request_call(
      self->wrapped,
      &call,
      &details,
      &metadata,
      self->call_cq,
      self->call_cq,
      tag
    );

    grpc_perl_debugf(
      "requestCall",
      "grpc_server_request_call -> %d",
      (int)error_code
    );

    if (error_code != GRPC_CALL_OK) {
      croak("grpc_server_request_call failed: %d", (int)error_code);
    }

    event = grpc_completion_queue_pluck(
      self->call_cq,
      tag,
      grpc_perl_deadline_seconds(10),
      NULL
    );

    grpc_perl_debugf(
      "requestCall",
      "pluck -> type=%d(%s) success=%d tag=%p",
      (int)event.type,
      grpc_perl_event_type_name(event.type),
      (int)event.success,
      event.tag
    );

    if (event.type == GRPC_QUEUE_TIMEOUT) {
      croak("requestCall timed out waiting for incoming RPC");
    }

    if (event.type != GRPC_OP_COMPLETE || !event.success) {
      croak(
        "requestCall failed: event.type=%d success=%d",
        (int)event.type,
        (int)event.success
      );
    }

    result = newHV();

    call_ctx = (CallCTX *)malloc(sizeof(CallCTX));
    call_ctx->wrapped = call;
    call_ctx->cq = self->call_cq;
    hv_stores(
      result,
      "call",
      sv_setref_pv(newSV(0), "Grpc::XS::Call", (void *)call_ctx)
    );

    timeval_ctx = (TimevalCTX *)malloc(sizeof(TimevalCTX));
    timeval_ctx->wrapped = details.deadline;
    hv_stores(
      result,
      "absolute_deadline",
      sv_setref_pv(newSV(0), "Grpc::XS::Timeval", (void *)timeval_ctx)
    );

    hv_stores(result, "method", grpc_perl_sv_from_slice(details.method));
    hv_stores(result, "host", grpc_perl_sv_from_slice(details.host));
    hv_stores(result, "metadata", newRV_noinc((SV *)grpc_parse_metadata_array(&metadata)));

    grpc_perl_debugf(
      "requestCall",
      "method=%.*s host=%.*s metadata_count=%lu call=%p",
      (int)GRPC_SLICE_LENGTH(details.method),
      (const char *)GRPC_SLICE_START_PTR(details.method),
      (int)GRPC_SLICE_LENGTH(details.host),
      (const char *)GRPC_SLICE_START_PTR(details.host),
      (unsigned long)metadata.count,
      (void *)call
    );

    retval = newRV_noinc((SV *)result);

  cleanup:
    grpc_call_details_destroy(&details);
    grpc_metadata_array_destroy(&metadata);
    RETVAL = retval;
  OUTPUT: RETVAL

long
addHttp2Port(Grpc::XS::Server self, SV *addr)
  PREINIT:
    grpc_server_credentials *creds = NULL;
  CODE:
    grpc_perl_debugf("addHttp2Port", "addr=%s", SvPV_nolen(addr));

    creds = grpc_perl_insecure_server_credentials_create();
    if (creds == NULL) {
      croak("insecure server credentials are unavailable in this gRPC build");
    }

    RETVAL = grpc_perl_server_add_http2_port(self->wrapped, SvPV_nolen(addr), creds);
    grpc_server_credentials_release(creds);

    if (RETVAL > 0) {
      self->has_listener = 1;
    }

    grpc_perl_debugf(
      "addHttp2Port",
      "ret=%ld has_listener=%d",
      RETVAL,
      self->has_listener
    );
  OUTPUT: RETVAL

long
addSecureHttp2Port(Grpc::XS::Server self, SV *addr, Grpc::XS::ServerCredentials creds)
  CODE:
    grpc_perl_debugf(
      "addSecureHttp2Port",
      "addr=%s creds=%p",
      SvPV_nolen(addr),
      (void *)creds->wrapped
    );

    RETVAL = grpc_perl_server_add_http2_port(self->wrapped, SvPV_nolen(addr), creds->wrapped);

    if (RETVAL > 0) {
      self->has_listener = 1;
    }

    grpc_perl_debugf(
      "addSecureHttp2Port",
      "ret=%ld has_listener=%d",
      RETVAL,
      self->has_listener
    );
  OUTPUT: RETVAL

void
start(Grpc::XS::Server self)
  CODE:
    grpc_perl_debugf("start", "starting server");
    grpc_server_start(self->wrapped);
    self->started = 1;

void
DESTROY(Grpc::XS::Server self)
  PREINIT:
    void *tag = NULL;
    int tag_token = 0;
    grpc_event shutdown_event;
  CODE:
    if (self == NULL) {
      XSRETURN_EMPTY;
    }

    grpc_perl_debugf(
      "DESTROY",
      "started=%d has_listener=%d wrapped=%p call_cq=%p shutdown_cq=%p",
      self->started,
      self->has_listener,
      (void *)self->wrapped,
      (void *)self->call_cq,
      (void *)self->shutdown_cq
    );

    if (self->wrapped != NULL && self->shutdown_cq != NULL && (self->started || self->has_listener)) {
      tag = &tag_token;
      grpc_server_shutdown_and_notify(self->wrapped, self->shutdown_cq, tag);
      grpc_perl_debugf("DESTROY", "shutdown_and_notify scheduled tag=%p", tag);

      if (self->started) {
        grpc_perl_debugf("DESTROY", "cancel_all_calls");
        grpc_server_cancel_all_calls(self->wrapped);
      }

      shutdown_event = grpc_completion_queue_pluck(
        self->shutdown_cq,
        tag,
        grpc_perl_deadline_seconds(5),
        NULL
      );

      grpc_perl_debugf(
        "DESTROY",
        "shutdown pluck -> type=%d(%s) success=%d tag=%p",
        (int)shutdown_event.type,
        grpc_perl_event_type_name(shutdown_event.type),
        (int)shutdown_event.success,
        shutdown_event.tag
      );
    }
    else {
      grpc_perl_debugf("DESTROY", "skip shutdown_and_notify");
    }

    if (self->wrapped != NULL) {
      grpc_server_destroy(self->wrapped);
      self->wrapped = NULL;
    }

    if (self->call_cq != NULL) {
      grpc_perl_completion_queue_shutdown_and_destroy(self->call_cq);
      self->call_cq = NULL;
    }

    if (self->shutdown_cq != NULL) {
      grpc_perl_completion_queue_shutdown_and_destroy(self->shutdown_cq);
      self->shutdown_cq = NULL;
    }

    Safefree(self);
