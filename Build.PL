#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use Module::Build;

my $build = new Module::Build(
	module_name => 'KVM::Kavoom',
	license => 'perl'
);

$build->create_build_script;
