package KVM::Kavoom::Instance;

use re '/aa';

use Class::Clarity -self;

use IO::File;
use IO::Socket::UNIX;
use File::Copy qw(copy);
use Fcntl;
use Expect;
use Digest::MD5 qw(md5_base64);

field config;
field name;

sub configvar(*@) {
    my $name = shift;
	if(@_) {
		my ($postproc, @args) = @_;
		my $isset = "${name}_isset";
		field($name, sub {
			my $self = shift;
			my $config = $self->config;
			return $config->$isset
				? $config->$name
				: $postproc->($self, @args);
		});
	} else {
		field($name, sub { shift->config->$name });
	}
}

configvar configdir;
configvar statedir;
configvar rundir;
configvar disks;
configvar nics;
configvar extra;
configvar sections;
configvar virtio;
configvar virtconsole;
configvar cache;
configvar aio;
configvar serialport;
configvar kvm;
configvar usb;
configvar vnc;
configvar mem;
configvar cpus;
configvar acpi;
configvar platform;
configvar ovmfdir;
configvar chipset => sub {
	my $platform = $self->platform;
	return undef unless defined $platform;
	return undef if $platform eq 'bios';
	return 'q35';
};
configvar tablet => sub {
	return exists $self->{tablet}
		? $self->{tablet}
		: $self->{vnc};
};
configvar hugepages => sub {
	my $hugepages;

	my $mtab = new IO::File('/proc/mounts', '<')
		or return undef;
	local $_;
	while(defined($_ = $mtab->getline)) {
		chomp;
		next if /^\s*#/;
		next unless /^((?:[^ \t\\]|\\.)+)[ \t]+((?:[^ \t\\]|\\.)+)[ \t]+((?:[^ \t\\]|\\.)+)[ \t]/;
		$hugepages = $2 if $3 eq 'hugetlbfs';
	}
	$mtab->close;

	return $hugepages;
};

field lock => sub {
	my $name = $self->name;
	my $statedir = $self->statedir;

	my $statedir_lock = new IO::File($statedir)
		or die "open($statedir): $!\n";
	flock($statedir_lock, Fcntl::LOCK_EX)
		or die "flock($statedir): $!\n";

	if(my $idfile = new IO::File("$statedir/$name.id", '<')) {
		flock($idfile, Fcntl::LOCK_EX)
			or die "flock($statedir): $!\n";
		$statedir_lock->close or die;

		my $line = $idfile->getline;
		chomp $line;
		die "can't parse pid '$line' from $statedir/$name.id\n"
			unless $line =~ /^(?:0|[1-9]\d*)\z/;
		my $id = int($line);
		die "can't parse pid '$line' from $statedir/$name.id\n"
			unless "$id" eq $line;

		return [$id, $idfile];
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
		or die "can't open $statedir/.seq,new for writing: $!\n";
	$seqfile->write("$seq\n") or die "$statedir/.seq,new: $!\n";
	$seqfile->flush or die "$statedir/.seq,new: $!\n";
	$seqfile->sync or die "$statedir/.seq,new: $!\n";
	$seqfile->close or die "$statedir/.seq,new: $!\n";

	my $idfile = new IO::File("$statedir/$name.id,new", '>')
		or die "can't open $statedir/$name.id,new for writing: $!\n";
	$idfile->write("$id\n") or die "$statedir/$name.id,new: $!\n";
	$idfile->flush or die "$statedir/$name.id,new: $!\n";
	$idfile->sync or die "$statedir/$name.id,new: $!\n";
	flock($idfile, Fcntl::LOCK_EX) or die "$statedir/$name.id,new: $!\n";

	rename "$statedir/.seq,new", "$statedir/.seq"
		or die "can't rename $statedir/.seq,new to $statedir/.seq: $!\n";
	rename "$statedir/$name.id,new", "$statedir/$name.id"
		or die "can't rename $statedir/$name.id,new to $statedir/$name.id: $!\n";

	return [$id, $idfile];
};

sub id {
	return $self->lock->[0];
}

field vhost_net => sub { -e '/dev/vhost-net' };

sub nictype {
	return $self->virtio ? 'virtio-net' : 'e1000';
}

sub disktype {
	return $self->virtio ? 'virtio-blk' : 'ide-hd';
}

sub running {
	my $rundir = $self->rundir;
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
	my $devices = $self->devices_path;
	my $rundir = $self->rundir;
	my $name = $self->name;
	my $id = $self->id;

	my @cmd = ($self->kvm,
		-name => $name,
		-pidfile => "$rundir/$name.pid",
		-readconfig => $devices,
		-daemonize,
		-nodefaults,
		-vga => 'cirrus',
	);

	push @cmd, '-no-acpi'
		if !$self->acpi;

	push @cmd, -usbdevice => 'tablet'
		if $self->tablet;

	my $hugepages = $self->hugepages;
	push @cmd, '-mem-path' => $hugepages
		if defined $hugepages;

	push @cmd, @{$self->extra}, @_;

	return \@cmd;
}

sub sh {
	my $cmd = $self->command(@_);
	return join(' ', map { s|[^A-Z0-9_.,=:+/%\@-]|\\$&|gi; $_ } @$cmd)
}

sub socket_path {
	my $type = shift;
	my $rundir = $self->rundir;
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

sub qmp {
	return $self->socket('qmp');
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
	die "console only available with console=yes\n"
		unless $self->virtconsole || -e $self->socket_path('console-0');
	return $self->socket("console-$num");
}

sub devices_path {
	my $statedir = $self->statedir;
	my $name = $self->name;
	return "$statedir/$name.devices";
}

sub devices_stanza {
	my $fh = shift;
	my $name = shift;
	my $id = shift;

	if(defined $id) {
		$fh->write("[$name \"$id\"]\n")
			or die "write error: $!\n";
	} else {
		$fh->write("[$name]\n")
			or die "write error: $!\n";
	}

	while(@_) {
		my $key = shift;
		my $val = shift;
		utf8::encode($val);
		die "value '$val' invalid because it contains quotes\n"
			if $val =~ /"/;
		die "value '$val' too long\n"
			if length($val) > 1023;
		$fh->write(" $key = \"$val\"\n")
			or die "write error: $!\n";
	}

	$fh->write("\n")
		or die "write error: $!\n";
}

sub devices_write {
	my $fh = shift;
	my $rundir = $self->rundir;
	my $statedir = $self->statedir;
	my $name = $self->name;

	$fh->write("# qemu config file\n\n")
		or die "write error: $!\n";

	$self->devices_stanza($fh, name => undef, guest => $name);

	my $cpus = $self->cpus;
	$self->devices_stanza($fh, 'smp-opts' => undef, cpus => $cpus)
		if defined $cpus;

	my $mem = $self->mem;
	$self->devices_stanza($fh, memory => undef, size => $mem)
		if defined $mem;

	my $chipset = $self->chipset;
	my @chipset = (type => $chipset) if defined $chipset;
	my @usb = (usb => 'on') if $self->usb;
	if(my @machine = (@chipset, @usb)) {
		$self->devices_stanza($fh, machine => undef, @machine);
	}

	$self->devices_stanza($fh, chardev => 'monitor',
		backend => 'socket',
		server => 'on',
		wait => 'off',
		path => "$rundir/$name.monitor",
	);

	$self->devices_stanza($fh, mon => 'monitor',
		mode => 'readline',
		chardev => 'monitor',
	);

	$self->devices_stanza($fh, chardev => 'qmp',
		backend => 'socket',
		server => 'on',
		wait => 'off',
		path => "$rundir/$name.qmp",
	);

	$self->devices_stanza($fh, mon => 'qmp',
		mode => 'control',
		chardev => 'qmp',
		pretty => 'on',
	);

	if($self->vnc) {
		my $id = $self->id;
		$self->devices_stanza($fh, vnc => 'default',
			vnc => "localhost:$id",
		);
	}

	if(defined $self->serialport) {
		for(my $i = 0; $i < 4; $i++) {
			$self->devices_stanza($fh, chardev => "serial-$i",
				backend => 'socket',
				server => 'on',
				wait => 'off',
				path => "$rundir/$name.serial-$i",
			);
			$self->devices_stanza($fh, device => "serial-$i",
				driver => 'isa-serial',
				chardev => "serial-$i",
			);
		}
	}

	$self->devices_stanza($fh, device => 'virtio-balloon', driver => 'virtio-balloon')
		if $self->virtio;

	if($self->virtconsole) {
		$self->devices_stanza($fh, device => 'virtio-serial', driver => 'virtio-serial');
		for(my $i = 0; $i < 8; $i++) {
			$self->devices_stanza($fh, chardev => "console-$i",
				backend => 'socket',
				server => 'on',
				wait => 'off',
				path => "$rundir/$name.console-$i",
			);
			$self->devices_stanza($fh, device => 'virtconsole',
				driver => 'virtconsole',
				chardev => "console-$i",
				name => "hvc$i",
			);
		}
	}

	my $platform = $self->platform;
	if($platform eq 'efi') {
		$self->lock;

		my $ovmfdir = $self->ovmfdir;
		die "'$ovmfdir/OVMF_CODE.fd' not found\n"
			unless -f "$ovmfdir/OVMF_CODE.fd";
		$self->devices_stanza($fh, drive => "efi-code",
			if => 'pflash',
			file => "$ovmfdir/OVMF_CODE.fd",
			format => 'raw',
			readonly => 'on',
		);
		unless(-e "$statedir/$name.efi") {
			die "'$ovmfdir/OVMF_VARS.fd' not found\n"
				unless -f "$ovmfdir/OVMF_VARS.fd";
			my $fh = new IO::File("$statedir/$name.efi.new", '>:raw')
				or die "open($statedir/$name.efi.new): $!\n";
			copy("$ovmfdir/OVMF_VARS.fd", $fh)
				or die "copy($ovmfdir/OVMF_VARS.fd, $statedir/$name.efi.new): $!\n";
			$fh->flush or die "write($statedir/$name.efi.new): $!\n";
			$fh->sync or die "fsync($statedir/$name.efi.new): $!\n";
			$fh->close or die "close($statedir/$name.efi.new): $!\n";
			rename("$statedir/$name.efi.new", "$statedir/$name.efi")
				or die "rename($statedir/$name.efi.new, $statedir/$name.efi): $!\n";
		}
		$self->devices_stanza($fh, drive => "efi-vars",
			if => 'pflash',
			file => "$statedir/$name.efi",
			format => 'raw',
		);
	}

	my $disks = $self->disks;
	my $disktype = $self->disktype;
	while(my ($i, $disk) = each @$disks) {
		my $cache = $self->cache;
		my $aio = $self->aio;
		my %opt;
		die "no such file or directory: $disk\n"
			unless -e $disk;
		if(-b _) {
			$cache //= 'none';
			$aio //= 'native' if $cache eq 'none';
			$opt{format} = 'raw';
		}
		my $serial = substr(md5_base64($disk), 0, 20);
		$serial =~ tr{+/}{XY};
		$opt{serial} = $serial;
		$opt{cache} = $cache if defined $cache;
		$opt{aio} = $aio if defined $aio;
		$self->devices_stanza($fh, drive => "blk-$i",
			file => $disk,
			if => 'none',
			%opt,
		);
		$self->devices_stanza($fh, device => "blk-$i",
			driver => $disktype,
			drive => "blk-$i",
		);
	}

	my $nics = $self->nics;
	my $nictype = $self->nictype;
	my @vhost_net = (vhost => 'on')
		if $self->vhost_net;
	while(my ($i, $mac) = each @$nics) {
		$self->devices_stanza($fh, netdev => "net-$i",
			type => 'tap',
			ifname => $name.$i,
			@vhost_net,
		);
		$self->devices_stanza($fh, device => "net-$i",
			driver => $nictype,
			netdev => "net-$i",
			mac => $mac,
		);
	}

#	$self->devices_stanza($fh, drive => 'cdrom',
#		if => 'none',
#	);
#	$self->devices_stanza($fh, device => 'ide0-cd1',
#		driver => 'ide-cd',
#		drive => 'cdrom',
#	);

	my $sections = $self->sections;
	foreach my $section (@$sections) {
		$self->devices_stanza($fh, @$section);
	}
}

sub devices_file {
	my $path = shift;
	$self->lock;
	my $fh = new IO::File($path, '>')
		or die "$path: $!\n";
	$self->devices_write($fh);
	$fh->flush or die "flush($path): $!\n";
	$fh->sync or $!{EINVAL} or die "fsync($path): $!\n";;
	$fh->close or die "close($path): $!\n";
}
