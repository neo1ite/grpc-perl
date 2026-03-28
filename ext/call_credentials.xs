Grpc::XS::CallCredentials
createComposite(cred1, cred2)
    Grpc::XS::CallCredentials cred1
    Grpc::XS::CallCredentials cred2
  PREINIT:
    CallCredentialsCTX* ctx = (CallCredentialsCTX *)malloc( sizeof(CallCredentialsCTX) );
  CODE:
    ctx->wrapped = grpc_composite_call_credentials_create(
                                cred1->wrapped, cred2->wrapped, NULL);
    RETVAL = ctx;
  OUTPUT: RETVAL

Grpc::XS::CallCredentials
createFromPlugin(callback)
    SV* callback
  PREINIT:
    CallCredentialsCTX* ctx = (CallCredentialsCTX *)malloc(sizeof(CallCredentialsCTX));
    grpc_metadata_credentials_plugin plugin;
  CODE:
    ctx->wrapped = NULL;
    Zero(&plugin, 1, grpc_metadata_credentials_plugin);

    plugin.get_metadata = plugin_get_metadata;
    plugin.destroy      = plugin_destroy_state;
    plugin.state        = (void *)SvRV(callback);
    plugin.type         = "";

    ctx->wrapped = grpc_perl_metadata_credentials_create_from_plugin(plugin);

    SvREFCNT_inc(callback);
    RETVAL = ctx;
  OUTPUT: RETVAL

void
DESTROY(Grpc::XS::CallCredentials self)
  CODE:
    if (self->wrapped != NULL) {
      grpc_call_credentials_release(self->wrapped);
    }
    Safefree(self);
