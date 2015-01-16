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

# startup
{
    no warnings 'redefine';

    my %login_args;
    local *Net::Async::Matrix::login = sub {
        my $self = shift;
        %login_args = @_;

        $self->{access_token} = "TOKEN";

        Future->done;
    };

    my $started;
    local *Net::Async::Matrix::start = sub {
        $started++;
        Future->done;
    };

    my %join_f;
    local *Net::Async::Matrix::join_room = sub {
        shift;
        my ( $room_alias ) = @_;
        return $join_f{$room_alias} = Future->new;
    };

    $dist->declare_signal( 'startup' );

    my $f = $dist->fire_async( startup => );

    is_deeply( \%login_args,
        { user_id => "my-user", password => "secret-here" },
        '$namatrix->login args'
    );
    ok( $started, '$namatrix->start' );

    # Might not yet have the room join future, because of the 0-second delay
    $loop->loop_once(1) until keys %join_f;

    ok( $join_f{"#the-room:server.here"}, 'Room join future is pending' );

    # TODO: can't ->done it yet without being able to mock in the room_id method
    # Also it would print a warning
}

done_testing;
