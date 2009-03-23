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

my %commands = (
	start => sub {
		my $kvm = &kvm;
		my $cmd = $kvm->command;
		run (@$cmd, @_);
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