#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use MatrixBridge::Component::Matrix;

use Event::Distributor;
use IO::Async::Loop;

{
    my %namatrix_args;

    no warnings 'once';
    local *Net::Async::Matrix::new = sub {
        my $class = shift;
        %namatrix_args = @_;
        return bless {}, $class;
    };

    my $dist = Event::Distributor->new;

    my $matrix = MatrixBridge::Component::Matrix->new(
        dist => $dist,
        conf => {
            matrix => {
                server => "test-server.here",
            },
        },
        loop => my $loop = IO::Async::Loop->new,
    );

    ok( defined $matrix, '$matrix defined' );
    isa_ok( $matrix, "MatrixBridge::Component::Matrix", '$matrix' );

    # First, the awkward CODErefs
    is( ref delete $namatrix_args{$_}, "CODE", "$_ => CODE" ) for qw(
        on_error on_log on_room_new
    );

    is_deeply( \%namatrix_args,
        {
            server          => "test-server.here",
            SSL_verify_mode => 0,
        },
        'Net::Async::Matrix->new arguments' );
}

done_testing;
