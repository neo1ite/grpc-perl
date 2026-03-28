Grpc::XS::CallCredentials
createComposite(Grpc::XS::CallCredentials cred1, Grpc::XS::CallCredentials cred2)
  PREINIT:
    CallCredentialsCTX *ctx = (CallCredentialsCTX *)malloc(sizeof(CallCredentialsCTX));
  CODE:
    ctx->wrapped = grpc_composite_call_credentials_create(
      cred1->wrapped,
      cred2->wrapped,
      NULL
    );
    grpc_perl_debugf_plugin(
      "createComposite",
      "cred1=%p cred2=%p wrapped=%p",
      (void *)cred1->wrapped,
      (void *)cred2->wrapped,
      (void *)ctx->wrapped
    );
    RETVAL = ctx;
  OUTPUT: RETVAL

Grpc::XS::CallCredentials
createFromPlugin(SV *callback)
  PREINIT:
    CallCredentialsCTX *ctx = (CallCredentialsCTX *)malloc(sizeof(CallCredentialsCTX));
    grpc_metadata_credentials_plugin plugin;
    SV *state = NULL;
  CODE:
    ctx->wrapped = NULL;
    Zero(&plugin, 1, grpc_metadata_credentials_plugin);

    if (!SvROK(callback) || SvTYPE(SvRV(callback)) != SVt_PVCV) {
      Safefree(ctx);
      croak("createFromPlugin expects a code reference");
    }

    state = newSVsv(callback);

    plugin.get_metadata = plugin_get_metadata;
    plugin.destroy = plugin_destroy_state;
    plugin.state = (void *)state;
    plugin.type = "grpc-perl";

    grpc_perl_debugf_plugin(
      "createFromPlugin",
      "callback_ref=%p callback_cv=%p state=%p",
      (void *)callback,
      (void *)SvRV(callback),
      (void *)state
    );

    ctx->wrapped = grpc_perl_metadata_credentials_create_from_plugin(plugin);

    if (ctx->wrapped == NULL) {
      SvREFCNT_dec(state);
      Safefree(ctx);
      croak("failed to create call credentials from plugin");
    }

    RETVAL = ctx;
  OUTPUT: RETVAL

void
DESTROY(Grpc::XS::CallCredentials self)
  CODE:
    grpc_perl_debugf_plugin("DESTROY", "wrapped=%p", self ? (void *)self->wrapped : NULL);
    if (self->wrapped != NULL) {
      grpc_call_credentials_release(self->wrapped);
    }
    Safefree(self);
