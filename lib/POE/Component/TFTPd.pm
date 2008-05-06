
#=============================
package POE::Component::TFTPd;
#=============================

use warnings;
use strict;
use POE::Component::TFTPd::Client;
use POE qw/Wheel::UDP Filter::Stream/;

our $VERSION = '0.01';


sub check_connections { #=====================================================

    my $kernel  = $_[KERNEL];
    my $clients = $_[OBJECT]->clients;

    CLIENT:
    for my $client (values %$clients) {
        if($client->retries <= 0) {
            delete $clients->{ $client->id };
            $self->log(info => $client, 'timeout');
        }
        if($client->timestamp < time - $self->timeout) {
            $client->retries--;
            $self->log(trace => $client, 'retry');
            $kernel->yield(prepare_packet => $client);
        }
    }

    ### check again later
    $kernel->delay(check_connections => 1);
}

sub send_error { #============================================================

    my $self   = $_[OBJECT];
    my $client = $_[ARG0];
    my $err    = $_[ARG1];
    my $errors = {
        mode_not_supported => [0, 'Transfere mode is not supported'],
    };

    $self->log(error => $client, $errors->{$err}[1]);

    delete $self->clients->{$client->id};
 
    return $self->server->put(
        addr    => $client->address,
        port    => $client->port,
        payload => pack("nnZ*", &TFTP_OPCODE_ERROR, @{ $errors->{$err} }),
    );
}

sub send_data { #=============================================================

    my $client = $_[ARG0];
    my $data   = $_[ARG1];
    my $n      = $client->last_ack + 1;
 
    ### send data
    my $bytes = $_[OBJECT]->server->put(
        addr    => $client->address,
        port    => $client->port,
        payload => pack("nna*", &TFTP_OPCODE_DATA, $n, $data),
    );

    ### success
    if($bytes) {
        $self->log(warning => $client, 'error sending data');
        $client->seek_pos($client->seek_to);
        $client->block_count++;
    }

    ### error
    else {
        $self->log(warning => $client, 'error sending data');
        $client->retries--;
    }
}

sub prepare_packet { #========================================================

    my $self   = $_[OBJECT];
    my $kernel = $_[KERNEL];
    my $client = $_[ARG0];

    ### this server only supports OCTET mode
    if($client->mode ne 'OCTET') {
        $kernel->yield(send_error => $client, 'mode_not_supported');
        return;
    }

    ### need to get last ack, before sending more data
    if($client->last_ack < $client->block_count) {
        $self->log(trace => $client, 'waiting for ack');
        $kernal->yield(prepare_packet => $client);
        return;
    }

    ### get data and hopefully a postback to this session
    $self->get_data->($client);
    return;
}

sub decode { #================================================================

    my $kernel  = $_[KERNEL];
    my $client  = $_[ARG0];
    my $payload = $_[ARG1];

    ### decode the message
    my($opcode, $datagram) = unpack("na*", $payload);

    ### ACK
    if($opcode eq &TFTP_OPCODE_ACK) {
        my $this_ACK      = unpack("n", $datagram);
        $client->last_ack = $this_ACK;

        ### done
        if($this_ACK == $client->last_block) {
            $self->log(info => $client, 'completed');
            delete $self->clients->{ $client->id };
        }

        ### more acks than expected
        elsif($this_ACK > $client->last_block) {
            $self->log(warning => $client, 'ack overflow');
            delete $self->clients->{ $client->id };
        }

        ### normal ack
        else {
            $self->log(trace => $client, "ack# $this_ACK");
            $client->timestamp = time;
            $client->retries   = $self->retries;
            $kernel->yield(prepare_packet => $client);
        }
    }

    ### error
    elsif($opcode eq &TFTP_OPCODE_ERROR) {
        $self->log(error => sprintf "client-error: %s", $datagram);
    }

    ### other
    else {
        $self->log(error => sprintf "client-error: %s", $datagram);
    }

    return;
}

sub new_connection { #========================================================

    my $self    = $_[OBJECT];
    my $client  = $_[ARG0];
    my $payload = $_[ARG1];

    ### too many connections
    if(my $n = $self->{'max_connections'}) {
        if(int keys %{ $self->clients } > $n) {
            $self->log(error => $client, 'too many connections');
            return;
        }
    }

    ### decode input
    my($opcode, $datagram) = unpack("na*", $payload);
    my($file, $mode, @rfc) = split("\0", $datagram);

    $client->opcode($opcode);
    $client->mode(uc $mode);
    $client->filename($file);
    $client->timestamp(time);

    return;
}

sub input { #=================================================================

    my $kernel    = $_[KERNEL];
    my $args      = $_[ARG0];
    my $client_id = join ":", $args->{'address'}, $args->{'port'};
    my $client    = $self->clients->{$client_id};

    ### new connection
    unless($client) {
        $client = POE::Component::TFTPd::Client->new($args);
        $self->clients->{$client_id} = $client;
        $kernel->yield(new_connection => $client, $args->{'payload'});
    }

    ### existing connection
    else {
        $kernel->yield(decode => $client, $args->{'payload'});
    }

    return;
}

sub start { #=================================================================

    my $self   = $_[OBJECT];
    my $kernel = $_[KERNEL];
    my $sender = $_[SENDER];
    my $events = $self->{'events'};

    ### set default events
    $events->{'log'}      ||= 'log';
    $events->{'get_data'} ||= 'get_data';

    $self->{'_log'}      = sub { $kernel->post(
                               $sender, $events->{'log'} => @_
                           ) };
    $self->{'_get_data'} = sub { $kernel->post(
                               $sender, $events->{'get_data'} => @_
                           ) };
    $self->{'_server'}   = POE::Wheel::UDP->new(
                               Filter     => $filter,
                               LocalAddr  => $self->{'localaddr'},
                               LocalPort  => $self->{'port'},
                               InputEvent => 'input',
                           );

    return;
}

sub stop { #==================================================================
    return delete $_[OBJECT]->{'_server'};
}

sub create { #================================================================

    my $class  = shift;
    my %args   = shift;
    my $self   = bless \%args, $class;
    my $filter = POE::Filter::Stream->new;

    $self->{'_clients'} = {};
    $self->{'_server'}  = undef;
    $self->{'alias'}  ||= 'TFTPd';

    ### check required args
    unless($self->{'localaddr'} and $self->{'port'}) {
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
                start           stop
                new_connection  check_connections
                input           decode
                send_data       send_error
                prepare_packet 
            / ],
        ],
    );

    return $self;
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
    my @lvalue = qw/retries timeout/;
    my @get    = qw/clients server get_data log/;

    for(@lvalue) {
        *$_ = sub :lvalue { shift->{$_} };
    }

    for(@get) {
        *$_ = sub { return shift->{"_$_"} };
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

 address =>
 port    =>
 timeout =>
 retries =>
 alias   => 
 events  => {
    log      =>
    get_data => 
 },

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

=head2 get_data

Calls the SENDER with event name C<$arg-E<gt>{'events'}{'get_data'}>
and $client as $_[ARG0].

The SENDER should then post back:

 $kernel->post($alias => $client, $data);

=head2 log

Calls the SENDER with event name C<$arg-E<gt>{'events'}{'log'}> and these
arguments:

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

=head2 check_connections

Checks for connections that have timed out, and destroys them.

=head2 prepare_packet($client)

Reads a some data, using C<get_data()>.

=head2 send_data($client, $data)

Sends data to the client.

=head2 send_error($client, $error_key)

Sends an error to the client.

=head2 input

Takes some input, and pass it on to either C<new_connection()> or C<decode()>,
dependent if the client exists or not.

=head2 new_connection

Creates a new client-object, and puts it into the C<$self-E<gt>clients> hash.

=head2 decode

Decodes the messages from the client. It can only handle ACKs for now.

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

 * Handle more than ACK messages.

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
