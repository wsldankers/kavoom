use strict;
use warnings FATAL => 'all';
use utf8;

use POSIX qw(_exit setsid :sys_wait_h);
use IO::Handle;
use KVM::Kavoom;

sub kvm {
	my $name = shift;
	die "missing kvm name\n" unless defined $name;
	my $kvm = new KVM::Kavoom($name);
	$kvm->config;
	return $kvm;
}

sub handle_status {
	my $prog = join(' ', @_);
	if(WIFEXITED($?)) {
		my $status = WEXITSTATUS($?);
		die sprintf("%s exited with status %d\n", $prog, $status)
			if $status;
	} elsif(WIFSIGNALED($?)) {
		my $sig = WTERMSIG($?);
		die sprintf("%s killed with signal %d%s\n", $prog, $sig & 127, ($sig & 128) ? ' (core dumped)' : '')
	} elsif(WIFSTOPPED($?)) {
		my $sig = WSTOPSIG($?);
		warn sprintf("%s stopped with signal %d\n", $prog, $sig)
	}
}

sub run {
	my $prog = $_[0];
	if((system $prog @_) == -1) {
		die sprintf("running %s: %s\n", join(' ', @_), $!);
	}
	handle_status(@_);
}

sub detonate {
	my $fh = shift;
	print $fh join(': ', @_)."\n";
	close($fh);
	_exit(2);
}

sub bg {
	my $pid = fork();
	die "fork(): $!\n" unless defined $pid;
	if($pid) {
		waitpid($pid, 0);
		handle_status(@_);
		return;
	}

	open my $err, '>&', *STDERR{IO}
		or die "can't dup STDERR: $!\n";

	chdir '/'
		or detonate($err, "Can't chdir to /", $!);
	open STDIN, '<:raw', '/dev/null'
		or detonate($err, "Can't open /dev/null", $!);
	open STDOUT, '>:raw', '/dev/null'
		or detonate($err, "Can't open /dev/null", $!);
	open STDERR, '>:raw', '/dev/null'
		or detonate($err, "Can't open /dev/null", $!);

	my $daemon = fork();
	detonate($err, "fork()", $!) unless defined $daemon;
	_exit(0) if $daemon;

	detonate($err, 'setsid()', $!) if setsid() == -1;
	my $prog = $_[0];
	eval { exec $prog @_ };
	detonate($err, 'exec('.join(' ', @_).')', $!);
	die;
}

my %tried;
my @tried;
my $configfile;

sub concat {
	return undef if grep !defined, @_;
	return join('/', @_);
}

foreach(
			$ENV{KAVOOMRC},
			concat($ENV{HOME}, '.kavoomrc'),
			concat($DIR{conf}, 'kavoom.cfg'),
			concat($DIR{root}, 'kavoom.cfg'),
			'/etc/kavoom.cfg',
			'/usr/local/etc/kavoom.cfg'
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

die "Can't find a configuration file. Tried:\n". map { "\t$_\n" } @tried
	unless defined $configfile;

KVM::Kavoom::configure($configfile);

my %commands = (
	start => sub {
		my $kvm = &kvm;
		my $cmd = $kvm->command;
		run (@$cmd, @_);
	},
	command => sub {
		my $kvm = &kvm;
		my $cmd = $kvm->sh;
		print "$cmd\n"
			or die $!;
	},
	serial => sub {
		my $kvm = &kvm;
		my $exp = $kvm->serial;
		my $name = $kvm->name;
		die "virtual machine $name not running.\n" unless $exp;
		print STDERR "Escape character is '^]'.\n";
		$exp->interact(\*STDIN, "");
		print "\n";
	},
	monitor => sub {
		my $kvm = &kvm;
		my $exp = $kvm->monitor;
		my $name = $kvm->name;
		die "virtual machine $name not running.\n" unless $exp;
		if(@_) {
			$exp->expect(1, -re => '^\(qemu\) ') or die "timeout\n";
			$exp->print(join(' ', @_)."\n");
			$exp->expect(1, -ex => "\n") or die "timeout\n";
			$exp->expect(60, -re => '^\(qemu\) ') or die "timeout\n";
			print $exp->before;
		} else {
			print STDERR "Escape character is '^]'.\n";
			$exp->interact(\*STDIN, "");
			print "\n";
		}
	},
	shutdown => sub {
		my $kvm = &kvm;
		my $exp = $kvm->monitor;
		my $name = $kvm->name;
		return unless $exp;
		$exp->expect(1, -re => '^\(qemu\) ') or die "timeout\n";
		$exp->print("sendkey ctrl-alt-delete\n");
		$exp->expect(1, -ex => "\n") or die "timeout\n";
		$exp->expect(60, -ex => 'No mr Bond, I expect you to die!');
	},
	destroy => sub {
		my $kvm = &kvm;
		my $exp = $kvm->monitor;
		my $name = $kvm->name;
		return unless $exp;
		$exp->expect(1, -re => '^\(qemu\) ') or die "timeout\n";
		$exp->print("quit\n");
		$exp->expect(60, -ex => 'No mr Bond, I expect you to die!');
	},
);

my $what = shift @ARGV;
die "kavoom: no command specified\n" unless defined $what;
my $lwhat = lc $what;
die "kavoom: unknown command '$what'\n" unless exists $commands{$lwhat};

eval {
	$commands{$lwhat}(@ARGV);
};
if($@) {
	print STDERR "kavoom $what: $@";
	exit 1;
} else {
	exit 0;
}

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

=item C<kavoom> C<start> I<instance>

Start a KVM instance, as described in its configuration file.
For the format of the configuration file, see below.

=item C<kavoom> C<command> I<instance>

Print the command as it would be executed by the C<start> command.

=item C<kavoom> C<serial> I<instance>

Get access to the serial console of an already running instance.
You can leave the serial console by typing C<^]> (control + right angle
bracket).

=item C<kavoom> C<monitor> I<instance> [I<monitor command>]

Without arguments, gives access to the interactive QEMU console (kvm is
based on QEMU, so the command set is the same).
You can leave the monitor by typing C<^]> (control + right angle bracket).

If arguments are given to the monitor command, they are input into the QEMU
monitor as a command and kavoom will wait until the prompt returns.

For information on the commands available in the QEMU console, see the QEMU
documentation.

=item C<kavoom> C<shutdown> I<instance>

Try to shut the instance down gracefully, by sending a ctrl-alt-delete to
it. This obviously will not work unless the guest OS interprets this as a
shutdown command (the default linux console will just start a reboot, which
is not sufficient).

=item C<kavoom> C<destroy> I<instance>

Destroy a KVM instance by ending the process. Any unsaved or unsynced data
in the guest will be lost.

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

Where I<prefix> and I<confdir> are as specified while building kavoom.

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
Usually F</var/run/kavoom>.

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

=item C<disk> = I<block device>

Add a disk image, which will show up in the guest as a PATA disk. You can
specify this parameter as often as you like, to add more disk devices.

=item C<drive> = I<drivespec>

Add a device using custom QEMU options. See the C<-drive> option in the
QEMU manpage for its syntax.

=back

=head1 EXAMPLE

Sample configuration file:

 mem = 1024
 disk = /dev/vg/foobar
 mac = 00:16:3e:c8:37:e0

Sample session:

 # kavoom start foobar
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

 Debian GNU/Linux 5.0 foobar ttyS0

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
