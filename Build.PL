#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use ScriptBuilder;

my $build = new ScriptBuilder(
	dist_version => '1.0',
	license => 'perl',
	module_name => 'KVM::Kavoom',
);
$build->add_build_element('pl');
$build->create_build_script;
