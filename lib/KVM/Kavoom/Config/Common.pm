package KVM::Kavoom::Config::Common;

use KVM::Kavoom::Config -self;

field disks => [];
field nics => [];
merge extra => [];
merge sections => [];
merge virtio => undef;
merge virtconsole => undef;
merge cache => undef;
merge aio => undef;
merge serialport => 0;
merge mem => undef;
merge cpus => undef;
merge acpi => 1;
merge usb => 0;
merge vnc => undef;
merge tablet => undef;
merge platform => 'bios';
merge ovmfdir => '/usr/share/OVMF';
merge chipset;
merge statedir;
merge rundir;
merge kvm;

field hugepages => undef;

sub set_mem {
	$self->mem(int(shift));
}

sub set_cpus {
	$self->cpus(int(shift));
}

sub set_nics {
	push @{$self->nics}, (undef) x shift;
}

sub set_vnc {
	$self->vnc(bool(shift));
}

sub set_usb {
	$self->usb(bool(shift));
}

sub set_tablet {
	$self->tablet(bool(shift));
}

sub set_serial {
	local $_ = shift;
	if(/^(?:ttyS)?(\d+)\z/) {
		$self->serialport(int($1));
	} elsif(/^(?:COM)([1-9]\d*)\z/) {
		$self->serialport(int($1) - 1);
	} elsif($_ eq 'none') {
		$self->serialport(undef);
	} else {
		die "unknown serial port '$_'\n";
	}
}

sub set_console {
	$self->virtconsole(bool(shift));
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
	$self->acpi(bool(shift));
}

sub set_virtio {
	$self->virtio(bool(shift));
}

sub set_platform {
	local $_ = lc(shift);
	if(/^(?:bios|efi)\z/) {
		$self->platform($_);
	} else {
		die "unknown platform type '$_' (possible values: bios, efi)\n";
	}
}

sub set_chipset {
	$self->chipset(shift);
}

sub set_ovmfdir {
	my $value = shift;
	die "OVMF directory '$value' does not exist\n" unless -e $value;
	die "OVMF directory '$value' is not a directory\n" unless -d _;
	$self->ovmfdir($value);
}

sub set_statedir {
	my $value = shift;
	die "state directory '$value' does not exist\n" unless -e $value;
	die "state directory '$value' is not a directory\n" unless -d _;
	$self->statedir($value);
}

sub set_rundir {
	my $value = shift;
	die "run directory '$value' does not exist\n" unless -e $value;
	die "run directory '$value' is not a directory\n" unless -d _;
	$self->rundir($value);
}

sub set_kvm {
	$self->kvm(shift);
}
