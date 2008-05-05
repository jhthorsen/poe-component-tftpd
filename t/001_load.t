# -*- perl -*-

# t/001_load.t - check module loading and create testing directory

use Test::More tests => 2;

BEGIN { use_ok( 'POE::Component::TFTPd' ); }

my $object = POE::Component::TFTPd->create;
isa_ok($object, 'POE::Component::TFTPd');

