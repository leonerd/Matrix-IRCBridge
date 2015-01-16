#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use IO::Async::Test;

use MatrixBridge::Component::Matrix;

use Event::Distributor;
use IO::Async::Loop;

my $dist = Event::Distributor->new;
$dist->declare_signal( 'log' );

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

testing_loop( $loop );

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
    $p->[2]->done( {
        rooms => [
            {
                room_id => "!abcdefg:server.here",
                membership => "join",
                state => [
                    {
                        type       => "m.room.member",
                        state_key  => '@someone:server.here',
                        membership => "join",
                    },
                ],
            },
        ],
        presence => [],
        end => "E-TOKEN" }
    );

    # Might not yet have the room join future, because of the 0-second delay
    wait_for { @next };

    $p = shift @next;
    is( $p->[0], "POST", 'request is POST' );
    is( $p->[1], "/join/#the-room:server.here", 'request URI' );
    $p->[2]->done( { room_id => "!abcdefg:server.here" } );

    ok( defined $next_GET_events, 'GET /events is pending' );
}

# receive message
{
    my @received;
    $dist->subscribe_sync( on_matrix_message => sub {
        shift;
        push @received, { @_ };
    });

    $next_GET_events->done( {
        chunk => [ {
            type    => "m.room.message",
            room_id => "!abcdefg:server.here",
            user_id => '@someone:server.here',
            content => {
                msgtype => "m.text",
                body    => "Hello, world",
            },
        } ],
        end => "E-TOKEN",
    });

    ok( scalar @received, 'on_matrix_message invoked' );
    is_deeply( shift @received,
        { user_id   => '@someone:server.here',
          room_name => "#the-room:server.here",
          type      => "m.text",
          message   => "Hello, world",

          content => {
              format  => undef,
              msgtype => "m.text",
              body    => "Hello, world",
          },
          displayname => undef,
        },
        'on_message arguments'
    );
}

done_testing;
