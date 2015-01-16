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
        'matrix-password-key' => "the key",
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
    my $self = shift;
    my ( $url, %args ) = @_;
    if( $url eq "/events" ) {
        return Future->new unless $self->{access_token} eq "BOT-TOKEN";
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

$dist->declare_signal( 'startup' );
my $f = $dist->fire_async( startup => );

# The login dance
{
    # GET /login
    (shift @next)->[2]->done( {
        flows => [ { type => "m.login.password", stages => [ "m.login.password" ] } ]
    } );

    # POST /login
    (shift @next)->[2]->done( { user_id => "my-user", access_token => "BOT-TOKEN" } );

    # GET /initialSync
    (shift @next)->[2]->done( {
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

    # POST /join
    (shift @next)->[2]->done( { room_id => "!abcdefg:server.here" } );

    ok( defined $next_GET_events, 'GET /events is pending' );
}

# send a message
{
    my $f = $dist->fire_async( send_matrix_message =>
        user_id     => "login-user",
        displayname => "(IRC login-user)",
        room_name   => "!abcdefg:server.here",
        type        => "m.text",
        message     => "Another hello",
    );

    ok( my $p = shift @next, 'send_matrix_message first HTTP request' );
    $p->[2]->done( {
        flows => [ { type => "m.login.password", stages => [ "m.login.password" ] } ]
    } );

    # POST /login
    (shift @next)->[2]->done( { user_id => '@login-user:server.here', access_token => "TOKEN" } );

    # GET /initialSync
    (shift @next)->[2]->done( { rooms => [], presence => [], end => "E-TOKEN" } );

    # PUT /profile/...
    (shift @next)->[2]->done( {} );

    # POST /join
    (shift @next)->[2]->done( { room_id => "!abcdefg:server.here" } );

    # GET /rooms/.../state
    (shift @next)->[2]->done( [] );

    # POST /rooms/.../send - fiiiinally
    (shift @next)->[2]->done( {} );

    $next_GET_events->done( {
        chunk => [ {
            type       => "m.room.member",
            room_id    => "!abcdefg:server.here",
            state_key  => '@login-user:server.here',
            user_id    => '@login-user:server.here',
            membership => "join",
            content => {
                membership => "join", # yes we need it twice.....
            },
        } ],
        end => "E-TOKEN",
    } );
}

# reflect this event and check it doesn't come back
{
    my $received;
    $dist->subscribe_sync( on_matrix_message => sub {
        $received++;
    });

    $next_GET_events->done( {
        chunk => [ {
            type => "m.room.message",
            room_id => "!abcdefg:server.here",
            user_id => '@login-user:server.here',
            content => {
                msgtype => "m.text",
                body    => "Another hello",
            },
        } ],
        end => "E-TOKEN",
    });

    ok( !$received, 'on_matrix_message not invoked for echoed message' );
}

done_testing;
