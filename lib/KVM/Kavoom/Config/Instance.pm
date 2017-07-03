package KVM::Kavoom::Config::Instance;

use KVM::Kavoom::Config::Common -self;

sub set_mac {
	push @{$self->nics}, shift;
}
