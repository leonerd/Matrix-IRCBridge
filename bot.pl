#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010; # //
use Event::Distributor;
use IO::Async::Loop;
use YAML;
use Getopt::Long;
use Data::Dump qw( pp );

use constant MAX_IRC_LINE => 460; # Some number comfortably away from 512

binmode STDOUT, ":encoding(UTF-8)";
binmode STDERR, ":encoding(UTF-8)";

my $loop = IO::Async::Loop->new;
# Net::Async::HTTP + SSL + IO::Poll doesn't play well. See
#   https://rt.cpan.org/Ticket/Display.html?id=93107
ref $loop eq "IO::Async::Loop::Poll" and
    warn "Using SSL with IO::Poll causes known memory-leaks!!\n";

GetOptions(
   'C|config=s' => \my $CONFIG,
   'eval-from=s' => \my $EVAL_FROM,
) or exit 1;

if( defined $EVAL_FROM ) {
    # An emergency 'eval() this file' hack
    $SIG{HUP} = sub {
        my $code = do {
            open my $fh, "<", $EVAL_FROM or warn( "Cannot read - $!" ), return;
            local $/; <$fh>
        };

        eval $code or warn "Cannot eval() - $@";
    };
}

defined $CONFIG or die "Must supply --configfile\n";

my %CONFIG = %{ YAML::LoadFile( $CONFIG ) };

my $dist = Event::Distributor->new;

# Globally-defined signals
$dist->declare_signal( $_ ) for qw(
    add_bridge_config
    startup shutdown log
);

$dist->subscribe_sync( log => sub {
    my ( $dist, $component, @args ) = @_;
    my $cname = ( ref $component ) =~ s/^MatrixBridge::Component:://r;

    warn "[$cname] ", @args, "\n";
});

my @components;
foreach (qw( Matrix IRC )) {
    my $component_class = "MatrixBridge::Component::$_";
    require( "$component_class.pm" =~ s{::}{/}gr ) or
        die "Cannot load $component_class - $@";

    push @components, $component_class->new(
        loop => $loop,
        conf => \%CONFIG,
        dist => $dist,
    );
}

my %ROOM_FOR_CHANNEL;
my %CHANNEL_FOR_ROOM;
foreach ( @{ $CONFIG{bridge} } ) {
    $dist->fire_sync( add_bridge_config => $_ );

    my $room    = $_->{"matrix-room"};
    my $channel = $_->{"irc-channel"};

    $ROOM_FOR_CHANNEL{$channel} = $room;
    $CHANNEL_FOR_ROOM{$room} = $channel;
}

{
    my %pending_futures;

    sub adopt_future
    {
        my ( $f ) = @_;
        my $key = "$f"; # stable

        $pending_futures{$key} = $f;
        $f->on_ready( sub { delete $pending_futures{$key} } );
        $f->on_fail( sub {
            my ( $failure, $name, @args ) = @_;

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
        });
    }
}

$dist->subscribe_sync( on_matrix_message => sub {
    my ( $dist, %args ) = @_;

    my $irc_channel = $CHANNEL_FOR_ROOM{$args{room_name}} or return;

    my $user_id = $args{user_id};
    my $msgtype = $args{type};
    my $msg     = $args{message};

    # Mangle the Matrix user_id into something that might work on an IRC channel
    my ($irc_user) = $user_id =~ /^\@([^:]+):/;
    $irc_user =~ s{[^a-z0-9A-Z]+}{_}g;

    # Prefix the IRC username to make it clear they came from Matrix
    $irc_user = "$CONFIG{'irc-user-prefix'}-$irc_user";

    my $emote;
    my $notice;
    if( $msgtype eq 'm.text' ) {
        $emote = 0;
    }
    elsif( $msgtype eq 'm.emote' ) {
        $emote = 1;
    }
    elsif( $msgtype eq 'm.notice' ) {
        $notice = 1;
    }
    elsif( $msgtype eq 'm.image' ) {
        # We can't directly post an image URL onto IRC as the ghost user,
        # without it being unspoofable. Instead we'll have the bot user
        # /itself/ report on this fact
        #
        # Additionally, if the URL is an mxc://... URL, we'll have to convert
        # it to the HTTP content repository URL for non-matrix clients
        my $uri = URI->new( $args{content}{url} );
        if( $uri->scheme eq "mxc" ) {
            $uri = "https://$CONFIG{matrix}{server}/_matrix/media/v1/download/" . $uri->authority . $uri->path;
        }

        adopt_future( $dist->fire_async( send_irc_message =>
            channel => $irc_channel,
            as_bot  => 1,
            message => "<$irc_user> posted image: $uri - $msg",
        ) );
        return;
    }
    else {
        warn "  [Matrix] Unknown message type '$msgtype' - ignoring";
        return;
    }

    # IRC cannot cope with linefeeds
    foreach my $line ( $msg->split( qr/\n/ ) ) {
        $line = substr( $line, 0, MAX_IRC_LINE-3 ) . "..." if
            length( $line ) > MAX_IRC_LINE;

        warn "  [Matrix] sending message for $irc_user - $line\n";

        adopt_future( $dist->fire_async( send_irc_message =>
            nick      => $irc_user,
            ident     => $irc_user,
            channel   => $irc_channel,
            message   => $line,
            is_action => $emote,
            is_notice => $notice,
        ));
    }
});

$dist->subscribe_sync( on_irc_message => sub {
    my ( $dist, %args ) = @_;

    my $channel = $args{channel};
    my $message = $args{message};

    my $matrix_room = $ROOM_FOR_CHANNEL{$channel} or return;

    my $matrix_id = "irc_$args{ident}";

    warn "  [IRC] sending message for $matrix_id - $message\n";

    my $msgtype = $args{is_notice} ? "m.notice"
                : $args{is_action} ? "m.emote"
                                   : "m.text";

    adopt_future( $dist->fire_async( send_matrix_message =>
        user_id     => $matrix_id,
        displayname => "(IRC $args{nick})",
        room_name   => $matrix_room,
        type        => $msgtype,
        message     => $message->as_formatted,
    ));
});

print STDERR "**********\nMatrix <-> IRC bridge starting...\n**********\n";
$dist->fire_sync( startup => );

print STDERR "*****\nNow connected\n*****\n";

$loop->attach_signal(
    PIPE => sub { warn "pipe\n" }
);
$loop->attach_signal(
    INT => sub { $loop->stop },
);
$loop->attach_signal(
    TERM => sub { $loop->stop },
);

my $running = 1;
$loop->run;

print STDERR "**********\nMatrix <-> IRC bridge shutting down...\n**********\n";

$dist->fire_sync( shutdown => );
