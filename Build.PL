#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use KavoomBuilder;

my $build = new KavoomBuilder(
	dist_version => '1.0',
	license => 'perl',
	module_name => 'KVM::Kavoom',
);
$build->add_build_element('pl');
$build->create_build_script;
