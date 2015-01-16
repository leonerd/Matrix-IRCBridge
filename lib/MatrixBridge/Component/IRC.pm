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
    );

    $dist->declare_signal( $_ ) for qw( on_irc_message );

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

sub _on_message
{
    my $self = shift;
    my ( $message, $is_action, $text, $hints ) = @_;

    return if $hints->{is_notice};
    # return if is_irc_user($hints->{prefix_name});

    my $channel = $hints->{target_name};

    my $msg = String::Tagged::IRC->parse_irc( $text );

    $self->log( ( $is_action ? "CTCP action" : "Text message" ), " in $channel: $msg" );

    $self->dist->fire_sync( on_irc_message =>
        nick      => $hints->{prefix_nick},
        ident     => $hints->{prefix_name},
        channel   => $channel,
        is_action => $is_action,
        message   => $msg,
    );
}

0x55AA;
