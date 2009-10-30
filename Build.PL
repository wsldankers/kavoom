#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use Script::Build;

my $build = new Script::Build(
	module_name => 'KVM::Kavoom',
	dist_name => 'kavoom',
	dist_version => '1.4',
	dist_abstract => 'Manage Linux KVM virtual machine instances',
	dist_author => 'Wessel Dankers <wsl@fruit.je>',
	license => 'perl',
	create_makefile_pl => 'small'
);
$build->create_build_script;
