
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
        }
        if($client->timestamp < time - $self->timeout) {
            $client->retries--;
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
        $self->log(trace => $client, 'waiting for ack...');
        $kernal->yield(prepare_packet => $client);
        return;
    }

    ### send data
    if(my $data = $client->read_data) {
        $kernel->yield(send_data => $client, $data);
    }
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
            $self->log($client, 'too many connections');
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
    my $input     = $_[ARG0];
    my $client_id = join ":", $input->{'address'}, $input->{'port'};
    my $client    = $self->clients->{$client_id};

    ### new connection
    unless($client) {
        $client = POE::Component::TFTPd::Client->new($input);
        $self->clients->{$client_id} = $client;
        $kernel->yield(new_connection => $client, $input->{'payload'});
    }

    ### existing connection
    else {
        $kernel->yield(decode => $client, $input->{'payload'});
    }

    return;
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

                $self->{'_server'} = POE::Wheel::UDP->new(
                                         Filter     => $filter,
                                         LocalAddr  => $self->{'localaddr'},
                                         LocalPort  => $self->{'port'},
                                         InputEvent => 'input',
                                    );

                $kernel->alias_set($self->{'alias'});
                $kernel->delay(check_connections => 1);
            },
        },
        object_states => [
            $self => [ qw/
                new_connection check_connections input log send_packet
            / ],
        ],
    );

    return $self;
}

sub clients { #===============================================================
    return shift->{'_clients'};
}

sub server { #================================================================
    return shift->{'_server'};
}

sub retries :lvalue { #=======================================================
    shift->{'retries'};
}

sub timeout :lvalue { #=======================================================
    shift->{'timeout'};
}

sub log { #===================================================================

    my $self   = shift;
    my $level  = shift;
    my $client = shift;
    my $msg    = shift;

    printf(STDERR "%s - %s:%i %s\n",
        $level,
        $client->address,
        $client->port,
        $msg,
    );

    return $msg;
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

 address
 port
 timeout
 retries
 alias

=head2 check_connections

Checks for connections that have timed out, and destroys them.

=head2 prepare_packet($client)

Reads a some data, using C<$client-E<gt>read_data> and sends it to send_data()

=head2 send_data($client, $data)

Sends data to the client.

=head2 send_error($client, $error_key)

Sends an error to the client.

=head2 input

Takes some input, and pass it on to either C<new_connection> or C<decode()>,
dependent if the client exists or not.

=head2 new_connection

Creates a new client-object, and puts it into the C<$self-E<gt>clients> hash.

=head2 decode

Decodes the messages from the client. It can only handle ACKs for now.

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


=head2 log($level, $client, $msg)

Logs information.

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
