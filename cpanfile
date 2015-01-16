requires 'curry', 0;
requires 'parent', 0;
requires 'Event::Distributor', 0;
requires 'Future', '>= 0.29';
requires 'Net::Async::IRC', 0;
requires 'Net::Async::Matrix', '>= 0.08';
requires 'Net::Async::Matrix::Utils';
requires 'IO::Async', '>= 0.63';
requires 'IO::Async::SSL', 0;
requires 'IO::Socket::SSL', 0;
requires 'String::Tagged::IRC', '>= 0.02';
requires 'YAML', 0;
requires 'Digest::SHA', 0;

on 'test' => sub {
	requires 'Test::More', '>= 0.98';
};

