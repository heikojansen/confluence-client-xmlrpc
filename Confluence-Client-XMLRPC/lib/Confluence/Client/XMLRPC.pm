
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

our $AUTO_SESSION_RENEWAL = 1;

use fields qw(url user pass token client cflVersion);

# Global variables
our $API        = 'confluence1';
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
	shift if $_[0] eq __PACKAGE__;
	carp "setRaiseError expected scalar"
		unless defined $_[0] and not ref $_[0];
	my $old = $RaiseError;
	$RaiseError = $_[0];
	return $old;
}

sub setPrintError {
	shift if ref $_[0];
	shift if $_[0] eq __PACKAGE__;
	carp "setPrintError expected scalar"
		unless defined $_[0] and not ref $_[0];
	my $old = $PrintError;
	$PrintError = $_[0];
	return $old;
}

sub setApiVersion {
	shift if ref $_[0];
	shift if $_[0] eq __PACKAGE__;
	my $new = shift;
	carp "setApiVersion expected scalar"
		unless defined $new and not ref $new;
	my $old = $API;

	if ( defined($new) and $new =~ /\A(?:confluence)?([1-9])\Z/i ) {
		$API = 'confluence' . $1;
	}

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
		if ( ( $arg eq 'true' or $arg eq 'false' ) and $depth == 0 ) {
			return new RPC::XML::boolean($arg);
		}
		else {
			return new RPC::XML::string($arg);
		}
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
	my ( $url, $user, $pass, $version ) = @_;
	unless ( ref $self ) {
		$self = fields::new($self);
	}
	$self->{url}  = $url;
	$self->{user} = $user;
	$self->{pass} = $pass;

	$API = 'confluence1';
	if ( defined($version) and $version =~ /\A(?:confluence)?([1-9])\Z/i ) {
		$API = 'confluence' . $1;
	}

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
		$self->{token} = '';
		return '';
	}

	$self->{token} = $result;

	_debugPrint( "Checking Confluence server version" ) if $CONFLDEBUG;
	my $serverInfo = _rpc( $self, 'getServerInfo' );
	if ( !defined($serverInfo) or ref($serverInfo) ne ref({}) ) {
		croak "Unable to determine Confluence version: aborting" if $RaiseError;
		warn  "Unable to determine Confluence version: aborting" if $PrintError;
		$self->{token} = '';
		return '';
	}
	$self->{'cflVersion'} = sprintf( "%03s%03s%03s", @{ $serverInfo }{ 'majorVersion', 'minorVersion', 'patchLevel' } );

	# set default API version based on Confluence version (unless explicitly given)
	unless ( defined($version) and $version =~ /\A(?:confluence)?([1-9])\Z/i ) {
		if ( $self->{'cflVersion'} ge '004000000' ) {
			$API = 'confluence2';
		}
		else {
			$API = 'confluence1';
		}
	}
	return $self;
} ## end sub new

# login is an alias for new
sub login {
	return new @_;
}

sub updatePage {
	my Confluence::Client::XMLRPC $self = shift;
	my $page                            = shift;
	my $pageUpdateOptions               = ( shift || {} );

	if ( $self->{'cflVersion'} gt "002010000" ) {
		_debugPrint("Using API method updatePage() for Confluence >= 2.10") if $CONFLDEBUG;
		return _rpc( $self, 'updatePage', $page, $pageUpdateOptions );
	}
	else {
		_debugPrint("Emulating non-existent API method updatePage() for Confluence < 2.10") if $CONFLDEBUG;
		return _updatePage( $self, $page );
	}
}

sub _updatePage {
	my Confluence::Client::XMLRPC $self = shift;

	my ($newPage)                       = @_;
	my $saveRaise                       = setRaiseError(0);
	my $result                          = $self->storePage($newPage);
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

=head1 SYNOPSIS

  my $object = Confluence::Client::XMLRPC->new( <URL>, <user>, <pass> );
  my $result = $object->method(argument,..);

  # Starting with version 2.3 of this module you can pass a fourth value to
  # new, denoting the Confluence API version to use (see below).

  my $object = Confluence::Client::XMLRPC->new( <URL>, <user>, <pass>, 2 );

=head1 METHODS

All method calls are simply mapped (via C<AUTOLOAD>) to RPC method calls.
Please refer to 
L<the official list of available methods|https://developer.atlassian.com/display/CONFDEV/Remote+Confluence+Methods>
for further information.

The module tries to automatically map between the data types mentioned in 
the Atlassian docs and the appropriate Perl data types:

=over 4

=item C<Vectors> : array references

=item C<Structs> and C<data objects> : hash references

=item C<Boolean> : strings "true" and "false"

=back

For everything else, simple scalars are used and mapped to RPC::XML::string, 
so explicit type conversions should not be required.

B<Note>: the "token" paramater mentioned in the Confluence docs is the session
id and is automatically added by this module, so do not pass in a parameter 
for it when invoking a method.

=head1 ERROR HANDLING

This package has two global flags which control error handling.

  Confluence::Client::XMLRPC::setRaiseError(1);  # Enable die
  Confluence::Client::XMLRPC::setPrintError(1);  # Enable warn
  Confluence::Client::XMLRPC::setRaiseError(0);  # Disable die
  Confluence::Client::XMLRPC::setPrintError(0);  # Disable warn

The C<setRaiseError> and C<setPrintError> functions both return the previous 
setting of the flag so that it may be restored if necessary.

RaiseError is initially set to 1 to preserve the original package behavior.

PrintError is initially set to 0.

If RaiseError is set to 0 then C<Confluence::Client::XMLRPC::lastError()> 
can be used to determine if an error occurred.

  Confluence::Client::XMLRPC::setRaiseError(0);
  my $page = $wiki->getPage($space, $title);
  if ( my $e = Confluence::Client::XMLRPC::lastError() ) {
      say $e;
  }

=head1 Debugging

You can get more info about the communication between your client and the
API by setting the environment variable C<CONFLDEBUG> to a true value.
If you do so, the module will log the messages exchanged to STDERR.

=head1 API VERSIONS

Analogous to the global error handling flags there is a flag to 
set the API version to use:

  Confluence::Client::XMLRPC::setApiVersion($num); # set the version

The C<setApiVersion> function returns the previous setting of the 
flag so that it may be restored if necessary.
The function accepts both plain numbers ("1" or "2") or the full
version namespaces ("confluence1", "confluence2").

The version 2 of the API was introduced with Confluence 4.0 and 
B<Atlassian recommends to use the newer version>.
However, due to backwards compatibility reasons the default value for the 
API version in this module still is B<1>. 

Note: you can use B<most but not all> of the version 1 API calls on newer 
Confluence installations! The Confluence docs contain a detailed and 
authoritative description of 
L<the differences between versions 1 and 2 of the API|https://developer.atlassian.com/display/CONFDEV/Confluence+XML-RPC+and+SOAP+APIs#ConfluenceXML-RPCandSOAPAPIs-v2apiRemoteAPIversion1andversion2>!

The new version 2 API implements the same methods as the version 1 API, 
however all content is stored and retrieved using the storage format. 
This means that you cannot, for example, create a page using wiki markup 
with the version 2 API, you must instead define the page using the new
XHTML based storage format.
You will be able to create pages, blogs and comments in wiki markup 
using the version 1 API even on Confluence 4.0 and later. However you 
will no longer be able to retrieve pages, blogs and comments using 
the version 1 API.

To aid in the migration phase Confluence 4.0 and up provide a method
C<convertWikiToStorageFormat()> where you can pass in a string with 
wiki markup and will recieve the same data converted to the new storage 
format (which you can then use to create or update a page).

=head1 API extension

=over 4

=item updatePage

This package has a function called C<updatePage> which is not part of the 
original remote API. If the page id is not specified then the function will 
call C<storePage> to do an insert. 
If an "already exists" error is encountered then the function will call 
C<getPage> to retrieve the page id and version, and then repeat the 
C<storePage> attempt. This function is intended to be used in situations 
where the intent is to upload pages, overwriting existing content if it 
exists. See example below.

=back

=head1 EXAMPLES

=over 4

=item C<upload_files.pl> - Upload files

The sample script uploads the contents of a directory to the wiki. Each file 
in the directory is uploaded as a separate page. The page title is the file 
name with extension removed. This script requires five arguments: API url, 
user name, password, space key and a directory name.

=item C<upload_users.pl> - Upload Users

This script reads and loads a list of users from a file (or stdin). If errors 
are encountered then the script will print an error message, but continue 
processing.
This script requires three arguments: API url, name and password of an admin 
user.

=item C<det_group_mbrship.pl> - Determine Group Membership

The script prints the group membership of all users.
This script requires three arguments: API url, name and password of an admin 
user.

=back

Please refer to the C<examples> directory of the distribution for the scripts 
themselves.

=head1 NOTES

The package uses the L<RPC::XML> module to do the heavy lifting. Read the 
perldoc for this package to learn more.

L<RPC::XML> uses LWP for handling C<http>/C<https> messaging. If you are 
experiencing problems when connecting to a C<https> based API endpoint,
please make sure that the necessary modules - like, e.g. 
L<LWP::Protocol::https> - are installed.

For further information on the Confluence API itself please refer to the 
L<official documentation|https://developer.atlassian.com/display/CONFDEV/Confluence+XML-RPC+and+SOAP+APIs>
as provided by Atlassian.

Please note that starting with Confluence 5.5 the XML-RPC API will be 
deprecated, meaning that Atlassian will not add new features or fix bugs 
related to the XML-RPC API for Confluence 5.5 or later.
This does B<not> mean, that this module will not work with newer Confluence
versions: as of now, there is no information if or when Atlassian will remove
the XML-RPC API and rely solely on the new REST API.

=head1 CAVEAT

B<ATTENTION>, please: This module was written by Asgeir Nilsen in 2004 and 
later on improved by Giles Lewis, Martin Ellis, and Torben K. Jensen.

I - Heiko Jansen - only took the available source code and created a CPAN 
distribution for it, because at least to me a Perl module almost does not 
exist if it's not on available via CPAN.

This package B<should> work with any remote API function.

The original authors tested it with C<addUserToGroup>, C<getActiveUsers>, 
C<getPage>, C<getPages>, C<getServerInfo>, C<getUser>, and C<storePage>. 
I (Heiko Jansen) have used it successfully to create and update pages, but 
I did B<not> test most other API functions and am thus B<unable to give any 
guarantee that it will work as expected>!

The original module was simply named "Confluence" but since Atlassian is 
currently working on a new REST-based API I renamed it to 
C<Confluence::Client::XMLRPC>.

=cut
