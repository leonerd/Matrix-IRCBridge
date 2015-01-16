package MatrixBridge::Component::Matrix;

use strict;
use warnings;
use base qw( MatrixBridge::Component );

use curry;
use Future;
use Future::Utils qw( try_repeat );

use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use Net::Async::Matrix 0.13; # $room->invite; ->join_room bugfix
use Net::Async::Matrix::Utils qw( parse_formatted_message build_formatted_message );

# A Future utility
sub try_repeat_with_delay(&@)
{
    my ( $code, $loop ) = @_;

    my $retries_remaining = 5;

    try_repeat {
        $code->()->else_with_f( sub {
            my ( $f ) = @_;
            return $f unless $retries_remaining--;

            warn $f->failure . "; $retries_remaining attempts remaining...\n";

            $loop->delay_future( after => 5 )
                ->then( sub { $f } )
        })
    } while => sub { shift->failure and $retries_remaining };
}

sub init
{
    my $self = shift;

    my $dist = $self->dist;
    $dist->subscribe_async( $_ => $self->${\"curry::$_"} ) for qw(
        add_bridge_config
        startup shutdown
        on_message
    );

    my $matrix_config = $self->{matrix_config} = {
        %{ $self->conf->{matrix} },
        # No harm in always applying this
        SSL_verify_mode => SSL_VERIFY_NONE,
    };

    my $matrix = Net::Async::Matrix->new(
        %$matrix_config,
        on_log => sub { warn "log: @_\n" },
        on_room_new => sub {
            my ( $matrix, $room ) = @_;

            $room->configure(
                on_message => $self->curry::weak::_on_room_message,
            );
        },
        on_error => sub {
            my ( undef, $failure, $name, @args ) = @_;
            print STDERR "Matrix failure: $failure\n";
            if( defined $name and $name eq "http" ) {
                my ($response, $request) = @args;
                print STDERR "HTTP failure details:\n" .
                    "Requested URL: ${\$request->method} ${\$request->uri}\n";
                if($response) {
                    print STDERR "Response ${\$response->status_line}\n";
                    print STDERR " | $_\n" for split m/\n/, $response->decoded_content;
                }
                else {
                    print STDERR "No response\n";
                }
            }
        },
    );
    $self->loop->add( $matrix );

    $self->{bot_matrix} = $matrix;

    $self->{bot_matrix_rooms} = {};

    # Incoming Matrix room messages only have the (opaque) room ID, so we'll need
    # to remember what alias we joined those rooms by
    $self->{room_alias_for_id} = {};

    $self->{bridged_rooms} = {};
}

sub add_bridge_config
{
    my $self = shift;
    my ( $dist, $config ) = @_;

    if( my $room_name = $config->{"matrix-room"} ) {
        $self->{bridged_rooms}{$room_name} = $config;
    }

    Future->done;
}

sub startup
{
    my $self = shift;

    my $matrix = $self->{bot_matrix};
    my $loop = $self->loop;

    my $login_f = try_repeat_with_delay {
        $matrix->login( %{ $self->conf->{"matrix-bot"} } )->then( sub {
            $matrix->start;
        });
    } $loop;

    # Stagger room joins to avoid thundering-herd on the server
    my $delay = 0;

    $login_f->then( sub {
        Future->wait_all( map {
            my $bridge = $_;
            my $room_alias = $bridge->{"matrix-room"};

            $loop->delay_future( after => $delay++ )->then( sub {
                try_repeat_with_delay {
                    $matrix->join_room( $room_alias )
                } $loop
            })->on_done( sub {
                my ( $room ) = @_;
                warn "[Matrix] joined $room_alias\n";
                $self->{bot_matrix_rooms}{$room_alias} = $room;
                $self->{room_alias_for_id}{$room->room_id} = $room_alias;
            })
        } values %{ $self->{bridged_rooms} } );
    })
}

sub shutdown
{
    my $self = shift;

    print STDERR "TODO: Shutdown Matrix here\n";

    Future->done(1);
}

sub on_message
{
    my $self = shift;
    my ( $dist, $type, @args ) = @_;

    return if $type eq "matrix";

    warn "[Matrix] TODO - echo message out";
    Future->done;
}

sub _on_room_message
{
    my $self = shift;
    my ( $room, $from, $content ) = @_;

    my $room_alias = $self->{room_alias_for_id}{$room->room_id} or return;
    warn "[Matrix] in $room_alias: " . $content->{body} . "\n";

    my $bridge = $self->{bridged_rooms}{$room_alias} or return;

    my $msg = parse_formatted_message( $content );
    my $msgtype = $content->{msgtype};

    $self->dist->fire_sync( on_message => matrix => $bridge, $from, {
        msg     => $msg,
        msgtype => $msgtype,
    });
}

0x55AA;
