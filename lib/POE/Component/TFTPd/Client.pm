
#=====================================
package POE::Component::TFTPd::Client;
#=====================================

use strict;
use warnings;

sub new { #===================================================================

    my $class = shift;
    my %args  = @_;

    return bless \%args, $class;
}

sub read_data { #=============================================================
    die "read_data() should be overriden";
}

BEGIN { #=====================================================================
    no strict;

    my @set = qw/
        address     port      timestamp
        completed   opcode    mode
        block_size  last_ack  last_block  payload
        filename    filesize  filehandle
        block_count retries
    /;

    for $sub (@set) {
        *$sub = sub :lvalue { shift->{$sub} };
    }
}

#=============================================================================
1983;
__END__

=head1 NAME

=head1 VERSION

See POE::Component::TFTPd

=head1 METHODS

=head2 new

=head2 read_data

=head2 address

=head2 port

=head2 timestamp

=head2 completed

=head2 opcode

=head2 mode

=head2 block_size

=head2 last_ack

=head2 last_block

=head2 payload

=head2 filename

=head2 filesize

=head2 filehandle

=head2 block_count

=head2 retries

=head1 TODO

 * Setup a default read_data() method that read plain files from disk

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
