use 5.008005;
use strict;
use warnings;

use ExtUtils::MakeMaker;
use Config;
use Devel::CheckLib;
use File::Path qw(make_path);
use Getopt::Long;

Getopt::Long::Configure('pass_through');
GetOptions(
    'd'                           => \my $DEBUG,
    'grpc-prefix=s'               => \my $GRPC_PREFIX,
    'enable-server-experimental!' => \my $ENABLE_SERVER_EXPERIMENTAL,
) or die "Error in command line arguments\n";

$ENABLE_SERVER_EXPERIMENTAL = 0 if !defined $ENABLE_SERVER_EXPERIMENTAL;

my ($EXTRA_INCFLAGS, $EXTRA_DEFINES, $EXTRA_LDFLAGS);
$EXTRA_INCFLAGS = $GRPC_PREFIX ? "-I$GRPC_PREFIX/include" : '';
$EXTRA_LDFLAGS  = $GRPC_PREFIX ? "-L$GRPC_PREFIX/lib -L$GRPC_PREFIX/lib64" : '';
$EXTRA_DEFINES  = $ENABLE_SERVER_EXPERIMENTAL
    ? ' -DGRPC_PERL_ENABLE_SERVER_EXPERIMENTAL'
    : '';

my @pc_dirs = grep { defined && length && -d $_ } (
    ($GRPC_PREFIX ? "$GRPC_PREFIX/lib/pkgconfig"   : ()),
    ($GRPC_PREFIX ? "$GRPC_PREFIX/lib64/pkgconfig" : ()),
    split(/:/, ($ENV{PKG_CONFIG_PATH} // '')),
);
local $ENV{PKG_CONFIG_PATH} = join(':', @pc_dirs) if @pc_dirs;

my $PKG_CFLAGS = `pkg-config --cflags grpc 2>/dev/null`;
chomp $PKG_CFLAGS;
my $PKG_LIBS = `pkg-config --libs grpc 2>/dev/null`;
chomp $PKG_LIBS;

my $BUILD_INC  = join ' ', grep { defined && length } ($EXTRA_INCFLAGS, $PKG_CFLAGS);
my $PROBE_LIBS = join ' ', grep { defined && length } ($EXTRA_LDFLAGS, '-lgrpc');

my $CXX = $Config{cxx} || 'g++';

my @rpath_dirs = grep { defined && length && -d $_ } (
    ($GRPC_PREFIX ? "$GRPC_PREFIX/lib"   : ()),
    ($GRPC_PREFIX ? "$GRPC_PREFIX/lib64" : ()),
);

my $RPATH_FLAGS = join ' ', map { "-Wl,-rpath,$_" } @rpath_dirs;

my $BUILD_LIBS_RAW = $PKG_LIBS || join(' ', grep { defined && length } ($EXTRA_LDFLAGS, '-lgrpc'));

my $BUILD_LIBS = join ' ', grep { defined && length } (
    $RPATH_FLAGS,
    '-Wl,--no-as-needed',
    $BUILD_LIBS_RAW,
    '-lstdc++',
    '-Wl,--as-needed',
);

my %CHECKLIB_ARGS = (
    header => [
        'grpc/grpc.h',
        'grpc/credentials.h',
        'grpc/grpc_security.h',
        'grpc/slice.h',
    ],
    INC  => $BUILD_INC,
    LIBS => $PROBE_LIBS,
);

sub _probe {
    my (%args) = @_;
    return check_lib(%CHECKLIB_ARGS, %args);
}

sub _write_build_config_pm {
    my (%args) = @_;

    my $dir  = 'lib/Grpc/XS';
    my $file = "$dir/BuildConfig.pm";

    make_path($dir) unless -d $dir;

    open my $fh, '>', $file
        or die "Cannot write $file: $!";

    print {$fh} <<"EOF_PM";
package Grpc::XS::BuildConfig;

use strict;
use warnings;

our \$VERSION = '0.001';

use constant SERVER_EXPERIMENTAL => @{[ $args{server_experimental} ? 1 : 0 ]};

1;
EOF_PM

    close $fh
        or die "Cannot close $file: $!";
}

check_lib_or_exit(
    %CHECKLIB_ARGS,
    function => 'grpc_version_string();',
);

_probe(
    function => <<'EOT',
grpc_completion_queue* (*fn)(void*) = grpc_completion_queue_create_for_pluck;
return fn == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_CQ_CREATE_FOR_PLUCK');

_probe(
    function => <<'EOT',
void (*fn)(grpc_call*) = grpc_call_unref;
return fn == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_CALL_UNREF');

_probe(
    function => <<'EOT',
grpc_call *(*fn)(grpc_channel*, grpc_call*, uint32_t, grpc_completion_queue*, grpc_slice, const grpc_slice*, gpr_timespec, void*) = grpc_channel_create_call;
return fn == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_CREATE_CALL_SLICE_API');

_probe(
    function => <<'EOT',
grpc_op op;
grpc_slice details = grpc_empty_slice();
op.data.send_status_from_server.status_details = &details;
return 0;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_SEND_STATUS_DETAILS_SLICE');

_probe(
    function => <<'EOT',
grpc_op op;
char *details = NULL;
size_t details_capacity = 0;
op.data.recv_status_on_client.status_details = &details;
op.data.recv_status_on_client.status_details_capacity = &details_capacity;
return 0;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_RECV_STATUS_DETAILS_CAPACITY');

_probe(
    function => <<'EOT',
grpc_op op;
op.data.recv_status_on_client.error_string = NULL;
return 0;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_RECV_STATUS_ON_CLIENT_ERROR_STRING');

_probe(
    function => <<'EOT',
grpc_google_default_credentials_options options;
grpc_channel_credentials *(*fn)(grpc_call_credentials*, grpc_google_default_credentials_options*) = grpc_google_default_credentials_create;
return fn == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_GOOGLE_DEFAULT_CREDENTIALS_OPTIONS');

_probe(
    function => <<'EOT',
grpc_call_credentials *(*fn)(grpc_metadata_credentials_plugin, grpc_security_level, void*) = grpc_metadata_credentials_create_from_plugin;
return fn == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_METADATA_PLUGIN_MIN_SECURITY');

_probe(
    function => <<'EOT',
grpc_channel_credentials *(*fn)(const char*, grpc_ssl_pem_key_cert_pair*, const verify_peer_options*, void*) = grpc_ssl_credentials_create;
return fn == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_SSL_CREDENTIALS_FOUR_ARGS');

_probe(
    function => <<'EOT',
grpc_channel_credentials *(*fn)(void) = grpc_insecure_credentials_create;
return fn == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_INSECURE_CREDENTIALS_CREATE');

_probe(
    function => <<'EOT',
void (*p)(void) = grpc_shutdown_blocking;
return p == NULL;
EOT
) and ($EXTRA_DEFINES .= ' -DGRPC_PERL_HAS_SHUTDOWN_BLOCKING');

_write_build_config_pm(
    server_experimental => $ENABLE_SERVER_EXPERIMENTAL,
);

WriteMakefile(
    NAME               => 'Grpc::XS',
    VERSION_FROM       => 'lib/Grpc/XS.pm',
    AUTHOR             => 'Vincent van Dam',
    LD                 => $CXX,
    LIBS               => [ $BUILD_LIBS ],
    DEFINE             => $EXTRA_DEFINES,
    INC                => "$BUILD_INC -I.",
    C                  => [ 'Grpc.c', 'util.c' ],
    OBJECT             => '$(O_FILES)',
    OPTIMIZE           => $DEBUG ? '-g' : '-O2',
	PROTOTYPES         => 'DISABLE',
    CONFIGURE_REQUIRES => {
        'Devel::CheckLib' => 0,
    },
    META_MERGE => {
        resources => {
            repository => 'https://github.com/neo1ite/grpc-perl',
            bugtracker => 'https://github.com/neo1ite/grpc-perl/issues',
            homepage   => 'https://github.com/neo1ite/grpc-perl',
        },
    },
);
