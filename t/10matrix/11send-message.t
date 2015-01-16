#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use MatrixBridge::Component::Matrix;

use Event::Distributor;
use IO::Async::Loop;

my $dist = Event::Distributor->new;
$dist->declare_signal( 'on_log' );
$dist->subscribe_sync( on_log => sub { warn @_ } );

my $matrix = MatrixBridge::Component::Matrix->new(
    dist => $dist,
    conf => {
        matrix => {
            server => "test-server.here",
        },
        'matrix-password-key' => "the key",
    },
    loop => my $loop = IO::Async::Loop->new,
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

*Net::Async::Matrix::_do_PUT_json = sub {
    shift;
    my ( $url, $content, %args ) = @_;
    push @next, [ PUT => $url, my $f = Future->new, \%args, $content ];
    return $f;
};
*Net::Async::Matrix::_do_POST_json = sub {
    shift;
    my ( $url, $content, %args ) = @_;
    push @next, [ POST => $url, my $f = Future->new, \%args, $content ];
    return $f;
};

# send message - log in user
{
    my $f = $dist->fire_async( send_matrix_message =>
        user_id     => "login-user",
        displayname => "(IRC login-user)",
        room_id     => "!abcdefg:server.here",
        type        => "m.text",
        message     => "Another hello",
    );

    # GET /login
    ok( my $p = shift @next, 'send_matrix_message first HTTP request' );
    is( $p->[1], "/login", 'request URI' );
    $p->[2]->done( {
        flows => [ { type => "m.login.password", stages => [ "m.login.password" ] } ]
    } );

    # POST /login
    ok( $p = shift @next, 'second request pending' );
    is( $p->[1], "/login", 'request URI' );
    $p->[2]->done( { user_id => '@login-user:server.here', access_token => "TOKEN" } );

    # GET /initialSync
    ok( $p = shift @next, 'third request pending' );
    is( $p->[1], "/initialSync", 'request URI' );
    $p->[2]->done( { rooms => [], presence => [], end => "E-TOKEN" } );

    # PUT /profile/...
    ok( $p = shift @next, 'fourth request pending' );
    is( $p->[1], '/profile/@login-user:server.here/displayname', 'request URI' );
    is( $p->[4]->{displayname}, "(IRC login-user)", 'request content displayname' );
    $p->[2]->done( {} );

    # POST /join
    ok( $p = shift @next, 'fifth request pending' );
    is( $p->[1], "/join/!abcdefg:server.here", 'request URI' );
    $p->[2]->done( { room_id => "!abcdefg:server.here" } );

    # GET /rooms/.../state
    ok( $p = shift @next, 'sixth request pending' );
    is( $p->[1], "/rooms/!abcdefg:server.here/state", 'request URI' );
    $p->[2]->done( [] );

    # POST /rooms/.../send - fiiiinally
    ok( $p = shift @next, 'seventh request pending' );
    is( $p->[1], "/rooms/!abcdefg:server.here/send/m.room.message", 'request URI' );
    is_deeply( $p->[4], { msgtype => "m.text", body => "Another hello" }, 'request content' );
    $p->[2]->done( {} );

    ok( $f->is_ready, '$f is now ready' );

    # Sending a second message should now be nice and cheap
    my $f2 = $dist->fire_async( send_matrix_message =>
        user_id => "login-user",
        room_id => "!abcdefg:server.here",
        type    => "m.text",
        message => "Second line",
    );
    $f2->on_fail( sub { die @_ } );

    ok( $p = shift @next, 'first request pending' );
    is( $p->[1], "/rooms/!abcdefg:server.here/send/m.room.message", 'request URI' );
    is_deeply( $p->[4], { msgtype => "m.text", body => "Second line" }, 'request content' );
    $p->[2]->done( {} );

    ok( $f2->is_ready, '$f2 is now ready' );
}

# send message - register a new user
{
    my $f = $dist->fire_async( send_matrix_message =>
        user_id     => "new-user",
        displayname => "(IRC new-user)",
        room_id     => "!abcdefg:server.here",
        type        => "m.text",
        message     => "Hi again",
    );

    # GET /login
    ok( my $p = shift @next, 'send_matrix_message first HTTP request' );
    is( $p->[1], "/login", 'request URI' );
    $p->[2]->done( {
        flows => [ { type => "m.login.password", stages => [ "m.login.password" ] } ]
    } );

    # POST /login - FAIL
    ok( $p = shift @next, 'second request pending' );
    is( $p->[1], "/login", 'request URI' );
    $p->[2]->fail( "Not allowed", http => undef, undef ); # TODO

    # GET /register
    ok( $p = shift @next, 'third request pending' );
    is( $p->[1], "/register", 'request URI' );
    $p->[2]->done( {
        flows => [ { type => "m.login.password", stages => [ "m.login.password" ] } ]
    } );

    # POST /register
    ok( $p = shift @next, 'fourth request pending' );
    is( $p->[1], "/register", 'request URI' );
    is( $p->[4]->{user}, "new-user", 'request content user' );
    $p->[2]->done( { user_id => '@new-user:server.here', access_token => "TOKEN" } );

    ok( $p = shift @next, 'fifth request pending' );
    is( $p->[1], "/initialSync", 'request URI' );

    # Stop there; should be the same from now on
}

done_testing;
