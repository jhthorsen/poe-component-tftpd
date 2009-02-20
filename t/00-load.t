#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'POE::Component::TFTPd' );
}

diag( "Testing POE::Component::TFTPd $POE::Component::TFTPd, Perl $], $^X" );
