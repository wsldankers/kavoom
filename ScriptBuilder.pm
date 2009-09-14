use strict;
use warnings FATAL => 'all';

package ScriptBuilder;

use base qw(Module::Build);

use IO::File;
use File::Spec::Functions qw(catdir);

*file_qr = \&Module::Build::Base::file_qr;

sub installation_prefix {
	my $self = shift;
	return $self->install_base if defined $self->install_base;
	return $self->prefix if defined $self->prefix;
	return $self->original_prefix->{$self->installdirs};
}

sub _set_install_paths {
	my $self = shift;

	my $ret = $self->SUPER::_set_install_paths(@_);

	my $props = $self->{properties};
	my $config = $self->{config};

	my $install_sets = $props->{install_sets};
	while(my ($installtype, $installdirs) = each(%$install_sets)) {
		my $infix = $installtype eq 'core' ? '' : $installtype;
		my $prefix = $self->original_prefix->{$installtype};
		my $confdir = catdir($prefix eq '/usr' ? '/' : $prefix, 'etc')
			if defined $prefix;
		$installdirs->{conf} = $config->get("install${infix}conf") || $confdir
			unless exists $installdirs->{conf};
	}
	unless(exists $props->{install_base_relpaths}{conf}) {
		$props->{install_base_relpaths}{conf} = ['etc']
	}
	my $prefix_relpaths = $props->{prefix_relpaths};
	while(my ($installtype, $installdirs) = each(%$prefix_relpaths)) {
		$installdirs->{conf} = ['etc']
			unless exists $installdirs->{conf};
	}
	
	return $ret;
}

sub process_pl_files {
	my $self = shift;
	my $files = $self->find_pl_files;

	my $perl = $self->perl;
	my $prefix = $self->installation_prefix();
	my $sysconfdir = $self->install_destination('conf');

	my $script = catdir($self->blib, 'script');
	my $tmpdir = catdir($self->blib, 'tmp');
	File::Path::mkpath($script);
	File::Path::mkpath($tmpdir);

	while (my ($src, $dsts) = each %$files) {
		my @out;
		my @names;
		foreach my $dst (@$dsts) {
			my $base = File::Basename::basename($dst);
			my $to = File::Spec->catfile($script, $base);
			next if $self->up_to_date($src, $to);

			print STDERR "Building $src -> $to\n";
			push @names, $base;
			my $tmp = File::Spec->catfile($tmpdir, $base);
			my $fh = new IO::File($tmp, O_WRONLY|O_CREAT|O_TRUNC, 0777)
				or die "$to: $!\n";
			push @out, $fh;
			$fh->binmode;
			$fh->print("#! $perl\n\nmy \$prefix = '$prefix';\n")
				or die "$to: $!\n";
			if(defined $sysconfdir) {
				$fh->print("my \$sysconfdir = '$sysconfdir';\n\n")
					or die "$to: $!\n";
			} else {
				$fh->print("my \$sysconfdir;\n\n")
					or die "$to: $!\n";
				warn "\$sysconfdir not defined\n";
			}
		}
		next unless @out;
		my $in = new IO::File($src, O_RDONLY)
			or die "$src: $!\n";
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
		foreach my $base (@names) {
			my $to = File::Spec->catfile($script, $base);
			my $tmp = File::Spec->catfile($tmpdir, $base);
			rename($tmp, $to)
				or die "rename($tmp, $to): $!\n";
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
