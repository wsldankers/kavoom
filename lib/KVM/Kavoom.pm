use strict;
use warnings FATAL => 'all';
use utf8;

package KVM::Kavoom;

use Clarity -self;
use IO::File;
use IO::Socket::UNIX;
use Fcntl;
use Expect;

our $configdir;
our $statedir;
our $rundir;
our $command = 'kvm';
our $prepare;

sub configure() {
	my $file = shift;

	my %paths = (
		configdir => \$configdir,
		statedir => \$statedir,
		rundir => \$rundir,
		command => \$command,
		prepare => \$prepare,
	);

	my $cfg = new IO::File($file, '<:utf8')
		or die "$file: $!\n";

	while(defined(local $_ = $cfg->getline)) {
		next if /^\s*($|#)/;
		my ($key, $val) = split('=', $_, 2);
		die "Malformed line at $file:$.\n"
			unless defined $val;
		trim($key, $val);

		die "Unknown configuration key '$key' at $file:@{[$cfg->input_line_number]}\n"
			unless exists $paths{$key};
		${$paths{$key}} = $val
	}
}

field name;
field disks => [];
field nics => [];
field extra => [];
field nictype => 'e1000';
field disktype => 'ide';
field cache => undef;
field aio => undef;

sub huge() {
	our $huge;
	unless(defined $huge) {
		$huge = '';
		eval {
			my $mtab = new IO::File('/proc/mounts', '<')
				or die;
			local $_;
			while(defined($_ = $mtab->getline)) {
				chomp;
				my @fields = split;
				$huge = $fields[1]
					if $fields[2] eq 'hugetlbfs';
			}
			$mtab->close;
		};
	}

	return $huge;
}

sub new {
	my $name = shift;
	die unless defined $name;

	die unless defined $configdir;
	die unless defined $statedir;
	die unless defined $rundir;

	$self = super(name => $name);
}

field args => sub {
	my $self = shift;
	my $name = $self->name;

	my $args = {
		name => $name,
		vnc => 'none',
		daemonize => undef,
		serial => "unix:$rundir/$name.serial,server,nowait",
		monitor => "unix:$rundir/$name.monitor,server,nowait",
		pidfile => "$rundir/$name.pid"
	};

	my $huge = huge();
	$args->{'mem-path'} = $huge
		if $huge ne '';

	return $args;
};

field id => sub {
	my $self = shift;
	my $name = $self->name;

	if(my $idfile = new IO::File("$statedir/$name.id", '<')) {
		my $line = $idfile->getline;
		chomp $line;
		die "Can't parse pid '$line' from $statedir/$name.id\n"
			unless $line =~ /^(?:0|[1-9]\d*)$/;
		$idfile->close or die;
		return int($line);
	}

	die "$statedir/$name.id: $!\n"
		unless $!{ENOENT};

	my $seq;
	if(my $seqfile = new IO::File("$statedir/.seq", '<')) {
		my $line = $seqfile->getline;
		chomp $line;
		$seq = int($line);
		$seqfile->close or die;
	} else {
		die "$statedir/.seq: $!\n"
			unless $!{ENOENT};
		$seq = 0;
	}
	my $id = $seq++;

	my $seqfile = new IO::File("$statedir/.seq,new", '>')
		or die "Can't open $statedir/.seq,new for writing: $!\n";
	$seqfile->write("$seq\n") or die "$statedir/.seq,new: $!\n";
	$seqfile->flush or die "$statedir/.seq,new: $!\n";
	$seqfile->sync or die "$statedir/.seq,new: $!\n";
	$seqfile->close or die "$statedir/.seq,new: $!\n";

	my $idfile = new IO::File("$statedir/$name.id,new", '>')
		or die "Can't open $statedir/$name.id,new for writing: $!\n";
	$idfile->write("$id\n") or die "$statedir/$name.id,new: $!\n";
	$idfile->flush or die "$statedir/$name.id,new: $!\n";
	$idfile->sync or die "$statedir/$name.id,new: $!\n";
	$idfile->close or die "$statedir/$name.id,new: $!\n";

	rename "$statedir/.seq,new", "$statedir/.seq"
		or die "Can't rename $statedir/.seq,new to $statedir/.seq: $!\n";
	rename "$statedir/$name.id,new", "$statedir/$name.id"
		or die "Can't rename $statedir/$name.id,new to $statedir/$name.id: $!\n";

	return $id;
};

sub trim() {
	foreach(@_) {
		s/(^\s+|\s+$)//g;
		s/\s+/ /;
	}
}

sub bool() {
	local $_ = shift;
	return 1 if /^([yjt]|(on|1)$)/i;
	return 0 if /^([nf]|(off|0)$)/i;
	return shift;
}

our %keys; @keys{qw(kvm prepare mem cpus mac vnc tablet drive disk acpi virtio aio cache)} = ();

sub mem {
	my $args = $self->args;
	$args->{m} = int(shift);
}

sub cpus {
	my $args = $self->args;
	$args->{smp} = int(shift);
}

sub mac {
	my $nics = $self->nics;
	push @$nics, shift;
}

sub vnc {
	my $id = $self->id;
	my $args = $self->args;
	$args->{vnc} = bool(shift) ? ":$id" : 'none'
}

sub tablet {
	return $self->{tablet} = bool(shift)
		if $@;
	return exists $self->{tablet}
		? $self->{tablet}
		: $self->args->{vnc} ne 'none';
}

sub drive {
	my $drive = shift;
	my ($p) = map { s/^file=// ? $_ : () } split(',', $drive);
	die "Can't parse deprecated drive= statement\n"
		unless $p;
	$self->disk($p);
	warn "WARNING: interpreting deprecated drive=$drive as disk=$p\n";
}

sub disk {
	push @{$self->disks}, shift;
}

sub acpi {
	my $args = $self->args;
	if(bool(shift)) {
		delete $args->{'no-acpi'};
	} else {
		undef $args->{'no-acpi'};
	}
}

sub virtio {
	my $args = $self->args;
	if(bool(shift)) {
		$self->nictype('virtio');
		$self->disktype('virtio');
		$args->{balloon} = 'virtio';
	} else {
		delete $self->{nictype};
		delete $self->{disktype};
		delete $args->{balloon};
	}
}

sub kvm {
	if(@_) {
		return $self->{kvm} = shift;
	} else {
		return $self->{kvm} // $command;
	}
}

sub prepare {
	if(@_) {
		return $self->{prepare} = shift;
	} else {
		return $self->{prepare} // $prepare;
	}
}

sub config {
	my $name = $self->name;
	my $file = @_ ? shift : "$configdir/$name.cfg";

	my $cfg = new IO::File($file, '<')
		or die "Can't open $file: $!\n";

	while(defined(local $_ = $cfg->getline)) {
		next if /^\s*($|#)/;
		trim($_);
		if(ord == 45) { # -
			my ($key, $val) = split(' ', $_, 2);
			my $extra = $self->extra;
			push @$extra, $key;
			push @$extra, $val if defined $val;
		} else {
			my ($key, $val) = split('=', $_, 2);
			die "Malformed line at $cfg:$.\n"
				unless defined $val;
			trim($key, $val);
			my $lkey = lc $key;
			die "unknown configuration parameter at $file:@{[$cfg->input_line_number]}: $key\n"
				unless exists $keys{$lkey};
			$self->$lkey($val);
		}
	}
}

sub keyval() {
	my @args;
	while(@_) {
		my $key = shift;
		my $val = shift;
		if(defined $val) {
			$val =~ s/,/,,/g;
			push @args, "$key=$val";
		} else {
			push @args, $key;
		}
	}
	return join(',', @args);
}

sub running {
	my $name = $self->name;
	my $fh = new IO::File("$rundir/$name.pid", '+<');
	return undef unless $fh;
	return undef if fcntl($fh, F_SETLK, pack('ssQQl', F_WRLCK, SEEK_CUR));
	return 1 if $!{EAGAIN};
	die "fcntl($rundir/$name.pid, F_SETLK): $!\n";
}

sub command {
	my @cmd = ($self->kvm, 'kvm');

	my $name = $self->name;
	my $id = $self->id;

	my $args = $self->args;
	while(my ($key, $val) = each(%$args)) {
		push @cmd, "-$key";
		push @cmd, $val
			if defined $val;
	}

	push @cmd, -usbdevice => 'tablet'
		if $self->tablet;

	my $nics = $self->nics;
	my $nictype = $self->nictype;
	my $i = 0;
	foreach my $mac (@$nics) {
		push @cmd,
			-net => keyval(tap => undef, vlan => $i, ifname => $name.$i),
			-net => keyval(nic => undef, vlan => $i, model => $nictype, macaddr => $mac);
		$i++;
	}
	push @cmd, -net => 'none'
		unless $i;

	my $disks = $self->disks;
	my $disktype = $self->disktype;
	undef $i;
	foreach my $disk (@$disks) {
		my $cache = $self->cache;
		my $aio = $self->aio;
		my %opt;
		die "No such file or directory: $disk\n" unless -e $disk;
		if(-b _) {
			$cache //= 'none';
			$aio //= 'native';
			$opt{format} = 'raw';
		}
		$opt{cache} = $cache if defined $cache;
		$opt{aio} = $aio if defined $aio;
		$opt{boot} = 'on' unless $i++;
		push @cmd, -drive => keyval(file => $disk, if => $disktype, %opt);
	}

	push @cmd, @{$self->extra};

	return \@cmd;
}

sub sh {
	my $cmd = $self->command(@_);
	my $prog = shift @$cmd;
	shift @$cmd;
	return join(' ', map { s|[^A-Z0-9_.,=:+/-]|\\$&|gi; $_ } ($prog, @$cmd))
}

sub socket {
	my $name = $self->name;
	my $type = shift;
	my $sock = new IO::Socket::UNIX(
		Peer => "$rundir/$name.$type",
		Type => SOCK_STREAM,
		Timeout => 1,
		@_
	);
	unless(defined $sock) {
		return undef if $!{ECONNREFUSED};
		die "can't create socket: $!\n";
	}
	my $exp = Expect->exp_init($sock);
	die "can't create Expect object: $!\n" unless defined $exp;
	return $exp;
}

sub monitor {
	return $self->socket('monitor')
}

sub serial {
	return $self->socket('serial')
}
