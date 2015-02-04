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
        'irc-bot' => {
            nick => "MyBot",
            ident => "bot",
        },
    },
    loop => $loop,
);

$dist->declare_signal( 'add_bridge_config' );
$dist->fire_sync( add_bridge_config =>
    { "irc-channel" => "#the-channel" },
);

# start the bot
{
    $dist->declare_signal( 'startup' );
    my $f = $dist->fire_async( startup => );

    $loop->loop_once(1) until $server_stream;

    $server_stream->read_until( qr/$CRLF.*$CRLF/ )->get;
    $server_stream->write( ":server 001 MyBot :Welcome to IRC$CRLF" );
    $server_stream->read_until( $CRLF )->get;
    $server_stream->write( ":MyBot!bot\@localhost JOIN #the-channel$CRLF" );

    $f->get;
}

my $bot_stream = $server_stream;
undef $server_stream;

# start a user
{
    my $f = $dist->fire_async( send_irc_message =>
        nick    => "TestUser",
        ident   => "testuser",
        channel => "#the-channel",
        message => "A message I hope doesn't echo",
    );

    $loop->loop_once(1) until $server_stream;

    $server_stream->read_until( qr/$CRLF.*$CRLF/ )->get;
    $server_stream->write( ":server 001 TestUser :Welcome to IRC$CRLF" );
    $server_stream->read_until( $CRLF )->get;
    $server_stream->write( ":TestUser!testuser\@localhost JOIN #the-channel$CRLF" );

    $f->get;
}

my $user_stream = $server_stream;
undef $server_stream;

# server should now see the message
like( $user_stream->read_until( $CRLF )->get,
    qr/^PRIVMSG #the-channel :A message I hope doesn't echo/, 'server sees user message' );

# reflect this event and check it doesn't come back
{
    my $received;
    $dist->subscribe_sync( on_irc_message => sub {
        $received++;
    });

    $bot_stream->write( ":TestUser!testuser\@localhost PRIVMSG #the-channel :A message I hope doesn't echo$CRLF" );

    # Give IO::Async a decent chance to do things
    $loop->loop_once(0.1) for 1 .. 3;

    ok ( !$received, 'on_irc_message not invoked for echoed message' );
}

done_testing;
