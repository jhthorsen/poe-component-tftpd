
#=====================================
package POE::Component::TFTPd::Client;
#=====================================

use strict;
use warnings;
use vars qw/$AUTOLOAD/;
use POE::Component::TFTPd;

my %defaults = (
    _id           => undef,
    _address      => undef,
    _port         => undef,
    _retries      => 0,
    _timestamp    => 0,
    _last_block   => 0,
    _block_size   => 0,
    _rrq          => 0,
    _wrq          => 0,
    _filename     => q(),
    _mode         => q(),
    _rfc          => [],
    _almost_done  => 0,
);

for my $key (keys %defaults) {
    no strict 'refs';
    my($sub) = $key =~ /_(\w+)/;
    *$sub    = sub :lvalue { shift->{$key} };
}

sub new { #===================================================================

    my $class  = shift;
    my $tftpd  = shift;
    my $client = shift;

    return bless {
        %defaults,
        _id         => join(":", $client->{'addr'}, $client->{'port'}),
        _address    => $client->{'addr'},
        _port       => $client->{'port'},
        _block_size => POE::Component::TFTPd::TFTP_MIN_BLKSIZE(),
        _retries    => $tftpd->retries,
    }, $class;
}


#=============================================================================
1983;
__END__

=head1 NAME

=head1 VERSION

See POE::Component::TFTPd

=head1 METHODS

  name         => default
  -----------------------
  id           => undef,
  address      => undef,
  port         => undef,
  retries      => 0,
  timestamp    => 0,
  last_block   => 0,
  block_size   => 0,
  rrq          => 0,
  wrq          => 0,
  filename     => q(),
  mode         => q(),
  rfc          => [],
  almost_done  => 0,

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
