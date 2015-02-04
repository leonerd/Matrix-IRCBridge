use strict;
use warnings;

use Module::Build;

Module::Build->new(
    module_name => 'MatrixBridge',
    requires => {
        'curry' => 0,
        'parent' => 0,
        'Digest::SHA' => 0,
        'Event::Distributor' => 0,
        'Future' => '0.29',
        'Net::Async::IRC' => 0,
        'Net::Async::Matrix' => '0.15',
        'Net::Async::Matrix::Utils' => 0,
        'IO::Async' => '0.63',
        'IO::Async::SSL' => 0,
        'IO::Socket::SSL' => 0,
        'String::Tagged::IRC' => '0.02',
        'YAML' => 0,
    },
    test_requires => {
        'Test::More' => 0.98,
    },
    recursive_test_files => 1,
    auto_configure_requires => 0, # Don't add M::B to configure_requires
    create_makefile_pl => 'small',
    create_readme => 1,
)->create_build_script;
