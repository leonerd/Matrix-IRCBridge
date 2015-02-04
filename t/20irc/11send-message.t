#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use IO::Async::Test;

use MatrixBridge::Component::IRC;

use Event::Distributor;
use IO::Async::Loop;
use IO::Async::Listener;

my $CRLF = "\x0D\x0A";

my $dist = Event::Distributor->new;
$dist->declare_signal( 'log' );

my $loop = IO::Async::Loop->new;

testing_loop( $loop );

# Test IRC against a real TCP socket we're listening on
my $server_stream;
my $server_port;

{
    my $irc_server = IO::Async::Listener->new(
        handle_class => "IO::Async::Stream",
        on_accept => sub {
            my ( undef, $stream ) = @_;
            die "accept() collision!" if $server_stream;

            $stream->configure(
                on_read => sub { 0 }, # read using read futures
            );

            $loop->add( $server_stream = $stream );
        }
    );
    $loop->add( $irc_server );

    $irc_server->listen( addr => { family => "inet", port => 0 } )->get;

    $server_port = $irc_server->read_handle->sockport;
}

my $irc = MatrixBridge::Component::IRC->new(
    dist => $dist,
    conf => {
        irc => {
            host => "127.0.0.1",
            service => $server_port,
        },
    },
    loop => $loop,
);

# send message - connect new user
{
    my $f = $dist->fire_async( send_irc_message =>
        nick      => "TestUser",
        ident     => "testuser",
        channel   => "#a-channel",
        is_action => 0,
        message   => "Here is my message",
    );
    $f->on_fail( sub { die @_ } );

    $loop->loop_once(1) until $server_stream;

    # Complete startup

    # Expect USER and NICK lines
    like( $server_stream->read_until( qr/$CRLF.*$CRLF/ )->get,
        qr/^USER.*${CRLF}NICK/, 'IRC login for user' );

    $server_stream->write( ":server 001 TestUser :Welcome to IRC$CRLF" );

    # Expect JOIN
    like( $server_stream->read_until( $CRLF )->get,
        qr/^JOIN #a-channel/, 'IRC user JOINs channel' );

    $server_stream->write( ":TestUser!testuser\@localhost JOIN #a-channel$CRLF" );

    # Expect PRIVMSG
    like( $server_stream->read_until( $CRLF )->get,
        qr/^PRIVMSG #a-channel :Here is my message/, 'IRC user sends PRIVMSG' );

    wait_for { $f->is_ready };
    ok( $f->is_ready, '$f is now ready' );
}

# second message to same channel - immediate
{
    my $f = $dist->fire_async( send_irc_message =>
        nick      => "TestUser",
        ident     => "testuser",
        channel   => "#a-channel",
        is_action => 0,
        message   => "A second message",
    );
    $f->on_fail( sub { die @_ } );

    # Expect PRIVMSG
    like( $server_stream->read_until( $CRLF )->get,
        qr/^PRIVMSG #a-channel :A second message/, 'IRC user sends second PRIVMSG immediately' );

    wait_for { $f->is_ready };
    ok( $f->is_ready, '$f is now ready' );
}

# new channel - sends JOIN on existing connection
{
    my $f = $dist->fire_async( send_irc_message =>
        nick      => "TestUser",
        ident     => "testuser",
        channel   => "#different",
        is_action => 0,
        message   => "Elsewhere now",
    );
    $f->on_fail( sub { die @_ } );

    # Expect JOIN
    like( $server_stream->read_until( $CRLF )->get,
        qr/^JOIN #different/, 'IRC user JOINs new channel' );

    $server_stream->write( ":TestUser!testuser\@localhost JOIN #different$CRLF" );

    # Expect PRIVMSG
    like( $server_stream->read_until( $CRLF )->get,
        qr/^PRIVMSG #different :Elsewhere now/, 'IRC user sends PRIVMSG' );

    wait_for { $f->is_ready };
    ok( $f->is_ready, '$f is now ready' );
}

# as action
{
    my $f = $dist->fire_async( send_irc_message =>
        nick      => "TestUser",
        ident     => "testuser",
        channel   => "#a-channel",
        is_action => 1,
        message   => "does something",
    );
    $f->on_fail( sub { die @_ } );

    # Expect PRIVMSG
    like( $server_stream->read_until( $CRLF )->get,
        qr/^PRIVMSG #a-channel :\cAACTION does something/, 'IRC user sends CTCP ACTION PRIVMSG' );

    wait_for { $f->is_ready };
    ok( $f->is_ready, '$f is now ready' );
}

# as notice
{
    my $f = $dist->fire_async( send_irc_message =>
        nick      => "TestUser",
        ident     => "testuser",
        channel   => "#a-channel",
        is_notice => 1,
        message   => "Announcement here",
    );
    $f->on_fail( sub { die @_ } );

    # Expect PRIVMSG
    like( $server_stream->read_until( $CRLF )->get,
        qr/^NOTICE #a-channel :Announcement/, 'IRC user sends NOTICE' );

    wait_for { $f->is_ready };
    ok( $f->is_ready, '$f is now ready' );
}

done_testing;
