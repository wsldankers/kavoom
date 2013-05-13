use strict;
use warnings FATAL => 'all';
use utf8;

package KVM::Kavoom;

use Clarity -self;
use IO::File;
use IO::Socket::UNIX;
use Fcntl;
use Expect;
use Digest::MD5 qw(md5_base64);

our $configdir;
our $statedir;
our $rundir;
our $kvm = 'kvm';

sub configure() {
	my $file = shift;

	my %paths = (
		configdir => \$configdir,
		statedir => \$statedir,
		rundir => \$rundir,
		kvm => \$kvm,
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
field virtio => undef;
field cache => undef;
field aio => undef;
field serialport => 0;
field kvm => sub { $kvm };
field vhost_net => sub { -e '/dev/vhost-net' };

sub huge() {
	our $huge;
	unless(defined $huge) {
		$huge = '';
		my $mtab = new IO::File('/proc/mounts', '<')
			or return $huge;
		local $_;
		while(defined($_ = $mtab->getline)) {
			chomp;
			next if /^\s*#/;
			next unless /^((?:[^ \t\\]|\\.)+)[ \t]+((?:[^ \t\\]|\\.)+)[ \t]+((?:[^ \t\\]|\\.)+)[ \t]/;
			$huge = $2 if $3 eq 'hugetlbfs';
		}
		$mtab->close;
	}

	return $huge;
}

sub new {
	my $name = shift;
	die unless defined $name;

	die unless defined $configdir;
	die unless defined $statedir;
	die unless defined $rundir;

	return super(name => $name);
}

field args => sub {
	my $self = shift;
	my $name = $self->name;

	my $args = {
		vnc => 'none',
		daemonize => undef,
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
	die "missing value\n" unless defined;
	return 1 if /^(?:on|yes|1|enabled?|true)$/i;
	return 0 if /^(?:off|no|0|disabled?|false)$/i;
	die "unable to parse '$_' as a boolean value\n";
}

sub set_mem {
	my $args = $self->args;
	$args->{m} = int(shift);
}

sub set_cpus {
	my $args = $self->args;
	$args->{smp} = int(shift);
}

sub set_mac {
	my $nics = $self->nics;
	push @$nics, shift;
}

sub set_vnc {
	my $id = $self->id;
	$self->args->{vnc} = bool(shift) ? ":$id" : 'none';
}

sub set_tablet {
	$self->tablet(bool(shift));
}

sub tablet {
	return $self->{tablet} = shift if @_;
	return exists $self->{tablet}
		? $self->{tablet}
		: $self->args->{vnc} ne 'none';
}

sub set_serial {
	local $_ = shift;
	if(/^(?:ttyS)?(\d+)$/) {
		$self->serialport(int($1));
	} elsif(/^(?:COM)([1-9]\d*)$/) {
		$self->serialport(int($1) - 1);
	} elsif(/^none$/i) {
		$self->serialport(undef);
	} else {
		die "unknown serial port '$_'\n";
	}
}

sub set_drive {
	my $drive = shift;
	my ($p) = map { s/^file=// ? $_ : () } split(',', $drive);
	die "can't parse deprecated drive= statement\n"
		unless $p;
	$self->disk($p);
	warn "WARNING: interpreting deprecated drive=$drive as disk=$p\n";
}

sub set_disk {
	push @{$self->disks}, shift;
}

sub set_cache {
	$self->cache(shift);
}

sub set_acpi {
	my $args = $self->args;
	if(bool(shift)) {
		delete $args->{'no-acpi'};
	} else {
		undef $args->{'no-acpi'};
	}
}

sub set_virtio {
	$self->virtio(bool(shift));
}

sub set_kvm {
	$self->kvm(shift);
}

sub nictype {
	return $self->virtio ? 'virtio-net' : 'e1000';
}

sub disktype {
	return $self->virtio ? 'virtio-blk' : 'ide-hd';
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
			eval {
				my ($key, $val) = split('=', $_, 2);
				die "malformed line\n"
					unless defined $val;
				trim($key, $val);
				my $lkey = 'set_'.lc($key);
				die "unknown configuration parameter '$key'\n"
					unless $self->can($lkey);
				eval { $self->$lkey($val) };
				die "$key: $@" if $@;
			};
			if(my $err = $@) {
				my $line = $cfg->input_line_number;
				die "$file:$line: $@";
			}
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

	my $flock = pack('ssQQl', F_WRLCK, SEEK_CUR);
	die "fcntl($rundir/$name.pid, F_GETLK): $!\n"
		unless fcntl($fh, F_GETLK, $flock);
	my ($type) = unpack('ssQQl', $flock);
	return $type == F_WRLCK;
}

sub command {
	my @cmd = ($self->kvm, -name => $self->name);

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

	if(defined $self->serialport) {
		for(my $i = 0; $i < 4; $i++) {
			push @cmd,
				-chardev => keyval(socket => undef, server => undef, nowait => undef, id => "serial-$i", path => "$rundir/$name.serial-$i"),
				-device => keyval('isa-serial' => undef, chardev => "serial-$i");

		}
	} else {
		push @cmd, -serial => 'none';
	}

	if($self->virtio) {
		push @cmd, -device => 'virtio-balloon';
		push @cmd, -device => 'virtio-serial';
		for(my $i = 0; $i < 8; $i++) {
			push @cmd,
				-chardev => keyval(socket => undef, server => undef, nowait => undef, id => "console-$i", path => "$rundir/$name.console-$i"),
				-device => keyval(virtconsole => undef, chardev => "console-$i", name => "hvc$i");
		}
	}

	my $nics = $self->nics;
	my $nictype = $self->nictype;
	my @vhost_net = (vhost => 'on')
		if $self->vhost_net;
	while(my ($i, $mac) = each @$nics) {
		push @cmd,
			-netdev => keyval(tap => undef, id => "net-$i", ifname => $name.$i, @vhost_net),
			-device => keyval($nictype => undef, netdev => "net-$i", mac => $mac);
	}
	push @cmd, -net => 'none'
		unless @$nics;

	my $disks = $self->disks;
	my $disktype = $self->disktype;
	while(my ($i, $disk) = each @$disks) {
		my $cache = $self->cache;
		my $aio = $self->aio;
		my %opt;
		die "No such file or directory: $disk\n"
			unless -e $disk;
		if(-b _) {
			$cache //= 'none';
			$aio //= 'native';
			$opt{format} = 'raw';
		}
		my $serial = substr(md5_base64($disk), 0, 20);
		$serial =~ tr{+/}{XY};
		$opt{serial} = $serial;
		$opt{cache} = $cache if defined $cache;
		$opt{aio} = $aio if defined $aio;
		push @cmd, -drive => keyval(file => $disk, id => "blk-$i", if => 'none', %opt);
		push @cmd, -device => keyval($disktype => undef, drive => "blk-$i");
	}

	push @cmd, @{$self->extra}, @_;

	return \@cmd;
}

sub sh {
	my $cmd = $self->command(@_);
	return join(' ', map { s|[^A-Z0-9_.,=:+/-]|\\$&|gi; $_ } @$cmd)
}

sub socket_path {
	my $type = shift;
	my $name = $self->name;
	return "$rundir/$name.$type";
}

sub socket {
	my $type = shift;
	my $sock = new IO::Socket::UNIX(
		Peer => $self->socket_path($type),
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
	return $self->socket('monitor');
}

sub serial {
	my $num = shift;
	my $serialport = $self->serialport;
	$num //= $serialport // 0;
	die "no serial ports configured\n"
		unless defined $serialport || -e $self->socket_path('serial-0');
	return $self->socket("serial-$num");
}

sub console {
	my $num = shift // 0;
	my $path = $self->socket_path("console-$num");
	die "console only available with virtio=yes\n"
		unless $self->virtio || -e $self->socket_path('console-0');
	return $self->socket("console-$num");
}
