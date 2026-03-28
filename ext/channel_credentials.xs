Grpc::XS::ChannelCredentials
createDefault()
  PREINIT:
    ChannelCredentialsCTX* ctx = (ChannelCredentialsCTX *)malloc(sizeof(ChannelCredentialsCTX));
  CODE:
    ctx->wrapped = grpc_perl_google_default_credentials_create();
    RETVAL = ctx;
  OUTPUT: RETVAL

Grpc::XS::ChannelCredentials
createSsl(...)
  PREINIT:
    ChannelCredentialsCTX* ctx = (ChannelCredentialsCTX *)malloc(sizeof(ChannelCredentialsCTX));
    const char* pem_root_certs = NULL;
    grpc_ssl_pem_key_cert_pair pem_key_cert_pair;
    int i;
    int positional = 0;
    int offset = 0;
  CODE:
    ctx->wrapped = NULL;
    pem_key_cert_pair.private_key = NULL;
    pem_key_cert_pair.cert_chain = NULL;

    if (items == 3 || items == 4) {
      positional = 1;
      offset = (items == 4) ? 1 : 0;
    }
    else {
      offset = (items % 2 == 1) ? 1 : 0;
      if (((items - offset) % 2) != 0) {
        Safefree(ctx);
        croak("Expecting createSsl(pem_root_certs, pem_private_key, pem_cert_chain) or named arguments");
      }
    }

    if (positional) {
      if (SvOK(ST(offset))) {
        pem_root_certs = SvPV_nolen(ST(offset));
      }
      if (SvOK(ST(offset + 1))) {
        pem_key_cert_pair.private_key = SvPV_nolen(ST(offset + 1));
      }
      if (SvOK(ST(offset + 2))) {
        pem_key_cert_pair.cert_chain = SvPV_nolen(ST(offset + 2));
      }
    }
    else {
      for (i = offset; i < items; i += 2) {
        const char *key = SvPV_nolen(ST(i));
        if (!strcmp(key, "pem_root_certs")) {
          if (SvOK(ST(i+1))) pem_root_certs = SvPV_nolen(ST(i+1));
        } else if (!strcmp(key, "pem_private_key")) {
          if (SvOK(ST(i+1))) pem_key_cert_pair.private_key = SvPV_nolen(ST(i+1));
        } else if (!strcmp(key, "pem_cert_chain")) {
          if (SvOK(ST(i+1))) pem_key_cert_pair.cert_chain = SvPV_nolen(ST(i+1));
        }
      }
    }

    ctx->wrapped = grpc_perl_ssl_credentials_create(
      pem_root_certs,
      pem_key_cert_pair.private_key == NULL ? NULL : &pem_key_cert_pair
    );

    if (ctx->wrapped == NULL) {
      Safefree(ctx);
      croak("failed to create SSL channel credentials");
    }

    RETVAL = ctx;
  OUTPUT: RETVAL

Grpc::XS::ChannelCredentials
createComposite(Grpc::XS::ChannelCredentials cred1, Grpc::XS::CallCredentials cred2)
  PREINIT:
    ChannelCredentialsCTX* ctx = (ChannelCredentialsCTX *)malloc(sizeof(ChannelCredentialsCTX));
  CODE:
    ctx->wrapped = grpc_composite_channel_credentials_create(
      cred1->wrapped,
      cred2->wrapped,
      NULL
    );
    RETVAL = ctx;
  OUTPUT: RETVAL

Grpc::XS::ChannelCredentials
createInsecure()
  CODE:
    XSRETURN_UNDEF;
  OUTPUT:

void
DESTROY(Grpc::XS::ChannelCredentials self)
  CODE:
    if (self->wrapped != NULL) {
      grpc_channel_credentials_release(self->wrapped);
    }
    Safefree(self);
