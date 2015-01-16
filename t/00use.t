#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use_ok( 'MatrixBridge' );
use_ok( 'MatrixBridge::Component' );

use_ok( 'MatrixBridge::Component::Matrix' );

done_testing;
