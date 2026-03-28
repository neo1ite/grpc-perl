package Grpc::XS::ServerCredentials;
use strict;
use warnings;

use Grpc::XS;
use Grpc::XS::BuildConfig ();

sub _server_disabled {
    require Carp;
    Carp::croak(
        "Grpc::XS server support is disabled in this build; ".
        "rebuild with --enable-server-experimental"
    );
}

unless (Grpc::XS::BuildConfig::SERVER_EXPERIMENTAL()) {
    no strict 'refs';
    for my $name (qw(
        createSsl
        createXds
    )) {
        *{$name} = \&_server_disabled unless __PACKAGE__->can($name);
    }
}

1;
