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

    $dist->declare_signal( 'startup' );

    my $f = $dist->fire_async( startup => );

    is_deeply( \%login_args,
        { user_id => "my-user", password => "secret-here" },
        '$namatrix->login args'
    );
    ok( $started, '$namatrix->start' );
}

done_testing;
