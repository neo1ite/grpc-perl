#ifndef GRPC_PERL_SERVER_H
#define GRPC_PERL_SERVER_H

#include <grpc/grpc.h>

typedef struct {
  grpc_server *wrapped;
  grpc_completion_queue *call_cq;
  grpc_completion_queue *shutdown_cq;
  int started;
  int has_listener;
} ServerCTX;

typedef ServerCTX* Grpc__XS__Server;

#endif
