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

# startup
{
    $dist->declare_signal( 'startup' );

    my $f = $dist->fire_async( startup => );
    $f->on_fail( sub { die @_ } );

    $loop->loop_once(1) until $server_stream;

    # Complete startup

    # Expect USER and NICK lines
    like( $server_stream->read_until( qr/$CRLF.*$CRLF/ )->get,
        qr/^USER.*${CRLF}NICK/, 'IRC login' );

    $server_stream->write( ":server 001 MyBot :Welcome to IRC$CRLF" );

    # Expect JOIN
    like( $server_stream->read_until( $CRLF )->get,
        qr/^JOIN #the-channel/, 'Bot joins the channel' );

    $server_stream->write( ":MyBot!bot\@localhost JOIN #the-channel$CRLF" );

    wait_for { $f->is_ready };
    ok( $f->is_ready, '$f is now ready' );
}

# receive message
{
    my @received;
    $dist->subscribe_sync( on_irc_message => sub {
        shift;
        push @received, { @_ };
    });

    $server_stream->write( ":SomeNick!user\@their.host PRIVMSG #channel :Here is the message$CRLF" );

    wait_for { scalar @received };

    is_deeply( shift @received,
        { nick      => "SomeNick",
          ident     => "SomeNick",   # TODO: this ought to be 'user'
          channel   => "#channel",
          is_action => 0,
          is_notice => 0,
          message   => "Here is the message",
        },
        'on_irc_message arguments'
    );

    $server_stream->write( ":SomeNick!user\@their.host NOTICE #channel :And here is another one$CRLF" );

    wait_for { scalar @received };

    is_deeply( shift @received,
        { nick      => "SomeNick",
          ident     => "SomeNick",   # TODO: this ought to be 'user'
          channel   => "#channel",
          is_action => 0,
          is_notice => 1,
          message   => "And here is another one",
        },
        'on_irc_message arguments'
    );
}

# send as bot
{
    my $f = $dist->fire_async( send_irc_message =>
        as_bot  => 1,
        channel => "#channel",
        message => "an announcement from the bot",
    );

    like( $server_stream->read_until( $CRLF )->get,
        qr/^PRIVMSG #channel :an announcement from the bot/,
        'IRC bot can send messages itself' );

    wait_for { $f->is_ready };
    ok( $f->is_ready, '$f is now ready' );
}

done_testing;
