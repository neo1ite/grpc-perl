#!perl -w
use strict;
use Test::More;
use Grpc::XS::BuildConfig ();

plan tests => Grpc::XS::BuildConfig::SERVER_EXPERIMENTAL() ? 16 : 14;

use_ok('Grpc::Client::AbstractCall');
use_ok('Grpc::Client::BaseStub');
use_ok('Grpc::Client::BidiStreamingCall');
use_ok('Grpc::Client::ClientStreamingCall');
use_ok('Grpc::Client::ServerStreamingCall');
use_ok('Grpc::Client::UnaryCall');
use_ok('Grpc::Constants');
use_ok('Grpc::XS::Server') if Grpc::XS::BuildConfig::SERVER_EXPERIMENTAL();
use_ok('Grpc::XS::ServerCredentials') if Grpc::XS::BuildConfig::SERVER_EXPERIMENTAL();
use_ok('Grpc::XS');
use_ok('Grpc::XS::Call');
use_ok('Grpc::XS::CallCredentials');
use_ok('Grpc::XS::Channel');
use_ok('Grpc::XS::ChannelCredentials');
use_ok('Grpc::XS::Constants');
use_ok('Grpc::XS::Timeval');
