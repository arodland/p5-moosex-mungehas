package MooseX::MungeHas;

use 5.008;
use strict;
use warnings;

BEGIN {
	$MooseX::MungeHas::AUTHORITY = 'cpan:TOBYINK';
	$MooseX::MungeHas::VERSION   = '0.003';
}

use Carp qw(croak);
use Eval::TypeTiny qw(eval_closure);
use Scalar::Util qw();

sub import
{
	no strict qw(refs);
	
	my $class  = shift;
	my $caller = caller;
	
	my $orig = \&{"$caller\::has"}
		or croak "$caller does not have a 'has' function to munge";

	no warnings qw(redefine prototype);
	*{"$caller\::has"} = $class->_make_has(
		$caller,
		$class->_make_munger($caller, @_),
		$orig,
	);
}

sub _detect_oo
{
	my $package = $_[0];
	return "" unless $package->can("meta");
	return "Moo"   if ref($package->meta) eq "Moo::HandleMoose::FakeMetaClass";
	return "Mouse" if $package->meta->isa("Mouse::Meta::Module");
	return "Moose" if $package->meta->isa("Moose::Meta::Class");
	return "Moose" if $package->meta->isa("Moose::Meta::Role");
	return "";
}

sub _make_munger
{
	my $class = shift;
	my ($caller, @features) = @_;
	
	@features or croak "Munge 'has' how exactly?? Expected list";
	
	return $class->_compile_munger_code($caller, @features);
}

sub _compile_munger_code
{
	my $class = shift;
	my ($caller, @features) = @_;
	my %features = map +($_ => 1), grep !ref, @features;
	my @subs     = grep ref, @features;
	
	my @code = "sub {";
	
	if (_detect_oo($caller) =~ /^Mo[ou]se$/)
	{
		push @code, '  if (exists($_{isa}) && !ref($_{isa})) {';
		push @code, '    $_{isa} = '._detect_oo($caller).'::Util::TypeConstraints::find_or_parse_type_constraint($_{isa});';
		push @code, '  }';
	}
	
	for my $is (qw/ro rw rwp lazy/)
	{
		if (delete $features{"is_$is"})
		{
			push @code, '  $_{is} ||= "'.$is.'";';
		}
	}
	
	unless (_detect_oo($caller) eq "Moo")
	{
		push @code, '  if ($_{is} eq q(lazy)) {';
		push @code, '    $_{is}      = "ro";';
		push @code, '    $_{lazy}    = 1 unless exists($_{lazy});';
		push @code, '    $_{builder} = "_build_$_" if $_{lazy} && !exists($_{builder}) && !exists($_{default});';
		push @code, '  }';
		
		push @code, '  if ($_{is} eq q(rwp)) {';
		push @code, '    $_{is}     = "ro";';
		push @code, '    $_{writer} = "_set_$_" unless exists($_{writer});';
		push @code, '  }';
	}
	
	if (delete $features{"eq_1"})
	{
		push @code, '  my ($pfx, $name) = ($_ =~ /^(_*)(.+)$/);';
		push @code, '  $_{builder}   = "_build_$_" if exists($_{builder}) && $_{builder} eq q(1);';
		push @code, '  $_{clearer}   = "${pfx}clear_${name}" if exists($_{clearer}) && $_{clearer} eq q(1);';
		push @code, '  $_{predicate} = "${pfx}has_${name}" if exists($_{predicate}) && $_{predicate} eq q(1);';
		push @code, '  if (exists($_{trigger}) && $_{trigger} eq q(1)) {';
		push @code, '    my $method = "_trigger_$_";';
		push @code, '    $_{trigger} = sub { shift->$method(@_) };';
		push @code, '  }';
	}
	
	if (delete $features{"always_coerce"})
	{
		push @code, '  if (exists($_{isa}) and !exists($_{coerce}) and Scalar::Util::blessed($_{isa}) and $_{isa}->can("has_coercion") and $_{isa}->has_coercion) {';
		push @code, '    $_{coerce} = $_{isa}->coercion;';
		push @code, '  }';
	}
	
	if (_detect_oo($caller) eq "Moo")
	{
		push @code, '  if (defined($_{coerce}) and !ref($_{coerce}) and $_{coerce} eq "1") {';
		push @code, '    Scalar::Util::blessed($_{isa}) && $_{isa}->isa("Type::Tiny")';
		push @code, '      or Carp::croak("coerce => 1, but not isa => Type::Tiny");';
		push @code, '    $_{coerce} = $_{isa}->coercion;';
		push @code, '  }';
		push @code, '  elsif (exists($_{coerce}) and not $_{coerce}) {';
		push @code, '    delete($_{coerce});';
		push @code, '  }';
	}
	
	if (delete $features{"no_isa"})
	{
		push @code, '  delete($_{isa}) if !exists($_{coerce});';
	}
	
	if (delete $features{"simple_isa"})
	{
		push @code, '  $_{isa} = "'.$class.'"->_simplify_isa($_{isa}) if Scalar::Util::blessed($_{isa}) && !$_{coerce};';
	}
	
	push @code, sprintf('  $subs[%d]->(@_);', $_) for 0..$#subs;
	
	push @code, "}";
	
	croak sprintf("Did not understand mungers: %s", join(q[, ], sort keys %features))
		if keys %features;
	
	return eval_closure(
		source      => \@code,
		environment => { '@subs' => \@subs },
	);
}

sub _simplify_isa
{
	my $class = shift;
	my ($t) = @_;
	
	until ($t->can_be_inlined)
	{
		if ($t->has_parent)
		{
			$t = $t->parent;
			next;
		}
		
		if ($t->isa("Type::Tiny::Intersection"))
		{
			require Type::Tiny::Intersection;
			my (@can_be_inlined) = grep $_->can_be_inlined, @$t;
			$t = "Type::Tiny::Intersection"->new(type_constraints => \@can_be_inlined);
			next;
		}
		
		require Type::Tiny;
		return "Type::Tiny"->new;
	}
	
	return $t;
}

sub _make_has
{
	my $class = shift;
	my ($caller, $coderef, $orig) = @_;
	
	return $class->_make_has_mouse(@_) if _detect_oo($caller) eq "Mouse";
	
	return sub
	{
		my ($attr, %spec) = @_;
		
		if (ref($attr) eq q(ARRAY))
		{
			my @attrs = @$attr;
			for my $attr (@attrs)
			{
				local %_ = %spec;
				local $_ = $attr;
				$coderef->($attr, %_);
				return $orig->($attr, %_);
			}
		}
		else
		{
			local %_ = %spec;
			local $_ = $attr;
			$coderef->($attr, %_);
			return $orig->($attr, %_);
		}
	};
}

sub _make_has_mouse
{
	my $class = shift;
	my ($caller, $coderef, $orig) = @_;
	
	return sub
	{
		my ($attr, %spec) = @_;
		
		if (ref($attr) eq q(ARRAY))
		{
			croak "MooseX::MungeHas does not support has \\\@array for Mouse";
		}
		else
		{
			local %_ = %spec;
			local $_ = $attr;
			$coderef->($attr, %_);
			@_ = ($attr, %_);
			goto $orig;
		}
	};
}

1;

__END__

=pod

=encoding utf-8

=for stopwords metathingies munges mungers

=head1 NAME

MooseX::MungeHas - munge your "has" (works with Moo, Moose and Mouse)

=head1 SYNOPSIS

   package Foo::Bar;
   
   use Moose;
   use MooseX::MungeHas "is_ro";
   
   has foo => ();             # read-only
   has bar => (is => "rw");   # read-write

=head1 DESCRIPTION

MooseX::MungeHas alters the behaviour of the attributes of your L<Moo>,
L<Moose> or L<Mouse> based class. It manages to support all three because
it doesn't attempt to do anything smart with metathingies; it simply
installs a wrapper for C<< has >> that munges the attribute specification
hash before passing it on to the original C<< has >> function.

When you C<< use MooseX::MungeHas >> you must provide a list of mungers
you want it to apply. The following are currently pre-defined:

=over

=item C<< is_ro >>, C<< is_rw >>, C<< is_rwp >>, C<< is_lazy >>

These mungers supply defaults for the C<< is >> option.

Although only L<Moo> supports C<< is => "rwp" >> and C<< is => "lazy" >>,
MooseX::MungeHas supplies an implementation of both for L<Moose> or
L<Mouse>.

=item C<< always_coerce >>

Automatically provides C<< coerce => 1 >> if the type constraint provides
coercions. (Unless you've explicitly specified C<< coerce => 0 >>.)

Although L<Moo> expects coerce to be a coderef, MooseX::MungeHas supplies
an implementation of C<< coerce => 0|1 >> for L<Type::Tiny> type constraints.

=item C<< eq_1 >>

Makes C<< builder => 1 >>, C<< clearer => 1 >>, C<< predicate => 1 >>,
and C<< trigger => 1 >> do what you mean.

=item C<< no_isa >>

Switches off C<< isa >> checks for attributes, unless they coerce.

=item C<< simple_isa >>

Loosens type constraints if they don't coerce, and if it's likely to make
them significantly faster. (Loosening C<Int> to C<Num> won't speed it
up.)

Only works if you're using L<Type::Tiny> constraints.

=back

If these predefined mungers don't float your boat, then you can provide
additional mungers using coderefs:

   use MooseX::MungeHas "no_isa", sub {
      # Make constructor ignore private attributes
      $_{init_arg} = undef if /^_/;
   };

Within coderefs, the name of the attribute being processed is available
in the C<< $_ >> variable, and the specification hash is available as
C<< %_ >>.

You may provide multiple coderefs. Mungers provided as coderefs are
executed I<after> named ones, but are otherwise executed in the order
specified.

=head1 BUGS

Please report any bugs to
L<http://rt.cpan.org/Dist/Display.html?Queue=MooseX-MungeHas>.

=head1 SEE ALSO

L<Moo>, L<Mouse>, L<Moose>, L<MooseX::AttributeShortcuts>,
L<MooseX::InlineTypes>, L<Type::Tiny::Manual>.

Similar: L<MooseX::HasDefaults>, L<MooseX::Attributes::Curried>,
L<MooseX::Attribute::Prototype> and L<MooseX::AttributeDefaults>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2013 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.

