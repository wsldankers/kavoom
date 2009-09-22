#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use Script::Build;

my $build = new Script::Build(
	module_name => 'KVM::Kavoom',
	dist_version => '1.1',
	dist_abstract => 'Manage KVM instances',
	dist_author => 'Wessel Dankers <wsl@fruit.je>',
	dist_abstract => 'Manage Linux KVM virtual machines',
	license => 'perl',
	create_makefile_pl => 'small'
);
$build->add_build_element('pl');
$build->create_build_script;
