#!perl

use strict;
use warnings;
use FindBin;
use POE;
use lib "$FindBin::Bin/../lib";
use POE::Component::TFTPd;

my $localaddr = '127.0.0.1';
my $port      = 9876;
my $alias     = 'TFTPd';

POE::Session->create(
    inline_states => {
        _start => \&start,
        get    => \&get,
        log    => \&logger,
    },
);

exit POE::Kernel->run;

sub get { #===================================================================

    my $kernel = $_[KERNEL];
    my $client = $_[ARG0];

    $kernel->post($alias => 'send_data' => 'foo');
    return;
}

sub logger { #================================================================

    my $level  = $_[ARG0] || shift;
    my $client = $_[ARG1] || shift;
    my $msg    = $_[ARG2] || shift;

    if(ref $client) {
        warn(sprintf "%s - %s:%i - %s\n",
            $level,
            $client->{'address'},
            $client->{'port'},
            $msg,
        );
    }
    else {
        warn "$level - $msg\n";
    }

    return;
}

sub start { #=================================================================

    my $kernel = $_[KERNEL];

    POE::Component::TFTPd->create(
        localaddr => $localaddr,
        port      => $port,
        alias     => $alias,
        states    => {
            log      => 'log',
            get_data => 'get',
        },
    );

    logger(info => undef, 'Starting server');
    $kernel->post($alias => 'start');

    return;
}
