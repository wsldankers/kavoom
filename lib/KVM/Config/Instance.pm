package KVM::Kavoom::Config::Instance;

use KVM::Kavoom::Config -self;

sub set_mac {
	push @{$self->nics}, shift;
}
