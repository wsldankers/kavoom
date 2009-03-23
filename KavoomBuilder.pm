use strict;
use warnings FATAL => 'all';

package KavoomBuilder;

use base qw(Module::Build);

sub process_pl_files {
	my $self = shift;
	my $files = $self->find_pl_files;
  
	while (my ($file, $to) = each %$files) {
		my @out;
		my $perl = $self->perl;
		foreach(@$to) {
			next if $self->up_to_date($file, $_);
			open my $fh, '>:raw', $_
				or die "$_: $!\n";
			push @out, $fh;
			print $fh, "#! $perl\n\n"
				or die "$_: $!\n";
		}
		next unless @out;
		open my $in, '<:raw', $file
			or die "$file: $!\n";
		while(<$in>) {
			foreach my $fh (@out) {
				print $fh, $_
					or die "can't write: $!\n";
			}
		}
		close $in;
		foreach my $fh (@out) {
			close $fh
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

	} else {
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
