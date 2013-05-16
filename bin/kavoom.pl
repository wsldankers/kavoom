#! /usr/bin/env perl

use strict;
use warnings FATAL => 'all';
use utf8;

use POSIX qw(_exit setsid :sys_wait_h);
use IO::Handle;
use KVM::Kavoom;

our $PACKAGE //= 'kavoom';
our $VERSION //= 'git';
our $prefix;
our $sysconfdir;

my $exit_status;

sub kvm {
	my $name = shift;
	die "missing kvm name\n" unless defined $name;
	my $kvm = new KVM::Kavoom($name);
	$kvm->config;
	return $kvm;
}

my %tried;
my @tried;
my $configfile;

sub concat {
	return if grep { !defined } @_;
	return join('/', @_);
}

foreach(
			$ENV{KAVOOMRC},
			concat($ENV{HOME}, '.kavoomrc'),
			concat($sysconfdir, 'kavoom.cfg'),
			concat($prefix, 'etc', 'kavoom.cfg'),
			'/etc/kavoom.cfg',
			'/usr/local/etc/kavoom.cfg',
			"/opt/$PACKAGE/etc/kavoom.cfg",
			"/opt/$PACKAGE-$VERSION/etc/kavoom.cfg",
		) {
	next unless defined;
	next if exists $tried{$_};
	undef $tried{$_};
	push @tried, $_;
	next unless -e;
	unless(-r _) {
		warn "Skipping unreadable $_\n";
		next;
	}
	$configfile = $_;
	last;
}

die "Can't find a configuration file. Tried:\n".join('', map {"\t$_\n"} @tried)
	unless defined $configfile;

KVM::Kavoom::configure($configfile);

sub start_or_resume {
	my $resume = shift;
	my $name = shift;
	my $kvm = kvm($name);
	die "virtual machine $name already running\n"
		if $kvm->running;
	my $devices = $kvm->devices_path;
	if($resume && !-f $devices) {
		warn "kavoom: resume invoked but no devices file exists yet. creating it.\n";
		$resume = 0;
	}
	$kvm->devices_file($devices) unless $resume;
	my $cmd = $kvm->command(@_);
	local $ENV{kavoom_id} = $kvm->id;
	local $ENV{kavoom_name} = $kvm->name;
	exec @$cmd;
	die sprintf("running %s: %s\n", $cmd->[0], $!);
}

my %commands = (
	start => sub {
		start_or_resume(0, @_);
	},
	resume => sub {
		start_or_resume(1, @_);
	},
	command => sub {
		my $kvm = &kvm;
		my $cmd = $kvm->sh(@_);
		print "$cmd\n"
			or die $!;
	},
	serial => sub {
		my $kvm = &kvm;
		my $name = $kvm->name;
		die "virtual machine $name not running.\n"
			unless $kvm->running;
		my $exp = $kvm->serial(shift)
			or die "can't connect to serial port of $name.\n";
		print STDERR "Escape character is '^]'.\n";
		$exp->interact(\*STDIN, "");
		print "\n";
	},
	monitor => sub {
		my $kvm = &kvm;
		my $name = $kvm->name;
		die "virtual machine $name not running.\n"
			unless $kvm->running;
		my $exp = $kvm->monitor
			or die "can't connect to monitor of $name.\n";
		if(@_) {
			$exp->expect(2, -re => '^\(qemu\) ') or die "timeout\n";
			$exp->print(join(' ', @_)."\n");
			$exp->expect(2, -ex => "\n") or die "timeout\n";
			$exp->expect(undef, -re => '^\(qemu\) ') or die "timeout\n";
			print $exp->before;
		} else {
			print STDERR "Escape character is '^]'.\n";
			$exp->interact(\*STDIN, "");
			print "\n";
		}
	},
	console => sub {
		my $kvm = &kvm;
		my $name = $kvm->name;
		die "virtual machine $name not running.\n"
			unless $kvm->running;
		my $exp = $kvm->console(shift)
			or die "can't connect to console port of $name.\n";
		print STDERR "Escape character is '^]'.\n";
		$exp->interact(\*STDIN, "");
		print "\n";
	},
	shutdown => sub {
		my $kvm = &kvm;
		return unless $kvm->running;
		my $exp = $kvm->monitor;
		my $name = $kvm->name;
		return unless $exp;
		$exp->expect(2, -re => '^\(qemu\) ') or die "timeout\n";
		$exp->print("system_powerdown\n");
		$exp->expect(2, -ex => "\n") or die "timeout\n";
		$exp->expect(60, -ex => 'No mr Bond, I expect you to die!');
	},
	destroy => sub {
		my $kvm = &kvm;
		return unless $kvm->running;
		my $exp = $kvm->monitor;
		my $name = $kvm->name;
		return unless $exp;
		$exp->expect(2, -re => '^\(qemu\) ') or die "timeout\n";
		$exp->print("quit\n");
		$exp->expect(60, -ex => 'No mr Bond, I expect you to die!');
	},
	started => sub {
		my $kvm = &kvm;
		$exit_status = $kvm->running ? 0 : 1;
	},
	stopped => sub {
		my $kvm = &kvm;
		$exit_status = $kvm->running ? 1 : 0;
	},
	configtest => sub {
		my $kvm = &kvm;
		$kvm->command;
	},
	devices => sub {
		my $kvm = &kvm;
		if(@_ == 0) {
			$kvm->devices_write(\*STDOUT);
		} elsif(@_ == 1) {
			my $filename = shift;
			eval { $kvm->devices_file($filename) };
			die "$filename: $@" if $@;
		} else {
			die "too many arguments\n";
		}
	},
);

my $what = shift @ARGV;
die "kavoom: no command specified\n" unless defined $what;
my $lwhat = lc $what;
die "kavoom: unknown command '$what'\n" unless exists $commands{$lwhat};

eval { $commands{$lwhat}(@ARGV) };
if($@) {
	print STDERR "kavoom $what: $@";
	$exit_status ||= 1;
}

exit($exit_status // 0);

__END__

=head1 NAME

kavoom - Manage KVM instances

=head1 SYNOPSIS

C<kavoom> I<command> I<instance>

=head1 DESCRIPTION

Kavoom manages instances of the Linux KVM virtual machine. It allows you to
start and stop KVM processes, access its serial port and to use the QEMU
monitor. The monitor can be used both interactively and using one-off
commands in a way suitable for scripting.

=head1 COMMANDS

=over

=item C<kavoom> C<start> I<instance> [I<kvm arguments>]

Start a KVM instance, as described in its configuration file.
For the format of the configuration file, see below.

Any extra arguments to this command are passed verbatim to kvm.

=item C<kavoom> C<command> I<instance>

Print the command as it would be executed by the C<start> command.

=item C<kavoom> C<resume> I<instance> [I<kvm arguments>]

Like the C<start> command, but only generates the kvm device file if
it doesn't exist (and prints a warning in that case). Useful when
resuming from a saved image: it helps to make sure the device list
is still compatible with the saved image.

=item C<kavoom> C<serial> I<instance>

Get access to the serial console of an already running instance.
You can leave the serial console by typing C<^]> (control + right square
bracket).

=item C<kavoom> C<console> I<instance>

Get access to the virtio console of an already running instance.
You can leave the virtio console by typing C<^]> (control + right square
bracket). Only available if the VM is configured with C<console> = I<yes>.

=item C<kavoom> C<monitor> I<instance> [I<monitor command>]

Without arguments, gives access to the interactive QEMU console (kvm is
based on QEMU, so the command set is the same).
You can leave the monitor by typing C<^]> (control + right square bracket).

If arguments are given to the monitor command, they are input into the QEMU
monitor as a command and kavoom will wait until the prompt returns.

For information on the commands available in the QEMU console, see the QEMU
documentation.

=item C<kavoom> C<shutdown> I<instance>

Try to shut the instance down gracefully, by sending an ACPI powerbutton
event.

=item C<kavoom> C<destroy> I<instance>

Destroy a KVM instance by ending the process. Any unsaved or unsynced data
in the guest will be lost.

=item C<kavoom> C<started> I<instance>

Silently checks whether the instance is running. Returns a non-zero
exit code if and only if the instance is not running or an error occurred.

=item C<kavoom> C<stopped> I<instance>

Silently checks whether the instance is stopped. Returns a non-zero
exit code if and only if the instance is still running or an error occurred.

=item C<kavoom> C<configtest> I<instance>

Test the configuration for this instance. Returns a zero exit code
if and only if no errors were encountered.

=item C<kavoom> C<devices> [I<filename>]

Write the kvm device configuration file to I<file> or to stdout if no file
was specified.

=back

=head1 PATHS

The main configuration file for kavoom describes the paths where kavoom
looks for everything else. Its syntax is C<key = value> (spaces optional).
Kavoom will look for this file in several locations, in this order:

=over

=item C<$KAVOOMRC>

=item F<~/.kavoomrc>

=item I<confdir>F</kavoom.cfg>

=item I<prefix>F</etc/kavoom.cfg>

=item F</etc/kavoom.cfg>

=item F</usr/local/etc/kavoom.cfg>

=back

where I<prefix> and I<confdir> are as specified while building kavoom.

The following paths can be set:

=over

=item C<configdir> = I<path>

Directory to look for files describing each KVM instance.
Usually F</etc/kavoom>.

=item C<statedir> = I<path>

Where kavoom keeps its data, such as per-vm sequence numbers.
Usually F</var/lib/kavoom>.

=item C<rundir> = I<path>

Where kavoom stores pidfiles and sockets.

=item C<kvm> = I<path>

The executable kavoom will invoke when starting kvm.
Usually F</usr/bin/kvm> or F<kvm>.

May be overridden by a vm configuration file.

=back

=head1 CONFIGURATION

Kavoom instances are configured by files in I<configdir>/I<instance>.cfg,
where I<configdir> is usually just F</etc/kavoom>. Its format is a series
of C<key = value> pairs (spaces optional). Configurable items are:

=over

=item C<mem> = I<size in mebibytes>

Memory allocated to the VM. If Linux hugepages are available, they will be
used.

=item C<cpus> = I<number>

Number of CPUs allocated to the VM.

=item C<mac> = I<xx>:I<xx>:I<xx>:I<xx>:I<xx>:I<xx>

Allocates a TUN/TAP interface to the VM with the specified MAC address.
Multiple ethernet devices can be created by adding additional C<mac =>
lines.

The bridge that these devices will be connected to, can be configured in
C</etc/kvm-ifup> (or C</etc/kvm/kvm-ifup>, depending on how kvm is
installed).

=item C<vnc> = I<yes>/I<no>

Whether to allocate a VNC socket. You can also add or remove such a socket
later using the C<monitor> command.

=item C<tablet> = I<yes>/I<no>

Whether to allocate a USB tablet device. You can also add or remove such a
device later using the C<monitor> command. Defaults to I<yes> if a VNC
socket was allocated, otherwise I<no>.

=item C<serial> = I<0>/I<1>/I<none>

Whether to attach a serial terminal, accessible through the C<kavoom
serial> command. The argument may be either I<none> if kavoom should
allocate no serial terminal at all, or a number, in which case kavoom will
allocate all four serial ports. The number indicates which of those four
serial ports will be used by default when invoking the C<kavoom serial>
command.

Specify I<0>, I<ttyS0> or I<COM1> to use the first serial port, or I<1>,
I<ttyS1> or I<COM2> to use the second serial port, etcetera, up to I<3>
(I<COM4>).

The default is I<0>.

=item C<acpi> = I<yes>/I<no>

Whether to enable ACPI on this VM.

=item C<disk> = I<block device>

Add a disk image, which will show up in the guest as a PATA disk. You can
specify this parameter as often as you like, to add more disk devices.

A block device will be interpreted as a "raw" image, a file will be
interpreted as qcow2 format.

=item C<drive> = I<drivespec>

Deprecated. If you need precise control over the disk parameters, use
C<-drive> instead. Otherwise, use C<disk>.

=item C<virtio> = I<yes>/I<no>

Use virtio for all disks and network interfaces. Your guest OS needs to
support this. This will also configure the memory ballooning device.
Defaults to I<off>.

=item C<console> = I<yes>/I<no>

Allocate 8 virtconsole devices. Some guest OS'es (notably Debian wheezy)
are unstable with these devices present. Defaults to I<off>.

=item C<cache> = I<writeback>/I<writethrough>/I<off>

Set the caching policy for all disks. Using I<writeback> is unsafe but
fast. Useful when installing the OS.

The default policy is to use I<off> when the backend is a block device
(recommended) and to leave it to kvm otherwise (at the time of writing,
kvm uses I<writethrough> by default).

=item C<aio> = I<native>/I<threads>

Set the aio (asynchronous I/O) method for all disks.

The default policy is to use I<native> when the backend is a block device
(recommended) and to leave it to kvm otherwise (at the time of writing,
kvm uses I<threads> by default). Please note that if the caching policy
is not set to I<off>, kvm may choose to fall back to using I<threads>.

=item C<kvm> = I<path to kvm>

The path to the kvm executable to use for starting this VM. The following
environment variables will be available (for use in wrapper scripts):

kavoom_name: the name of the vm being started

kavoom_id: the numeric ID of the vm being started

=item 

=back

You can also specify kvm command line options directly, one per line.
Any options thus given are appended to the command line when starting
kvm. For example:

 -cdrom /tmp/debian-netinst.iso
 -no-reboot

=head1 EXAMPLE

Sample configuration file (I<foobar.cfg>):

 mem = 1024
 disk = /dev/vg/foobar
 mac = 52:54:00:c8:37:e0

Sample session:

 # kavoom start foobar -cdrom /tmp/debian-netinst.iso
 # kavoom monitor foobar sum 435783 33
 20681
 # kavoom monitor foobar 
 Escape character is '^]'.
 QEMU 0.9.1 monitor - type 'help' for more information
 (qemu) info balloon
 balloon: actual=1024
 (qemu) ^]
 # kavoom serial foobar
 Escape character is '^]'.

 Debian GNU/Linux 7.0 foobar ttyS0

 foobar login: ^]
 #

=head1 AUTHOR

Wessel Dankers <wsl@fruit.je>

=head1 COPYRIGHT

Copyright (c) 2009 Wessel Dankers <L<wsl@fruit.je|mailto:wsl@fruit.je>>

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<kvm(1)>, L<qemu(1)>
