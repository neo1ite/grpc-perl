#ifndef GRPC_PERL_CALL_H
#define GRPC_PERL_CALL_H

#include <grpc/grpc.h>

typedef struct {
  grpc_call *wrapped;
  grpc_completion_queue *cq;
} CallCTX;

typedef CallCTX* Grpc__XS__Call;

#endif
