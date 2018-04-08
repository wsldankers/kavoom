#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use Module::Build;
use File::Find;

my ($debian_changelog_version) = do {
	my $fh = new IO::File('debian/changelog')
		or die "open(debian/changelog): $!\n";
	my $line = <$fh> // die "read(debian/changelog): $!\n";
	$fh->close;
	$line =~ /\(([^\)]+)\)/
} or die "can't parse debian/changelog\n";

do {
	# create the MANIFEST file on the fly
	my $fh = new IO::File('MANIFEST', '>')
		or die "open(MANIFEST): $!\n";
	find({wanted => sub {
		return unless -f;
		print $fh "$_\n" or die "write(MANIFEST): $!\n";
	}, no_chdir => 1, follow => 0}, qw(lib));
	$fh->close or die "close(MANIFEST): $!\n";
};

my $build = new Module::Build(
	module_name => 'KVM::Kavoom',
	dist_name => 'kavoom',
	dist_version => $debian_changelog_version,
	dist_abstract => 'Manage Linux KVM virtual machine instances',
	dist_author => 'Wessel Dankers <wsl@fruit.je>',
	license => 'perl',
	script_files => [],
	create_makefile_pl => 'small'
);
$build->create_build_script;
