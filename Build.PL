#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';

package Script::Build;

use base qw(Module::Build);

sub compile_pl_file {
	my $self = shift;
	my $from = shift;
	my @to = @_;

	foreach
}

sub process_pl_files {
	my $self = shift;
	my $files = $self->find_pl_files;
  
	while (my ($file, $to) = each %$files) {
		unless($self->up_to_date($file, $to)) {
			$self->run_perl_script($file, [], [@$to]) or die "$file failed";
			$self->add_to_cleanup(@$to);
		}
	}
}

sub find_pl_files {
	my $self = shift;
	my $files = $self->{properties}{pl_files};
    if(UNIVERSAL::isa($files, 'ARRAY')) {
		return {
				map {$_, [/^(.*)\.pl$/]}
				map $self->localize_file_path($_),
				@$files
			};
	} elsif(UNIVERSAL::isa($files, 'HASH')) {
		my %out;
		while(my ($file, $to) = each %$files) {
			$out{$self->localize_file_path($file)} = [
				map $self->localize_file_path($_), ref $to ? @$to : ($to)
			];
		}
		return \%out;

		} else {
			die "'pl_files' must be a hash reference or array reference";
		}
	}
  
	return unless -d 'script';
	return {
		map {$_, [/^(.*)\.pl$/i]} @{
			$self->rscan_dir('script', file_qr('\.pl$'))
		}
	};
}


package main;

my $build = new Script::Build(
	dist_version => '1.0',
	license => 'perl',
	module_name => 'KVM::Kavoom',
	script_files => 'scripts/kavoom',
);

$build->create_build_script;
