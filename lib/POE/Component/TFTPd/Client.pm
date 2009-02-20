package POE::Component::TFTPd::Client;

=head1 NAME

POE::Component::TFTPd::Client

=head1 VERSION

See L<POE::Component::TFTPd>

=cut

use strict;
use warnings;
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
    _rfc          => [], # remember to override in new!
    _almost_done  => 0,
);

=head1 METHODS

=head2 new

=cut

sub new {
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
        _rfc        => [],
    }, $class;
}

=head2 id

=head2 address

=head2 port

=head2 retries

=head2 timestamp

=head2 last_block

=head2 block_size

=head2 rrq

=head2 wrq

=head2 filename

=head2 mode

=head2 rfc

=head2 almost_done

=cut

{
    no strict 'refs';
    for my $key (keys %defaults) {
        my($sub) = $key =~ /_(\w+)/;
        *$sub    = sub :lvalue { shift->{$key} };
    }
}

=head1 AUTHOR

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

See L<POE::Component::TFTPd>

=cut

1;
