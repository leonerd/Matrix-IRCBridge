package MatrixBridge::Component;

use strict;
use warnings;

sub new
{
    my $class = shift;
    my %args = @_;

    my $self = bless {
        loop => $args{loop},
        conf => $args{conf},
        dist => $args{dist},
    }, $class;

    $self->init if $self->can( 'init' );

    return $self;
}

sub loop { shift->{loop} }
sub conf { shift->{conf} }
sub dist { shift->{dist} }

sub log
{
    my $self = shift;
    $self->dist( log => $self, @_ );
}

0x55AA;
