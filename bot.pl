#!/usr/bin/env perl 
use strict;
use warnings;
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use JSON::MaybeXS;
use IO::Async::Loop;
use Net::Async::IRC;
use Net::Async::Matrix 0.07;
use YAML;
use Getopt::Long;

my $loop = IO::Async::Loop->new;

GetOptions(
   'C|config=s' => \my $CONFIG,
) or exit 1;

defined $CONFIG or die "Must supply --configfile\n";

my %CONFIG = %{ YAML::LoadFile( $CONFIG ) };

my %MATRIX_CONFIG = %{ $CONFIG{matrix} };
# No harm in always applying this
$MATRIX_CONFIG{SSL_verify_mode} = SSL_VERIFY_NONE;

my $MATRIX_ROOM = $CONFIG{bridge}{"matrix-room"};

my %IRC_CONFIG = %{ $CONFIG{irc} };

my $IRC_CHANNEL = $CONFIG{bridge}{"irc-channel"};

# IRC instances corresponding to Matrix IDs
my %irc;

my $json = JSON::MaybeXS->new(
	utf8 => 1,
	pretty => 1
);

# Predeclare way ahead of time, we may want to be sending messages on this eventually
my $irc;

my %matrix_rooms;
my $matrix = Net::Async::Matrix->new(
	%MATRIX_CONFIG,
	on_log => sub { warn "log: @_\n" },
	on_room_new => sub {
		my ($matrix, $room) = @_;
		warn "Have a room: " . $room->name . "\n";

		$matrix_rooms{$room->room_id} = $room;

		$room->configure(
			on_message => sub {
				my ($room, $from, $content) = @_;
				warn "Message in " . $room->name . ": " . $content->{body};

				# Mangle the Matrix user_id into something that might work on an IRC channel
				my ($irc_user) = $from->user->user_id =~ /^\@([^:]+):/;
				$irc_user =~ s{[^a-z0-9A-Z]+}{_}g;

				# so this would want to be changed to match on content instead, if we
				# want users to be able to use IRC and Matrix users interchangeably
				if($irc_user =~ /^irc_/) {
					warn "this was a message from an IRC user, ignoring\n";
					return
				} 

				# Prefix the IRC username to make it clear they came from Matrix
				$irc_user = "Mx-$irc_user";

				# the "user IRC" connection
				my $ui;
				unless(exists $irc{lc $irc_user}) {
					warn "Creating new IRC user for $irc_user\n";
					$ui = Net::Async::IRC->new(
						user => $irc_user
					);
					$loop->add($ui);
					$irc{lc $irc_user} = $ui->login(
						nick => $irc_user,
						%IRC_CONFIG,
					)->then(sub {
						Future->needs_all(
							$ui->send_message( "JOIN", undef, $IRC_CHANNEL),
							# could notify someone if we want to track user creation
							# $ui->send_message( "PRIVMSG", undef, "tom_m", "i exist" )
						)
					})->transform(
						done => sub { $ui },
						fail => sub { warn "something went wrong... @_"; 1 }
					)
				}
				my $msg = $content->{body};
				my $msgtype = $content->{msgtype};
				warn "Queue message for IRC as $irc_user\n";
				my $f = $irc{lc $irc_user}->then(sub {
					my $ui = shift;
					warn "sending message for $irc_user - $msg\n";
					if($msgtype eq 'm.text') {
						return $ui->send_message( "PRIVMSG", undef, $IRC_CHANNEL, $msg);
					} elsif($msgtype eq 'm.emote') {
						return $ui->send_ctcp(undef, $IRC_CHANNEL, "ACTION", $msg);
					} else {
						warn "unknown type $msgtype\n";
					}
				}, sub { warn "unexpected error - @_\n"; Future->done });
				$f->on_ready(sub { undef $f });
			}
		);
	},
	on_error => sub {
		print STDERR "Matrix failure: @_\n";
	},
);
$loop->add( $matrix );

$matrix->login( %{ $CONFIG{"matrix-bot"} } )->get;
$matrix->start->get; # await room initialSync

# We should now be started up
$matrix_rooms{$MATRIX_ROOM} or
	$matrix->join_room($MATRIX_ROOM)->get;

$irc = Net::Async::IRC->new(
	on_message_ctcp_ACTION => sub {
		my ( $self, $message, $hints ) = @_;
		warn "CTCP action";
		return if exists $irc{lc $hints->{prefix_name}};
		warn "we think we should do this one";
		my $irc_user = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{ctcp_args};
		my $f = get_or_make_matrix_user( $irc_user )->then(sub {
			my ($room) = @_;
			warn "Sending emote $msg\n";
			$room->send_message(
				type => 'm.emote',
				body => $msg,
			)
		});
		$f->on_ready(sub { undef $f });
	},
	on_message_text => sub {
		my ( $self, $message, $hints ) = @_;
		warn "text message";
		return if $hints->{is_notice};
		return if exists $irc{lc $hints->{prefix_name}};
		warn "we think we should do this one";
		my $irc_user = "irc_" . $hints->{prefix_name};
		my $msg = $hints->{text};
		my $f = get_or_make_matrix_user( $irc_user )->then(sub {
			my ($room) = @_;
			warn "Sending text $msg\n";
			$room->send_message(
				type => 'm.text',
				body => $msg,
			)
		});
		$f->on_ready(sub { undef $f });
	},
	on_error => sub {
		print STDERR "IRC failure: @_\n";
	},
);

$loop->add( $irc );

# These parameters would normally be configurable
my $f;
$f = $irc->login(
	%IRC_CONFIG,
	%{ $CONFIG{"irc-bot"} },
)->then(sub {
	$irc->send_message( "JOIN", undef, $IRC_CHANNEL);
})->on_ready(sub { undef $f });

$loop->attach_signal(
	PIPE => sub { warn "pipe\n" }
);
$loop->attach_signal(
	INT => sub { $loop->stop },
);
$loop->attach_signal(
	TERM => sub { $loop->stop },
);
eval {
   $loop->run;
} or my $e = $@;

# When the bot gets shut down, have it leave the room so it's clear to observers
# that it is no longer running.
$matrix_rooms{$MATRIX_ROOM}->leave->get;

die $e if $e;

exit 0;

# this bit establishes the per-user IRC connection
my %matrix_users;
sub get_or_make_matrix_user
{
	my ($irc_user) = @_;
	return $matrix_users{$irc_user} ||= _make_matrix_user($irc_user);
}

sub _make_matrix_user
{
	my ($irc_user) = @_;

	my $user_matrix = Net::Async::Matrix->new(
		%MATRIX_CONFIG,
	);
	$matrix->add_child( $user_matrix );

	(
		# Try to register a new user
		$user_matrix->register(
			user_id => $irc_user,
			password => 'nothing',
			%{ $CONFIG{"matrix-register"} || {} },
		)
	)->else( sub {
		# If it failed, log in as existing one
		$user_matrix->login(
			user_id => $irc_user,
			password => 'nothing',
		)
	})->then( sub {
		$user_matrix->start;
	})->then( sub {
		$matrix_users{$irc_user} = $user_matrix->join_room($MATRIX_ROOM);
	})->on_done(sub {
		my ($room) = @_;
		warn "New Matrix user ready with room: $room\n";
	});
}
