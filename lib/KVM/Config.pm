use strict;
use warnings FATAL => 'all';
use utf8;

package KVM::Kavoom::Config;

use Class::Clarity -self;

use IO::File;
use Scalar::Util ();

our @EXPORT_BASE = qw(trim bool merge);

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

sub merge(*@) {
    my $name = shift;
	if(@_) {
		my $postproc = shift;
		my $type = Scalar::Util::reftype($postproc);
		if($type eq 'ARRAY') {
			my $factory = Class::Clarity::Factory::factory($postproc);
			$postproc = sub {
				my $self = shift;
				my $value = $factory->();
				push @$value, @{shift()} if @_;
				return $value;
			};
		} elsif($type eq 'HASH') {
			my $factory = Class::Clarity::Factory::factory($postproc);
			$postproc = sub {
				my $self = shift;
				my $value = $factory->();
				if(@_) {
					my $inherited = shift;
					@$value{keys %$inherited} = values %$inherited;
				}
				return $value;
			};
		} elsif($type eq 'CODE') {
			# just use $postproc as-is
		} else {
			my $factory = Class::Clarity::Factory::factory($postproc);
			$postproc = sub {
				my $self = shift;
				return @_ ? shift : $factory->();
			};
		}

		field($name, sub {
			my $self = shift;
			if($self->template_isset) {
				return $postproc->($self, $self->template->$name);
			} else {
				return $postproc->($self);
			}
		});

	} else {
		field($name, sub {
			my $self = shift;
			if($self->template_isset) {
				return $self->template->$name;
			} else {
				die "configuration variable '$name' not set\n";
			}
			return $self->template->$name;
		});
	}
}

sub load {
	my $file = shift;

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

field template;

sub can {
	if(my $super = super) {
		return $super;
	}

	unless(defined Scalar::Util::blessed($self)) {
		return UNIVERSAL::can($self, @_);
	}

	if(my $template = $self->template) {
		my $method = shift;
		return sub { shift; $self->$method(@_) };
	}

	return undef;
}

sub AUTOLOAD {
	my $name = our $AUTOLOAD
		or confess("AUTOLOAD called but \$AUTOLOAD not set");
	my $off = rindex($name, '::');
	confess("no package name in '$name'")
		if $off == -1;
	my $pkg = substr($name, 0, $off + 2, '');
	if(my $template = $self->template) {
		return $template->$name(@_) if $template->can($name);
	}
	die "unknown configuration parameter\n"
		if substr($name, 0, 4) eq 'set_';
	substr($pkg, -2, 2, '');
	local $Carp::CarpLevel = 1;
	confess("Can't locate object method \"$name\" via package \"$pkg\"");
}
