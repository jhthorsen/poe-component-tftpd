#!perl

use strict;
use warnings;
use FindBin;
use POE;
use lib "$FindBin::Bin/../lib";
use POE::Component::TFTPd qw/TFTP_OPCODE_RRQ TFTP_OPCODE_WRQ/;

my $localaddr = '127.0.0.1';
my $port      = 9876;
my $alias     = 'TFTPd';

POE::Session->create(
    inline_states => {
        _start        => \&start,
        tftpd_init    => \&init,
        tftpd_done    => \&done,
        tftpd_send    => \&send,
        tftpd_receive => \&receive,
        tftpd_log     => \&logger,
    },
);

exit POE::Kernel->run;


sub init { #==================================================================

    my $client = $_[ARG0];
    my $fh;

    if($client->rrq) {
        open($fh, "<", "$FindBin::Bin/tftpd.pl");
    }
    elsif($client->wrq) {
        open($fh, ">", "/tmp/poco_tftpd.tmp");
    }

    $client->{'fh'} = $fh;

    return;
}

sub done { #==================================================================
    my $client = $_[ARG0];
    close $client->{'fh'};
    return;
}

sub send { #==================================================================

    my $self   = $_[OBJECT];
    my $kernel = $_[KERNEL];
    my $client = $_[ARG0];
    my $data;

    seek $client->{'fh'}, 0, $client->last_block * $client->block_size;
    read $client->{'fh'}, $data, $client->block_size;

    ### send data
    if($data) {
        $kernel->post($alias => send_data => $client, $data);
    }

    return;
}

sub receive { #===============================================================

    my $self   = $_[OBJECT];
    my $kernel = $_[KERNEL];
    my $client = $_[ARG0];
    my $data   = $_[ARG1];

    seek $client->{'fh'}, 0, $client->last_block * $client->block_size;
    print { $client->{'fh'} } $data;

    $kernel->post($alias => send_ack => $client);

    return;
}

sub logger { #================================================================

    my $level  = $_[ARG0] || shift;
    my $client = $_[ARG1] || shift;
    my $msg    = $_[ARG2] || shift;

    if(ref $client) {
        warn(sprintf "%s - %s:%i - %s\n",
            $level,
            $client->address,
            $client->port,
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
    );

    logger(info => undef, 'Starting server');
    $kernel->post($alias => 'start');

    return;
}

