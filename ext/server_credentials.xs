Grpc::XS::ServerCredentials
createInsecure(...)
  PREINIT:
    ServerCredentialsCTX *ctx = (ServerCredentialsCTX *)malloc(sizeof(ServerCredentialsCTX));
  CODE:
    ctx->wrapped = grpc_perl_insecure_server_credentials_create();

    grpc_perl_debugf_server_credentials(
      "createInsecure",
      "wrapped=%p",
      (void *)ctx->wrapped
    );

    if (ctx->wrapped == NULL) {
      Safefree(ctx);
      croak("insecure server credentials are unavailable in this gRPC build");
    }

    RETVAL = ctx;
  OUTPUT: RETVAL

Grpc::XS::ServerCredentials
createSsl(...)
  PREINIT:
    ServerCredentialsCTX *ctx = (ServerCredentialsCTX *)malloc(sizeof(ServerCredentialsCTX));
    const char *pem_root_certs = NULL;
    grpc_ssl_pem_key_cert_pair pem_key_cert_pair;
    STRLEN pem_root_len = 0;
    STRLEN pem_key_len = 0;
    STRLEN pem_cert_len = 0;
    int positional = 0;
    int offset = 0;
    int i;
  CODE:
    ctx->wrapped = NULL;
    pem_key_cert_pair.private_key = NULL;
    pem_key_cert_pair.cert_chain = NULL;

    if (items == 3 || items == 4) {
      positional = 1;
      offset = (items == 4) ? 1 : 0;
    } else {
      offset = (items % 2 == 1) ? 1 : 0;
      if (((items - offset) % 2) != 0) {
        Safefree(ctx);
        croak("Expecting createSsl(pem_root_certs, pem_private_key, pem_cert_chain) or named arguments");
      }
    }

    if (positional) {
      if (SvOK(ST(offset))) {
        pem_root_certs = SvPV(ST(offset), pem_root_len);
      }
      if (SvOK(ST(offset + 1))) {
        pem_key_cert_pair.private_key = SvPV(ST(offset + 1), pem_key_len);
      }
      if (SvOK(ST(offset + 2))) {
        pem_key_cert_pair.cert_chain = SvPV(ST(offset + 2), pem_cert_len);
      }
    } else {
      for (i = offset; i < items; i += 2) {
        const char *key = SvPV_nolen(ST(i));
        if (!strcmp(key, "pem_root_certs")) {
          if (SvOK(ST(i + 1))) {
            pem_root_certs = SvPV(ST(i + 1), pem_root_len);
          }
        }
        else if (!strcmp(key, "pem_private_key")) {
          if (SvOK(ST(i + 1))) {
            pem_key_cert_pair.private_key = SvPV(ST(i + 1), pem_key_len);
          }
        }
        else if (!strcmp(key, "pem_cert_chain")) {
          if (SvOK(ST(i + 1))) {
            pem_key_cert_pair.cert_chain = SvPV(ST(i + 1), pem_cert_len);
          }
        }
        else {
          grpc_perl_debugf_server_credentials("createSsl", "ignoring unknown key=%s", key);
        }
      }
    }

    grpc_perl_debugf_server_credentials(
      "createSsl",
      "positional=%d root_len=%lu key_len=%lu cert_len=%lu",
      positional,
      (unsigned long)pem_root_len,
      (unsigned long)pem_key_len,
      (unsigned long)pem_cert_len
    );

    if ((pem_key_cert_pair.private_key == NULL) != (pem_key_cert_pair.cert_chain == NULL)) {
      Safefree(ctx);
      croak("pem_private_key and pem_cert_chain must be provided together");
    }

    if (pem_key_cert_pair.private_key == NULL || pem_key_cert_pair.cert_chain == NULL) {
      Safefree(ctx);
      croak("server SSL credentials require pem_private_key and pem_cert_chain");
    }

    ctx->wrapped = grpc_perl_ssl_server_credentials_create(
      pem_root_certs,
      &pem_key_cert_pair
    );

    grpc_perl_debugf_server_credentials(
      "createSsl",
      "wrapped=%p",
      (void *)ctx->wrapped
    );

    if (ctx->wrapped == NULL) {
      Safefree(ctx);
      croak("failed to create SSL server credentials");
    }

    RETVAL = ctx;
  OUTPUT: RETVAL

void
DESTROY(Grpc::XS::ServerCredentials self)
  CODE:
    if (self != NULL) {
      grpc_perl_debugf_server_credentials("DESTROY", "wrapped=%p", self->wrapped);
      if (self->wrapped != NULL) {
        grpc_server_credentials_release(self->wrapped);
      }
      Safefree(self);
    }
