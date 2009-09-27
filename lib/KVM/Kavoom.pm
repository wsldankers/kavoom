use strict;
use warnings FATAL => 'all';
use utf8;

package KVM::Kavoom;

use Spiffy -Base;
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

	open CFG, '<:utf8', $file
		or die "$file: $!\n";

	while(<CFG>) {
		next if /^\s*($|#)/;
		my ($key, $val) = split('=', $_, 2);
		die "Malformed line at $file:$.\n"
			unless defined $val;
		trim($key, $val);

		die "Unknown configuration key '$key' at $file:$.\n"
			unless exists $paths{$key};
		${$paths{$key}} = $val
	}
}

field 'name';
field 'id';
field 'disks' => [];
field 'nics' => [];
field 'args';

sub huge() {
	our $huge;
	unless(defined $huge) {
		$huge = '';
		eval {
			open my $mtab, '/proc/mounts'
				or die;
			while(<$mtab>) {
				chomp;
				my @fields = split;
				$huge = $fields[1]
					if $fields[2] eq 'hugetlbfs';
			}
			close $mtab;
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
		usbdevice => 'tablet',
#		monitor => 'tcp:localhost:'.(4000+$id).',server,nowait,nodelay',
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
	return 1 if /^([yjt]|(on|1)$)/;
	return 0 if /^([nf]|(off|0)$)/;
	return $_[1];
}

our %keys; @keys{qw(mem cpus mac vnc disk drive)} = ();

sub mem {
	my $args = $self->args;
	my $mem = int($_[0]);
	$mem -= 22 if exists $args->{'mem-path'};
	$args->{m} = $mem
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

sub drive {
	my $disks = $self->disks;
	push @$disks, $_[0]
}

sub disk {
	$self->drive("media=disk,file=$_[0],cache=off")
}

sub config {
	my $name = $self->name;
	my $cfg = @_ ? $_[0] : "$configdir/$name.cfg";
	open CFG, '<', $cfg
		or die "Can't open $cfg: $!\n";

	while(<CFG>) {
		next if /^\s*($|#)/;
		my ($key, $val) = split('=', $_, 2);
		die "Malformed line at $cfg:$.\n"
			unless defined $val;
		trim($key, $val);
		my $lkey = lc $key;
		die "unknown configuration parameter at $cfg:$.: $key\n"
			unless exists $keys{$lkey};
		$self->$lkey($val);
	}

	close CFG or die;
}

sub command {
	my @cmd = qw(kvm -daemonize);

	my $name = $self->name;
	my $id = $self->id;

	my $args = $self->args;
	while(my ($key, $val) = each(%$args)) {
		push @cmd, "-$key", $val;
	}

	my $nics = $self->nics;
	my $i = 0;
	foreach my $mac (@$nics) {
		push @cmd,
			'-net', "tap,vlan=$i,ifname=$name$i",
#			'-net', "nic,vlan=$i,macaddr=$mac";
			'-net', "nic,vlan=$i,model=e1000,macaddr=$mac";
#			'-net', "nic,vlan=$i,model=virtio,macaddr=$mac";
		$i++;
	}
	push @cmd, '-net', 'none'
		unless $i;

	my $disks = $self->disks;
	foreach my $disk (@$disks) {
		push @cmd, '-drive', $disk;
	}

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
