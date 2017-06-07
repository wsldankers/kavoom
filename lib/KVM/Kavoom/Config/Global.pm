package KVM::Kavoom::Config::Global;

use KVM::Kavoom::Config -self;

field configdir;

sub set_configdir {
	my $value = shift;
	die "config directory '$value' does not exist\n" unless -e $value;
	die "config directory '$value' is not a directory\n" unless -d $value;
	$self->configdir($configdir);
}
