
#=============================
package POE::Component::TFTPd;
#=============================

use warnings;
use strict;
use POE::Component::TFTPd::Client;
use POE qw/Wheel::UDP Filter::Stream/;

our $VERSION = '0.01';
our %TFTP_ERROR = (
    not_defined         => [0, "Not defined, see error message"],
    unknown_opcode      => [0, "Unknown opcode: %s"],
    no_connection       => [0, "No connection"],
    file_not_found      => [1, "File not found"],
    access_violation    => [2, "Access violation"],
    disk_full           => [3, "Disk full or allocation exceeded"],
    illegal_operation   => [4, "Illegal TFTP operation"],
    unknown_transfer_id => [5, "Unknown transfer ID"],
    file_exists         => [6, "File already exists"],
    no_suck_user        => [7, "No such user"],
);


sub check { #=================================================================

    my $self    = $_[OBJECT];
    my $kernel  = $_[KERNEL];
    my $clients = $self->clients;

    CLIENT:
    for my $client (values %$clients) {
        if($client->retries <= 0) {
            delete $clients->{ $client->id };
            $self->log(info => $client, 'timeout');
        }
        if($client->timestamp < time - $self->timeout) {
            $client->retries--;
            $self->log(trace => $client, 'retry');
            $kernel->post($self->sender => tftpd_send => $client);
        }
    }

    ### check again later
    $kernel->delay(check_connections => 1);

    return;
}

sub send_error { #============================================================

    my $self   = $_[OBJECT];
    my $client = $_[ARG0];
    my $key    = $_[ARG1];
    my $args   = $_[ARG2] || [];
    my $error  = $TFTP_ERROR{$key} || $TFTP_ERROR{'not_defined'};

    $self->log(error => $client, sprintf($error->[1], @$args));
    delete $self->clients->{$client->id};
 
    $self->server->put({
        addr    => $client->address,
        port    => $client->port,
        payload => [pack("nnZ*", &TFTP_OPCODE_ERROR, @$error)],
    });

    return;
}

sub send_data { #=============================================================

    my $self   = $_[OBJECT];
    my $kernel = $_[KERNEL];
    my $client = $_[ARG0];
    my $data   = $_[ARG1];
    my $n      = $client->last_ack + 1;

    ### send data
    my $bytes = $self->server->put({
        addr    => $client->address,
        port    => $client->port,
        payload => [pack("nna*", &TFTP_OPCODE_DATA, $n, $data)],
    });

    ### success
    if($bytes) {
        $self->log(trace => $client, "packet $n transmitted");
        $client->retries   = $self->retries;
        $client->timestamp = time;
    }

    ### error
    elsif($client->retries) {
        $client->retries--;
        $self->log(warning => $client, "failed to transmit packet $n");
        $kernel->yield(send_data => $client, $data);
    }

    return;
}

sub completed { #=============================================================

    my $self   = $_[OBJECT];
    my $kernel = $_[KERNEL];
    my $client = $_[ARG0];

    $self->log(trace => $client, 'client completed');
    delete $self->clients->{ $client->id };

    return;
}

sub init_request { #==========================================================

    my $self     = $_[OBJECT];
    my $kernel   = $_[KERNEL];
    my $client   = $_[ARG0];
    my $datagram = $_[ARG1];

    ### too many connections
    if(my $n = $self->max_connections) {
        if(int keys %{ $self->clients } > $n) {
            $self->log(error => $client, 'too many connections');
            return;
        }
    }

    ### decode input
    my($file, $mode, @rfc) = split("\0", $datagram);

    $client->filename  = $file;
    $client->mode      = uc $mode;
    $client->rfc       = \@rfc;
    $client->timestamp = time;

    ### this server only supports OCTET mode
    if($client->mode ne 'OCTET') {
        $self->log(error => $client, 'mode not supported');
        $kernel->yield(send_error => $client, 'illegal_operation');
        return;
    }

    $self->log(info => $client, "rrw/rrq $file");

    return;
}

sub input { #=================================================================

    my $self      = $_[OBJECT];
    my $kernel    = $_[KERNEL];
    my $args      = $_[ARG0];
    my $client_id = join ":", $args->{'addr'}, $args->{'port'};
    my $client    = $self->clients->{$client_id};

    my($opcode, $datagram) = unpack "na*", shift @{ $args->{'payload'} };

    if($opcode eq &TFTP_OPCODE_RRQ or $opcode eq &TFTP_OPCODE_WRQ) {
        $client = POE::Component::TFTPd::Client->new($self, $args);
        $self->clients->{$client_id} = $client;
        $kernel->yield(init_request => $client, $datagram);

        if($opcode eq &TFTP_OPCODE_RRQ) {
            $kernel->post($self->sender => tftpd_init => $client);
            $kernel->post($self->sender => tftpd_send => $client);
        }
    }

    elsif($opcode == &TFTP_OPCODE_ACK) {
        if($client) {
            $client->last_ack = unpack("n", $datagram);
            $self->log(trace => $client, "last ack=" .$client->last_ack);
            $kernel->post($self->sender => tftpd_send => $client);
        }
        else {
            $client = POE::Component::TFTPd::Client->new($self, $args);
            $kernel->yield(send_error => $client, 'no_connection');
        }
    }

    elsif($opcode eq &TFTP_OPCODE_ERROR) {
        $self->log(error => $client, $datagram);
    }

    else {
        $kernel->yield(send_error => $client, 'unknown_opcode', [$opcode]);
    }

    return;
}

sub start { #=================================================================

    my $self   = $_[OBJECT];
    my $kernel = $_[KERNEL];

    $self->{'_sender'} = $_[SENDER];
    $self->{'_kernel'} = $_[KERNEL];
    $self->{'_server'} = POE::Wheel::UDP->new(
                             Filter     => POE::Filter::Stream->new,
                             LocalAddr  => $self->localaddr,
                             LocalPort  => $self->port,
                             InputEvent => 'input',
                         );

    return;
}

sub stop { #==================================================================
    return delete $_[OBJECT]->{'_server'};
}

sub create { #================================================================

    my $class = shift;
    my %args  = @_;
    my $self  = bless \%args, $class;

    $self->{'alias'}    ||= 'TFTPd';
    $self->{'timeout'}  ||= 60;
    $self->{'retries'}  ||= 10;
    $self->{'_clients'}   = {};
    $self->{'_localaddr'} = delete $self->{'localaddr'};
    $self->{'_port'}      = delete $self->{'port'};

    ### check required args
    unless($self->localaddr and $self->port) {
        die "Missing localaddr + port self\n";
    }

    ### setup session
    POE::Session->create(
        inline_states => {
            _start => sub {
                my $kernel = $_[KERNEL];
                $kernel->alias_set($self->{'alias'});
                $kernel->delay(check_connections => 1);
            },
        },
        object_states => [
            $self => [ qw/
                start      stop
                send_data  send_error
                input      init_request
                check      completed
            / ],
        ],
    );

    return $self;
}

sub log { #===================================================================
    my $self = shift;
    $self->kernel->post($self->sender => tftpd_log => @_);
}

sub TFTP_MIN_BLKSIZE  { return 512;  }
sub TFTP_MAX_BLKSIZE  { return 1428; }
sub TFTP_MIN_TIMEOUT  { return 1;    }
sub TFTP_MAX_TIMEOUT  { return 60;   }
sub TFTP_DEFAULT_PORT { return 69;   }
sub TFTP_OPCODE_RRQ   { return 1;    }
sub TFTP_OPCODE_WRQ   { return 2;    }
sub TFTP_OPCODE_DATA  { return 3;    }
sub TFTP_OPCODE_ACK   { return 4;    }
sub TFTP_OPCODE_ERROR { return 5;    }
sub TFTP_OPCODE_OACK  { return 6;    }

BEGIN {
    no strict 'refs';

    my @lvalue = qw/retries timeout max_connections/;
    my @get    = qw/localaddr port clients server sender kernel/;

    for my $sub (@lvalue) {
        *$sub = sub :lvalue { shift->{$sub} };
    }

    for my $sub (@get) {
        *$sub = sub { return shift->{"_$sub"} };
    }
}

#=============================================================================
1983;
__END__

=head1 NAME

POE::Component::TFTPd - Starts a tftp-server, through POE

=head1 VERSION

0.01

=head1 METHODS

=head2 create(%args)

Component constructor.

Args:

 address        =>
 port           =>
 timeout        =>
 retries        =>
 alias          => 
 max_connection => 

=head2 clients

Returns a hash-ref, containing all the clients:

 $client_id => $client_obj

=head2 server

Returns the server.

=head2 retries

Pointer to the number of retries:

 print $self->retries;
 $self->retries = 4;

=head2 timeout

Pointer to the timeout in seconds:

 print $self->timeout;
 $self->timeout = 4;

=head2 max_connections

Pointer to max number of concurrent clients:

 print $self->max_connections;
 $self->max_connections = 4;

=head2 log

Calls the SENDER with event name 'tftpd_log' and these arguments:

  $_[ARG0] = $level
  $_[ARG1] = $client
  $_[ARG2] = $msg

C<$level> is the same as C<Log::Log4perl> use

=head1 EVENTS

=head2 start

Starts the server, by setting up:

 * POE::Wheel::UDP
 * Postback for logging
 * Postback for getting data

=head2 stop

Stops the TFTPd server.

=head2 input

Takes some input, figure out the opcode and pass the request on to the next
stage.

 rrq/rrw: init_request in current sesssion.
 ack:     tftpd_data in sender session.

=head2 init_request

Checks if max_connection limit is reached. If not, sets up

  $client->filename  = $file;    # the filename to read/write
  $client->mode      = uc $mode; # only OCTET is valid
  $client->rfc       = [ ... ];
  $client->timestamp = time;

=head2 check

Checks for connections that have timed out, and destroys them.

=head2 send_data($client, $data)

Sends data to the client.

=head2 send_error($client, $error_key)

Sends an error to the client.

=head2 completed

Logs that the server is done with the client, and deletes the client from
C<$self-E<gt>clients>.

=head1 FUNCTIONS

=head2 TFTP_MIN_BLKSIZE

=head2 TFTP_MAX_BLKSIZE

=head2 TFTP_MIN_TIMEOUT

=head2 TFTP_MAX_TIMEOUT

=head2 TFTP_DEFAULT_PORT

=head2 TFTP_OPCODE_RRQ

=head2 TFTP_OPCODE_WRQ

=head2 TFTP_OPCODE_DATA

=head2 TFTP_OPCODE_ACK

=head2 TFTP_OPCODE_ERROR

=head2 TFTP_OPCODE_OACK

=head1 TODO

 * Handle write requests

=head1 AUTHOR

Jan Henning Thorsen, C<< <pm at flodhest.net> >>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Component::TFTPd

You can also look for information at: L<http://trac.flodhest.net/pm>

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2007 Jan Henning Thorsen, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
