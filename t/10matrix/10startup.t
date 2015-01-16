#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use MatrixBridge::Component::Matrix;

use Event::Distributor;
use IO::Async::Loop;

my $dist = Event::Distributor->new;

my $matrix = MatrixBridge::Component::Matrix->new(
    dist => $dist,
    conf => {
        matrix => {
            server => "test-server.here",
        },
        'matrix-bot' => {
            user_id  => "my-user",
            password => "secret-here",
        },
    },
    loop => my $loop = IO::Async::Loop->new,
);

$dist->declare_signal( 'add_bridge_config' );
$dist->fire_sync( add_bridge_config =>
    { "matrix-room" => "#the-room:server.here" },
);

no warnings 'redefine';

my $next_GET_events;
my @next;

*Net::Async::Matrix::_do_GET_json = sub {
    shift;
    my ( $url, %args ) = @_;
    if( $url eq "/events" ) {
        return $next_GET_events = Future->new;
    }
    push @next, [ GET => $url, my $f = Future->new, \%args ];
    return $f;
};

*Net::Async::Matrix::_do_POST_json = sub {
    shift;
    my ( $url, $content, %args ) = @_;
    push @next, [ POST => $url, my $f = Future->new, \%args, $content ];
    return $f;
};

# startup
{
    $dist->declare_signal( 'startup' );

    my $f = $dist->fire_async( startup => );

    # Complete the entire /login dance
    ok( my $p = shift @next, 'request pending' );
    is( $p->[0], "GET", 'request is GET' );
    is( $p->[1], "/login", 'request URI' );
    $p->[2]->done( {
        flows => [ { type => "m.login.password", stages => [ "m.login.password" ] } ]
    } );

    ok( $p = shift @next, 'second request pending' );
    is( $p->[0], "POST", 'request is POST' );
    is( $p->[1], "/login", 'request URI' );
    $p->[2]->done( { user_id => "my-user", access_token => "TOKEN" } );

    # Probably have a GET /initialSync now
    ok( $p = shift @next, 'third request pending' );
    is( $p->[0], "GET", 'request is GET' );
    is( $p->[1], "/initialSync", 'request URI' );
    # Nothing
    $p->[2]->done( { rooms => [], presence => [], end => "E-TOKEN" } );

    # Might not yet have the room join future, because of the 0-second delay
    $loop->loop_once(1) until @next;

    $p = shift @next;
    is( $p->[0], "POST", 'request is POST' );
    is( $p->[1], "/join/#the-room:server.here", 'request URI' );

    # TODO: can't ->done it yet without being able to mock in the room_id method
    # Also it would print a warning
}

done_testing;
