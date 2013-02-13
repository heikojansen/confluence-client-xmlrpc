
package Confluence::Client::XMLRPC;
use strict;
use warnings;

# ABSTRACT: Client for the Atlassian Confluence wiki, based on RPC::XML

# Copyright (c) 2004 Asgeir.Nilsen@telenor.com
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# Version 2.1.1 changes by Torben K. Jensen
# + Support for automatic reconnect upon session expiration.

use RPC::XML;
use RPC::XML::Client;
use Env qw(CONFLDEBUG);
use Carp;
use vars '$AUTOLOAD';    # keep 'use strict' happy

our $API                  = 'confluence1';
our $AUTO_SESSION_RENEWAL = 1;

use fields qw(url user pass token client);

# Global variables
our $RaiseError = 1;
our $PrintError = 0;
our $LastError  = '';

# For debugging
sub _debugPrint {
	require Data::Dumper;
	$Data::Dumper::Terse     = 1;
	$Data::Dumper::Indent    = 0;
	$Data::Dumper::Quotekeys = 0;
	print STDERR ( shift @_ );
	print STDERR ( Data::Dumper::Dumper($_) . ( scalar @_ ? ', ' : '' ) ) while ( $_ = shift @_ );
	print STDERR "\n";
}

sub setRaiseError {
	shift if ref $_[0];
	carp "setRaiseError expected scalar"
		unless defined $_[0] and not ref $_[0];
	my $old = $RaiseError;
	$RaiseError = $_[0];
	return $old;
}

sub setPrintError {
	shift if ref $_[0];
	carp "setPrintError expected scalar"
		unless defined $_[0] and not ref $_[0];
	my $old = $PrintError;
	$PrintError = $_[0];
	return $old;
}

sub lastError {
	return $LastError;
}

#  This function converts scalars to RPC::XML strings
sub argcopy {
	my ( $arg, $depth ) = @_;
	return $arg if $depth > 1;
	my $typ = ref $arg;
	if ( !$typ ) {
		if   ( $arg =~ /true|false/ and $depth == 0 ) { return new RPC::XML::boolean($arg); }
		else                                          { return new RPC::XML::string($arg); }
	}
	if ( $typ eq "HASH" ) {
		my %hash;
		foreach my $key ( keys %$arg ) {
			$hash{$key} = argcopy( $arg->{$key}, $depth + 1 );
		}
		return \%hash;
	}
	if ( $typ eq "ARRAY" ) {
		my @array = map { argcopy( $_, $depth + 1 ) } @$arg;
		return \@array;
	}
	return $arg;
}

sub new {
	my Confluence::Client::XMLRPC $self = shift;
	my ( $url, $user, $pass ) = @_;
	unless ( ref $self ) {
		$self = fields::new($self);
	}
	$self->{url}  = shift;
	$self->{user} = shift;
	$self->{pass} = shift;
	warn "Creating client connection to $url" if $CONFLDEBUG;
	$self->{client} = new RPC::XML::Client $url;
	warn "Logging in $user" if $CONFLDEBUG;
	my $result = $self->{client}->simple_request( "$API.login", $user, $pass );
	$LastError
		= defined($result)
		? (
		ref($result) eq 'HASH'
		? ( exists $result->{faultString} ? "REMOTE ERROR: " . $result->{faultString} : '' )
		: ''
		)
		: "XML-RPC ERROR: Unable to connect to " . $self->{url};
	_debugPrint( "Result=", $result ) if $CONFLDEBUG;

	if ($LastError) {
		croak $LastError if $RaiseError;
		warn $LastError  if $PrintError;
	}
	$self->{token} = $LastError ? '' : $result;
	return $LastError ? '' : $self;
} ## end sub new

# login is an alias for new
sub login {
	return new @_;
}

sub updatePage {
	my Confluence::Client::XMLRPC $self = shift;
	my ($newPage)               = @_;
	my $saveRaise               = setRaiseError(0);
	my $result                  = $self->storePage($newPage);
	setRaiseError($saveRaise);
	if ($LastError) {
		if ( $LastError =~ /already exists/ ) {
			my $oldPage = $self->getPage( $newPage->{space}, $newPage->{title} );
			$newPage->{id}      = $oldPage->{id};
			$newPage->{version} = $oldPage->{version};
			$result             = $self->storePage($newPage);
		}
		else {
			croak $LastError if $RaiseError;
			warn $LastError  if $PrintError;
		}
	}
	return $result;
}

sub _rpc {
	my Confluence::Client::XMLRPC $self = shift;
	my $method = shift;
	croak "ERROR: Not connected" unless $self->{token};
	my @args = map { argcopy( $_, 0 ) } @_;
	_debugPrint( "Sending $API.$method ", @args ) if $CONFLDEBUG;
	my $result = $self->{client}->simple_request( "$API.$method", $self->{token}, @args );
	$LastError
		= defined($result)
		? (
		ref($result) eq 'HASH'
		? (
			exists $result->{faultString}
			? "REMOTE ERROR: " . $result->{faultString}
			: ''
			)
		: ''
		)
		: defined $RPC::XML::ERROR ? $RPC::XML::ERROR
		:                            "XML-RPC ERROR: Unable to connect to " . $self->{url};

	_debugPrint( "Result=", $result ) if $CONFLDEBUG;
	if ( ( $LastError =~ /InvalidSessionException/i ) && $AUTO_SESSION_RENEWAL )
	{    # Session time-out; log back in.
		warn "SESSION EXPIRED: Reconnecting...\n" if $PrintError;
		my $pass = $self->{pass};
		$self->{pass} = '';    # Prevent repeated attempts.
		my $clone = Confluence::Client::XMLRPC->new( $self->{url}, $self->{user}, $pass );
		if ($clone) {
			$self->{token} = $clone->{token};
			$result = _rpc( $self, $method, @_ );
			$self->{pass} = $pass;
		}
	}
	if ($LastError) {
		croak $LastError if $RaiseError;
		warn $LastError  if $PrintError;
	}
	return $LastError ? '' : $result;
} ## end sub _rpc

# Define commonly used functions to avoid overhead of autoload
sub getPage {
	my Confluence::Client::XMLRPC $self = shift;
	_rpc( $self, 'getPage', @_ );
}

sub storePage {
	my Confluence::Client::XMLRPC $self = shift;
	_rpc( $self, 'storePage', @_ );
}

# Use autolaod for everything else
sub AUTOLOAD {
	my Confluence::Client::XMLRPC $self = shift;
	$AUTOLOAD =~ s/Confluence::Client::XMLRPC:://;
	return if $AUTOLOAD =~ /DESTROY/;
	_rpc( $self, $AUTOLOAD, @_ );
}

1;

__END__


=pod

=encoding utf8

=head1 CAVEAT

B<ATTENTION>, please: This module was written by Asgeir Nilsen in 2004 and later on
improved by Giles Lewis, Martin Ellis, and Torben K. Jensen.

I - Heiko Jansen - only took the available source code and created a CPAN distribution
for it, because at least to me a Perl module almost does not exist if it's not on 
available via CPAN.

This package B<should> work with any remote API function.

The original authors tested it with C<addUserToGroup>, C<getActiveUsers>, C<getPage>, C<getPages>, C<getServerInfo>,
C<getUser>, and C<storePage>. I (Heiko Jansen) have used it successfully to create and update pages, but I did
B<not> test most other API functions and am thus B<unable to give any guarantee that it will work as expected>!

The original module was simply named "Confluence" but since Atlassian is currently
working on a new REST-based API and since there already is L<Jira::Client> and
L<Jira::Client::REST> on CPAN I renamed it to C<Confluence::Client::XMLRPC>.

=head1 SYNOPSIS

  my $object = Confluence::Client::XMLRPC->new( <URL>, <user>, <pass> );
  my $result = $object->method(argument,..);


=head1 ERROR HANDLING

This package has two global flags which control error handings.

  Confluence::Client::XMLRPC::setRaiseError(1);  # Enable die
  Confluence::Client::XMLRPC::setPrintError(1);  # Enable warn
  Confluence::Client::XMLRPC::setRaiseError(0);  # Disable die
  Confluence::Client::XMLRPC::setPrintError(0);  # Disable warn

The C<setRaiseError> and C<setPrintError> functions both return the previous setting of the flag so that it may be restored if necessary.

RaiseError is initially set to 1 to preserve the original package behavior.

PrintError is initially set to 0.

If RaiseError is set to 0 then C<Confluence::Client::XMLRPC::lastError()> can be used to determine if an error occurred.

  Confluence::Client::XMLRPC::setRaiseError(0);
  my $page = $wiki->getPage($space, $title);
  if ( my $e = Confluence::Client::XMLRPC::lastError() ) {
    say $e;
  }

=head1 USAGE

=head2 Data types

Perl simple data types are mapped to string.
Hash references are mapped to struct.
Array references are mapped to array.

This package now automatically converts all scalars to RPC::XML::string, so explicit type conversions should not be required.

=head1 API extension

=over 4

=item updatePage

This package has a function called C<updatePage> which is not part of the original remote API.
If the page id is not specified then the function will call C<storePage> to do an insert. 
If an "already exists" error is encountered then the function will call C<getPage> to retrieve
the page id and version, and then repeat the C<storePage> attempt. This function is intended 
to be used in situations where the intent is to upload pages, overwriting existing content if 
it exists. See example below.

=back

=head1 EXAMPLES

=over 4

=item C<upload_files.pl> - Upload files

The sample script uploads the contents of a directory to the wiki. Each file in the directory 
is uploaded as a separate page. The page title is the file name with extension removed. This 
script requires five arguments: API url, user name, password, space key and a directory name.

=item C<upload_users.pl> - Upload Users

This script reads and loads a list of users from a file (or stdin). If errors are encountered then 
the script will print an error message, but continue processing.
This script requires three arguments: API url, name and password of an admin user.

=item C<det_group_mbrship.pl> - Determine Group Membership

The script prints the group membership of all users.
This script requires three arguments: API url, name and password of an admin user.

=back

Please refer to the C<examples> directory of the distribution for the scripts themselves.

=head1 SEE ALSO

The package uses the L<RPC::XML> module to do the heavy lifting. Read the perldoc for this package to learn more.

For further information on the Confluence API itself please refer to the 
L<official documentation|https://confluence.atlassian.com/display/DOC/Confluence+Documentation+Home> as provided
by Atlassian.

=cut
