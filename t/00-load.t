#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'Var::State' );
}

diag( "Testing Var::State $Var::State::VERSION, Perl $], $^X" );
