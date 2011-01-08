use strict;
use warnings FATAL => 'all';
use utf8;

package KVM::Kavoom;

use Clarity -self;
use IO::File;
use IO::Socket::UNIX;
use Expect;

our $configdir;
our $statedir;
our $rundir;

sub configure() {
	my $file = shift;

	my %paths = (
		configdir => \$configdir,
		statedir => \$statedir,
		rundir => \$rundir,
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
field id;
field disks => [];
field nics => [];
field args;
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
			while(defined(local $_ = $mtab->getline)) {
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
	my $name = $_[0];
	die unless defined $name;

	die unless defined $configdir;
	die unless defined $statedir;
	die unless defined $rundir;

	my $id;
	if(open ID, '<', "$statedir/$name.id") {
		my $line = <ID>;
		chomp $line;
		$id = int($line);
		close ID or die;
	} else {
		my $seq;
		if(open SEQ, '<', "$statedir/.seq") {
			my $line = <SEQ>;
			chomp $line;
			$seq = int($line);
			close SEQ or die;
		} else {
			die "$statedir/.seq: $!\n"
				unless $!{ENOENT};
			$seq = 0;
		}
		$id = $seq++;

		open SEQ, '>', "$statedir/.seq,new"
			or die "Can't open $statedir/.seq,new for writing: $!\n";
		print SEQ "$seq\n" or die;
		close SEQ or die;

		open ID, '>', "$statedir/$name.id,new"
			or die "Can't open $statedir/$name.id,new for writing: $!\n";
		print ID "$id\n" or die;
		close ID or die;

		rename "$statedir/.seq,new", "$statedir/.seq"
			or die "Can't rename $statedir/.seq,new to $statedir/.seq: $!\n";
		rename "$statedir/$name.id,new", "$statedir/$name.id"
			or die "Can't rename $statedir/$name.id,new to $statedir/$name.id: $!\n";
	}
	die unless defined $id;

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

	$self = super(name => $name, id => $id, args => $args);
}

sub trim() {
	foreach(@_) {
		s/(^\s+|\s+$)//g;
		s/\s+/ /;
	}
}

sub bool() {
	local $_ = $_[0];
	return 1 if /^([yjt]|(on|1)$)/i;
	return 0 if /^([nf]|(off|0)$)/i;
	return $_[1];
}

our %keys; @keys{qw(mem cpus mac vnc disk drive acpi virtio aio cache tablet)} = ();

sub mem {
	my $args = $self->args;
	$args->{m} = int($_[0]);
}

sub cpus {
	my $args = $self->args;
	$args->{smp} = int($_[0])
}

sub mac {
	my $nics = $self->nics;
	push @$nics, $_[0]
}

sub vnc {
	my $id = $self->id;
	my $args = $self->args;
	$args->{vnc} = bool($_[0]) ? ":$id" : 'none'
}

sub tablet {
	return $self->{tablet} = bool($_[0])
		if $@;
	return exists $self->{tablet}
		? $self->{tablet}
		: $self->args->{vnc} ne 'none';
}

sub drive {
	my ($p) = map { s/^file=// ? $_ : () } split(',', $_[0]);
	die "Can't parse deprecated drive= statement\n"
		unless $p;
	$self->disk($p);
	warn "WARNING: interpreting deprecated drive=$_[0] as disk=$p\n";
}

sub disk {
	push @{$self->disks}, $_[0];
}

sub acpi {
	my $args = $self->args;
	if(bool($_[0])) {
		delete $args->{'no-acpi'};
	} else {
		undef $args->{'no-acpi'};
	}
}

sub virtio {
	my $args = $self->args;
	if(bool($_[0])) {
		$self->nictype('virtio');
		$self->disktype('virtio');
	} else {
		delete $self->{nictype};
		delete $self->{disktype};
	}
}

sub config {
	my $name = $self->name;
	my $file = @_ ? $_[0] : "$configdir/$name.cfg";

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

sub command {
	my @cmd = qw(kvm);

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
		die "No such file or directory: $disk\n" unless -e $disk;
		if(-b _) {
			$cache //= 'none';
			$aio //= 'native';
		}
		my %opt;
		$opt{cache} = $cache
			if defined $cache;
		$opt{aio} = $aio
			if defined $aio;
		$opt{boot} = 'on'
			unless $i++;
		push @cmd, -drive => keyval(file => $disk, if => $disktype, %opt);
	}

	push @cmd, @{$self->extra};

	return \@cmd;
}

sub sh {
	my $cmd = $self->command(@_);
	return join(' ', map { s|[^A-Z0-9_.,=:+/-]|\\$&|gi; $_ } @$cmd)
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
