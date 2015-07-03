package MatrixBridge::Component::Matrix;

use strict;
use warnings;
use base qw( MatrixBridge::Component );

use curry;
use Digest::SHA qw( hmac_sha1_base64 );
use Future;
use Future::Utils qw( try_repeat );

use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use Net::Async::Matrix 0.15; # enable_events, m.notice
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

        send_matrix_message
    );

    $dist->declare_signal( $_ ) for qw( on_matrix_message send_matrix_message );

    my $matrix_config = $self->{matrix_config} = {
        %{ $self->conf->{matrix} },
        # No harm in always applying this
        SSL_verify_mode => SSL_VERIFY_NONE,
    };

    my $matrix = Net::Async::Matrix->new(
        %$matrix_config,
        on_log => $self->curry::weak::log,
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

    $self->{user_matrix} = {};
    $self->{user_rooms} = {};

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
                $self->log( "joined $room_alias" );
                $self->{bot_matrix_rooms}{$room_alias} = $room;
                $self->{room_alias_for_id}{$room->room_id} = $room_alias;
            })
        } values %{ $self->{bridged_rooms} } );
    })
}

sub shutdown
{
    my $self = shift;

    # Code is a little neater to read this way
    Future->done->then_with_f( sub {
        return $_[0] unless $self->conf->{"remove-users-on-shutdown"} // 1;

        $self->log( "Removing ghost users from Matrix rooms" );

        my @rooms = map { values %$_ } values %{ $self->{user_rooms} };
        Future->wait_all( map {
            # These are all futures that (might) yield Rooms
            my $f = $_;
            $f->is_ready ? $f->get->leave->else_done() : ()
        } @rooms )
    })->then_with_f( sub {
        return $_[0] unless $self->conf->{"remove-bot-on-shutdown"} // 1;

        $self->log( "Removing bot from Matrix rooms" );

        my @rooms = values %{ $self->{bot_matrix_rooms} };
        Future->wait_all( map {
            # These are all Rooms directly
            $_->leave->else_done()
        } @rooms )
    });
}

sub _on_room_message
{
    my $self = shift;
    my ( $room, $from, $content ) = @_;

    my $user_id = $from->user->user_id;

    # Suppress messages from my own ghosts
    return if $self->{ghosted_userids}{$user_id};

    my $room_alias = $self->{room_alias_for_id}{$room->room_id} or return;
    $self->log( "message from $user_id in $room_alias: " . $content->{body} );

    $self->dist->fire_sync( on_matrix_message =>
        user_id   => $user_id,
        room_name => $room_alias,
        type      => $content->{msgtype},
        message   => parse_formatted_message( $content ),

        displayname => $from->user->displayname,
        content     => $content,
    );
}

sub _make_user
{
    my $self = shift;
    my ( $matrix_id, $displayname, %opts ) = @_;

    $self->log( "making new Matrix user for $matrix_id" );

    # Generate a password for this user
    my $password = hmac_sha1_base64( $matrix_id, $self->conf->{"matrix-password-key"} );

    my $user_matrix = Net::Async::Matrix->new(
        %{ $self->conf->{'matrix'} },
        enable_events => 0, # ghosts don't need to receive events
    );
    $self->{bot_matrix}->add_child( $user_matrix );

    return
        # Try first to log in as an existing user
        $user_matrix->login(
            user_id  => $matrix_id,
            password => $password,
        )
    ->else( sub {
        my ($failure) = @_;
        $self->log( "login as existing user failed - $failure" );

        return Future->fail( $failure ) if $opts{no_register};

        # If it failed, try to register an account
        $user_matrix->register(
            user_id => $matrix_id,
            password => $password,
            %{ $self->conf->{"matrix-register"} || {} },
        )
    })->then( sub {
        return Future->done unless defined $displayname;
        $user_matrix->set_displayname( $displayname );
    })->then( sub {
        $user_matrix->start->then_done( $user_matrix );
    })->on_done(sub {
        $self->log( "new Matrix user ready" );
    })->on_fail(sub {
        my ( $failure ) = @_;
        $self->log( "failed to register or login for new user - $failure" );
    });
}

sub _join_user_to_room
{
    my $self = shift;
    my ( $user_matrix, $room_name ) = @_;

    my $room_config = $self->{bridged_rooms}{$room_name};

    ( $room_config->{"matrix-needs-invite"} ?
        # Inviting an existing member causes an error; we'll have to ignore it
        $self->{bot_matrix_rooms}{$room_name}->invite( $user_matrix->myself->user_id )
            ->else_done() : # TODO(paul): a finer-grained error ignoring condition
        Future->done
    )->then( sub {
        $user_matrix->join_room( $room_name );
    });
}

sub _get_user_in_room
{
    my $self = shift;
    my ( $user_id, $displayname, $room_name, %opts ) = @_;

    ( $self->{user_matrix}{$user_id} ||= $self->_make_user( $user_id, $displayname, %opts )
        ->on_fail( sub { delete $self->{user_matrix}{$user_id} } )
    )->then( sub {
        my ( $user_matrix ) = @_;
        $self->{ghosted_userids}{$user_matrix->myself->user_id}++;

        my $user_rooms = $self->{user_rooms}{$user_id} //= {};

        return $user_rooms->{$room_name} //= $self->_join_user_to_room( $user_matrix, $room_name )
            ->on_fail( sub { delete $user_rooms->{$room_name} } );
    });
}

sub send_matrix_message
{
    my $self = shift;
    my ( $dist, %args ) = @_;

    my $user_id   = $args{user_id};
    my $room_name = $args{room_name};
    my $type      = $args{type};
    my $message   = $args{message};

    $self->_get_user_in_room( $user_id, $args{displayname}, $room_name )->then( sub {
        my ( $room ) = @_;
        $room->send_message(
            type => $type,
            %{ build_formatted_message( $message ) },
        )
    })->on_fail( sub {
        my ( $failure ) = @_;
        # If the ghost user isn't actually in the room, or was kicked and
        # we didn't notice (TODO: notice kicks), then this send will fail.
        # We won't bother retrying this but we should at least forget the
        # ghost's membership in the room, so next attempt will try to join
        # again.

        # SPEC TODO: we really need a nicer way to determine this.
        return unless @_ > 1 and $_[1] eq "http";
        my $resp = $_[2];
        return unless $resp and $resp->code == 403;
        my $err = eval { JSON->new->decode( $resp->decoded_content ) } or return;
        $err->{error} =~ m/^User \S+ not in room / or return;

        # Send failed because user wasn't in the room
        $self->log( "User isn't in the room after all" );
        delete $self->{user_rooms}{$user_id}{$room_name};
    });
}

0x55AA;
