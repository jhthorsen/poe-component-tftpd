
#=============================
package POE::Component::TFTPd;
#=============================

use warnings;
use strict;
use POE::Component::TFTPd::Client;
use POE qw/Wheel::UDP Filter::Stream/;

our $VERSION    = '0.01';
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

    my $self    = $_[OBJECT];
    my $kernel  = $_[KERNEL];
    my $client  = $_[ARG0];
    my($opname) = $_[STATE] =~ /send_(\w+)/; # data/ack
    my($opcode, $data, $n, $done);

    if($opname eq 'data') {
        $opcode = &TFTP_OPCODE_DATA;
        $data   = $_[ARG1];
        $n      = $client->last_block + 1;
        $client->almost_done = length $data < $client->block_size;
    }
    elsif($opname eq 'ack') {
        $opcode = &TFTP_OPCODE_ACK;
        $data   = q();
        $n      = $client->last_block;
        $done   = $client->almost_done;
    }

    ### send data
    my $bytes = $self->server->put({
        addr    => $client->address,
        port    => $client->port,
        payload => [pack("nna*", $opcode, $n, $data)],
    });

    ### success
    if($bytes) {
        $self->log(trace => $client, "sent $opname $n");
        $client->retries   = $self->retries;
        $client->timestamp = time;
        $self->cleanup($client) if($done);
    }

    ### error
    elsif($client->retries) {
        $client->retries--;
        $self->log(warning => $client, "failed to transmit $opname $n");
        $kernel->yield("send_$opname" => $client);
    }

    return;
}

sub get_data { #==============================================================

    my $self      = $_[OBJECT];
    my $kernel    = $_[KERNEL];
    my $client    = $_[ARG0];
    my($opname)   = $_[STATE] =~ /get_(\w+)/; # data/ack
    my($n, $data) = unpack("na*", $_[ARG1]);
    my($this_state, $sender_state, $done);

    if($opname eq 'data') {
        $sender_state        = 'tftpd_receive';
        $this_state          = 'send_ack';
        $client->almost_done = length $data < $client->block_size;
    }
    elsif($opname eq 'ack') {
        $sender_state = 'tftpd_send';
        $this_state   = 'send_data';
        $done         = $client->almost_done;
    }

    ### get data
    if($n == $client->last_block + 1) {
        $client->last_block ++;
        $self->log(trace => $client, "got $opname $n");
        $kernel->post($self->sender => $sender_state => $client, $data);
        $self->cleanup($client) if($done);
    }

    ### wrong block number
    else {
        $self->log(trace => $client, sprintf(
            "wrong %s %i (%i)", $opname, $n, $client->last_block + 1,
        ));
        $kernel->yield($this_state => $client);
    }

    return;
}

sub init_request { #==========================================================

    my $self      = $_[OBJECT];
    my $kernel    = $_[KERNEL];
    my $args      = $_[ARG0];
    my $opcode    = $_[ARG1];
    my $datagram  = $_[ARG2];
    my($opname)   = $_[STATE] =~ /init_(\w+)/;
    my $client_id = join ":", $args->{'addr'}, $args->{'port'};
    my($client, $file, $mode, @rfc);

    ### too many connections
    if(my $n = $self->max_clients) {
        if(int keys %{ $self->clients } > $n) {
            $self->log(error => $client, 'too many connections');
            return;
        }
    }

    ### create client
    $client = POE::Component::TFTPd::Client->new($self, $args);
    $self->clients->{$client_id} = $client;

    ### decode input
    ($file, $mode, @rfc) = split("\0", $datagram);
    $client->filename    = $file;
    $client->mode        = uc $mode;
    $client->rfc         = \@rfc;
    $client->timestamp   = time;

    ### this server only supports OCTET mode
    if($client->mode ne 'OCTET') {
        $self->log(error => $client, 'mode not supported');
        $kernel->yield(send_error => $client, 'illegal_operation');
        return;
    }

    $self->log(info => $client, "$opname $file");

    ### tell sender about the new request
    $kernel->post($self->sender => tftpd_init => $client);

    ### send data
    if($opcode == &TFTP_OPCODE_RRQ) {
        $kernel->post($self->sender => tftpd_send => $client);
        $client->rrq = 1;
    }

    ### receive data
    else {
        $kernel->yield(send_ack => $client);
        $client->wrq = 1;
    }

    return;
}

sub input { #=================================================================

    my $self           = $_[OBJECT];
    my $kernel         = $_[KERNEL];
    my $args           = $_[ARG0];
    my $client_id      = join ":", $args->{'addr'}, $args->{'port'};
    my($opcode, $data) = unpack "na*", shift @{ $args->{'payload'} };

    ### init new connection
    if($opcode eq &TFTP_OPCODE_RRQ) {
        $kernel->yield(init_rrq => $args, $opcode, $data);
        return;
    }
    elsif($opcode eq &TFTP_OPCODE_WRQ) {
        $kernel->yield(init_wrq => $args, $opcode, $data);
        return;
    }

    ### connection is established
    if(my $client = $self->clients->{$client_id}) {
        if($opcode == &TFTP_OPCODE_ACK) {
            $kernel->yield(get_ack => $client, $data);
        }
        elsif($opcode == &TFTP_OPCODE_DATA) {
            $kernel->yield(get_data => $client, $data);
        }
        elsif($opcode eq &TFTP_OPCODE_ERROR) {
            $self->log(error => $client, $data);
        }
        else {
            $kernel->yield(send_error => $client, 'unknown_opcode', [$opcode]);
        }
    }

    ### no connection
    else {
        $client = POE::Component::TFTPd::Client->new($self, $args);
        $self->log(error => $client, 'no connection');
        $kernel->yield(send_error => $client, 'no_connection');
    }
 
    return;
}

sub get_object { #============================================================
    return $_[OBJECT];
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
    $self->{'address'}  ||= '127.0.0.1';
    $self->{'port'}     ||= 69;
    $self->{'timeout'}  ||= 10;
    $self->{'retries'}  ||= 3;
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
            $self => {
                init_rrq  => 'init_request',
                init_wrq  => 'init_request',
                get_ack   => 'get_data',
                get_data  => 'get_data',
                send_ack  => 'send_data',
                send_data => 'send_data',
            },
            $self => [ qw/
                start stop get_object send_error input check
            / ],
        ],
    );

    return $self;
}

sub cleanup { #===============================================================

    my $self   = shift;
    my $client = shift;

    $self->log(trace => $client, 'done');
    delete $self->clients->{ $client->id };
    $self->kernel->post($self->sender => tftpd_done => $client);

    return;
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

    my @lvalue = qw/retries timeout max_clients/;
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

POE::Component::TFTPd - A tftp-server, implemented through POE

=head1 VERSION

0.01

=head1 SYNOPSIS

 POE::Session->create(
     inline_states => {
         _start        => sub {
             POE::Component::TFTPd->create;
             $_[KERNEL]->post($alias => 'start');
         },
         tftpd_init    => sub {
             my($client, $fh) = ($_[ARG0], undef);
             open($fh, "<", $client->filename) if($client->rrq);
             open($fh, ">", $client->filename) if($client->wrq);
             $client->{'fh'} = $fh;
         },
         tftpd_done    => sub {
             my $client = $_[ARG0];
             close $client->{'fh'};
         },
         tftpd_send    => sub {
             my $client = $_[ARG0];
             read $client->{'fh'}, my $data, $client->block_size;
             $_[KERNEL]->post($alias => send_data => $client, $data);
         },
         tftpd_receive => sub {
             my($client, $data) = @_[ARG0,ARG1];
             print { $client->{'fh'} } $data;
             $kernel->post($alias => send_ack => $client);
         },
         tftpd_log     => sub {
             my($level, $client, $msg) = @_[ARG0..ARG2];
             warn(sprintf "%s - %s:%i - %s\n",
                 $level, $client->address, $client->port, $msg,
             );
         },
     },
 );

=head1 METHODS

=head2 create(%args)

Component constructor.

Args:

 Name        => default   # Comment
 --------------------------------------------------------------------
 alias       => TFTPd     # Alias for the POE session
 address     => 127.0.0.1 # Address to listen to
 port        => 69        # Port to listen to
 timeout     => 10        # Seconds between block sent and ACK
 retries     => 3         # How many retries before giving up on host
 max_clients => undef     # Maximum concurrent connections

=head2 clients

Returns a hash-ref, containing all the clients:

 $client_id => $client_obj

See C<POE::Component::TFTPd::Client> for details

=head2 server

Returns the server: C<POE::Wheel::UDP>.

=head2 cleanup

 1. Logs that the server is done with the client
 2. deletes the client from C<$self-E<gt>clients>
 3. Calls C<tftpd_done> event in sender session

=head2 timeout

Pointer to the timeout in seconds:

 print $self->timeout;
 $self->timeout = 4;

=head2 retries

Pointer to the number of retries:

 print $self->retries;
 $self->retries = 4;

=head2 max_clients

Pointer to max number of concurrent clients:

 print $self->max_clients;
 $self->max_clients = 4;

=head2 log

Calls SENDER with event name 'tftpd_log' and these arguments:

  $_[ARG0] = $level
  $_[ARG1] = $client
  $_[ARG2] = $msg

C<$level> is the same as C<Log::Log4perl> use.

=head1 EVENTS

=head2 start

Starts the server, by setting up C<POE::Wheel::UDP>.

=head2 stop

Stops the TFTPd server, by deleting the UDP wheel.

=head2 input => $udp_wheel_args

Takes some input, figure out the opcode and pass the request on to the next
stage.

 opcode | event    | method
 -------|----------|-------------
 rrq    | init_rrq | init_request
 ack    | get_ack  | get_data
 data   | get_data | get_data

=head2 init_request => $args, $opcode, $data

 1. Checks if max_clients limit is reached. If not, sets up

  $client->filename  = $file;    # the filename to read/write
  $client->mode      = uc $mode; # only OCTET is valid
  $client->rfc       = [ ... ];
  $client->timestamp = time;

 2. Calls C<tftpd_init> in sender session.

 3. Calls C<tftpd_send> in sender session, if read-request from client

=head2 send_data => $client, $data

Sends data to the client. Used for both ACK and DATA. It resends data
automatically on failure, and decreases C<$client-E<gt>retries>.

=head2 send_error => $client, $error_key [, $args]

Sends an error to the client.

 $error_key referes to C<%TFTP_ERROR>
 $args is an array ref that can be used to replace %x in the error string

=head2 get_data => $client, $data

Handles both ACK and DATA packets.

If correct packet-number:

 1. Logs the packet number
 2. Calls C<tftpd_receive> / C<tftpd_send> in sender session

On failure:

 1. Logs failure
 2. Resends the last packet

=head2 check

Checks for connections that have timed out, and destroys them. This is done
periodically, every second.

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
