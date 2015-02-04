package MatrixBridge::Component::IRC;

use strict;
use warnings;
use base qw( MatrixBridge::Component );

use curry;
use Future;

use String::Tagged::IRC 0.02; # Formatting

# placate bug in Protocol::IRC::Message
{
    local $_;
    require Net::Async::IRC;
}

sub init
{
    my $self = shift;

    my $dist = $self->dist;
    $dist->subscribe_async( $_ => $self->${\"curry::$_"} ) for qw(
        add_bridge_config
        startup shutdown

        send_irc_message
    );

    $dist->declare_signal( $_ ) for qw( on_irc_message send_irc_message );

    my $irc_config = $self->{irc_config} = {
        %{ $self->conf->{irc} },
    };

    my $reconnect_delay = 5;

    my $on_message = $self->curry::weak::_on_message;
    my $do_startup = $self->curry::weak::startup;

    my $irc = Net::Async::IRC->new(
        encoding => "UTF-8",
        on_message_ctcp_ACTION => sub {
            my ( $self, $message, $hints ) = @_;
            $reconnect_delay = 5;

            $on_message->( $message, 1, $hints->{ctcp_args}, $hints );
        },
        on_message_text => sub {
            my ( $self, $message, $hints ) = @_;
            $reconnect_delay = 5;

            $on_message->( $message, 0, $hints->{text}, $hints );
        },
        on_error => sub {
            my ( undef, $failure, $name, @args ) = @_;
            print STDERR "IRC failure: $failure\n";
        },
        on_closed => sub {
            my ( $self ) = @_;

            $self->loop->delay_future( after => $reconnect_delay )->then( sub {
                $reconnect_delay *= 2 if $reconnect_delay < 300; # ramp up to 5 minutes

                $self->adopt_future( $do_startup->() );
            });
        },
    );
    $self->loop->add( $irc );

    $self->{bot_irc} = $irc;

    $self->{user_irc} = {};
    $self->{user_channels} = {};

    $self->{bridged_channels} = {};
}

sub add_bridge_config
{
    my $self = shift;
    my ( $dist, $config ) = @_;

    if( my $channel_name = $config->{"irc-channel"} ) {
        $self->{bridged_channels}{$channel_name} = $config;
    }

    Future->done;
}

sub startup
{
    my $self = shift;

    my $irc = $self->{bot_irc};

    # Stagger channel joins to avoid thundering-herd on the server
    my $delay = 0;

    $irc->login( %{ $self->{irc_config} }, %{ $self->conf->{"irc-bot"} } )->then(sub {
        Future->wait_all( map {
            my $channel = $_->{"irc-channel"};

            $self->loop->delay_future( after => $delay++ )->then( sub {
                $irc->send_message( "JOIN", undef, $channel )
            })->on_done( sub {
                # TODO: We haven't joined yet, we've just sent the join message.
                # We should await a confirmation from the server
                $self->log( "joined $channel" );
            });
        } values %{ $self->{bridged_channels} } );
    })
}

sub shutdown
{
    # do nothing
}

sub _on_message
{
    my $self = shift;
    my ( $message, $is_action, $text, $hints ) = @_;

    return if exists $self->{user_irc}{ $hints->{prefix_name_folded} };

    my $channel = $hints->{target_name};

    my $msg = String::Tagged::IRC->parse_irc( $text );

    $self->log( ( $is_action ? "CTCP action" : "Text message" ), " in $channel: $msg" );

    $self->dist->fire_sync( on_irc_message =>
        nick      => $hints->{prefix_nick},
        ident     => $hints->{prefix_name},
        channel   => $channel,
        is_action => $is_action,
        is_notice => $hints->{is_notice},
        message   => $msg,
    );
}

sub _canonise_irc_name
{
    my $self = shift;
    my ( $name ) = @_;

    my $maxlen = $self->{bot_irc}->isupport( 'NICKLEN' ) // 9;
    return lc substr $name, 0, $maxlen;
}

sub _make_user
{
    my $self = shift;
    my ( $nick_canon, $nick, $ident ) = @_;

    $self->log( "making new IRC user for $nick" );

    my $user_irc = Net::Async::IRC->new(
        encoding => "UTF-8",
        user => $ident,

        on_message_KICK => sub {
            my ( $user_irc, $message, $hints ) = @_;

            # TODO: Get NaIRC to add kicked_is_me hint
            return unless $user_irc->is_nick_me( $hints->{kicked_nick} );

            my $channel = $hints->{target_name};

            $self->log( "user $nick got kicked from $channel" );
            delete $self->{user_channels}{$nick_canon}{$channel};
        },

        on_closed => sub {
            $self->log( "user $nick connection lost" );

            delete $self->{user_channels}{$nick_canon};
            delete $self->{user_irc}{$nick_canon};
        },
    );
    $self->{bot_irc}->add_child( $user_irc );

    return $user_irc->login(
        nick => $nick,
        %{ $self->conf->{'irc'} },
    )->on_done(sub {
        $self->log( "new IRC user ready" );
    });
}

sub _get_user_in_channel
{
    my $self = shift;
    my ( $nick, $ident, $channel ) = @_;

    my $nick_canon = $self->_canonise_irc_name( $nick );

    ( $self->{user_irc}{$nick_canon} ||= $self->_make_user( $nick_canon, $nick, $ident )
        ->on_fail( sub { delete $self->{user_irc}{$nick_canon} } )
    )->then( sub {
        my ( $user_irc ) = @_;
        return $self->{user_channels}{$nick_canon}{$channel} //=
            $user_irc->send_message( "JOIN", undef, $channel )->then_done( $user_irc )
            ->on_fail( sub { delete $self->{user_channels}{$nick_canon}{$channel} } );
        });
}

sub send_irc_message
{
    my $self = shift;
    my ( $dist, %args ) = @_;

    my $nick      = $args{nick};
    my $ident     = $args{ident};
    my $channel   = $args{channel};
    my $is_action = $args{is_action};
    my $is_notice = $args{is_notice};
    my $message   = $args{message};

    ( $args{as_bot}
        ? Future->done( $self->{bot_irc} )
        : $self->_get_user_in_channel( $nick, $ident, $channel )
    )->then( sub {
        my ( $user_irc ) = @_;

        my $rawmessage = ref $message ?
            String::Tagged::IRC->new_from_formatted( $message )->build_irc :
            $message;

        if( $is_notice ) {
            $user_irc->send_message( "NOTICE", undef, $channel, $rawmessage );
        }
        elsif( $is_action ) {
            $user_irc->send_ctcp( undef, $channel, "ACTION", $rawmessage );
        }
        else {
            $user_irc->send_message( "PRIVMSG", undef, $channel, $rawmessage );
        }
    });
}

0x55AA;
