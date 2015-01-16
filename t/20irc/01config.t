#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use MatrixBridge::Component::IRC;

use Event::Distributor;
use IO::Async::Loop;

{
    my %nairc_args;

    no warnings 'redefine';
    my $was_new = Net::Async::IRC->can( 'new' );
    local *Net::Async::IRC::new = sub {
        my $class = shift;
        %nairc_args = @_;
        return $class->$was_new( @_ );
    };

    my $dist = Event::Distributor->new;

    my $irc = MatrixBridge::Component::IRC->new(
        dist => $dist,
        conf => {
            irc => {
                host => "my-test-server",
            },
        },
        loop => my $loop = IO::Async::Loop->new,
    );

    ok( defined $irc, '$irc defined' );
    isa_ok( $irc, "MatrixBridge::Component::IRC", '$irc' );

    # First, the awkward CODErefs
    is( ref delete $nairc_args{$_}, "CODE", "$_ => CODE" ) for qw(
        on_error on_closed
        on_message_text on_message_ctcp_ACTION
    );

    is_deeply( \%nairc_args,
        {
            encoding => "UTF-8",
        },
        'Net::Async::IRC->new arguments' );
}

done_testing;
