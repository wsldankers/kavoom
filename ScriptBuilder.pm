use strict;
use warnings FATAL => 'all';

package ScriptBuilder;

use base qw(Module::Build);

use IO::File;

*file_qr = \&Module::Build::Base::file_qr;

sub process_pl_files {
	my $self = shift;
	my $files = $self->find_pl_files;
  
	while (my ($file, $to) = each %$files) {
		my @out;
		my $perl = $self->perl;
		foreach(@$to) {
			next if $self->up_to_date($file, $_);
			my $fh = new IO::File($_, O_WRONLY|O_CREAT|O_TRUNC, 0777)
				or die "$_: $!\n";
			push @out, $fh;
			$fh->binmode;
			$fh->print("#! $perl\n\n")
				or die "$_: $!\n";
		}
		next unless @out;
		my $in = new IO::File($file, O_RDONLY)
			or die "$file: $!\n";
		$in->binmode;
		while(<$in>) {
			foreach my $fh (@out) {
				$fh->print($_)
					or die "can't write: $!\n";
			}
		}
		$in->close;
		foreach my $fh (@out) {
			$fh->close
				or die "can't close: $!\n";
		}
		$self->add_to_cleanup(@$to);
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
	} elsif(defined $files) {
		die "'pl_files' must be a hash reference or array reference";
	}
  
	return unless -d 'script';
	return {
		map {$_, [/^(.*)\.pl$/i]} @{
			$self->rscan_dir('script', file_qr('\.pl$'))
		}
	};
}

1
