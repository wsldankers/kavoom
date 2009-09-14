#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use ScriptBuilder;

my $build = new ScriptBuilder(
	module_name => 'KVM::Kavoom',
	dist_version => '1.0',
	dist_abstract => 'Manage KVM instances',
	license => 'perl',
	create_makefile_pl => 'small'
);
$build->add_build_element('pl');
$build->create_build_script;
