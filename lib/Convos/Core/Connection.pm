package Convos::Core::Connection;
use Mojo::Base 'Mojo::EventEmitter';

use Convos::Core::Dialog;
use Convos::Util qw(DEBUG has_many);
use Mojo::JSON qw(false true);
use Mojo::Loader 'load_class';
use Mojo::Promise;
use Mojo::URL;
use Mojo::Util qw(term_escape url_escape);
use Unicode::UTF8;

$IO::Socket::SSL::DEBUG = $ENV{CONVOS_TLS_DEBUG} if $ENV{CONVOS_TLS_DEBUG};

has messages => sub {
  my $self   = shift;
  my $dialog = Convos::Core::Dialog->new(id => '', name => $self->name);
  Scalar::Util::weaken($dialog->{connection} = $self);
  return $dialog;
};

sub name { shift->{name} }
has on_connect_commands => sub { +[] };
has protocol            => 'null';
has wanted_state        => 'connected';

sub url {
  my $self = shift;

  # Set
  return $self->_set_url(shift) if @_;

  # Default value
  $self->_set_url($self->{url} || sprintf '%s://localhost', $self->protocol)
    unless ref $self->{url};

  # Get
  return $self->{url};
}

sub user { shift->{user} }

sub connect {
  my $self = shift;

  # Reconnect
  return $self->disconnect_p->then(
    sub { $self->user->core->connect($self, 'Reconnect on connection change.') })
    if $self->{stream_id} and ($self->{host_port} || '') ne $self->url->host_port;

  # Already connected/connecting
  return if $self->{stream_id};

  delete $self->{disconnecting};
  $self->emit(state => frozen => $_->frozen('Not connected.')->TO_JSON)
    for grep { !$_->frozen } @{$self->dialogs};

  # Connect
  Scalar::Util::weaken($self);
  $self->_debug('Connecting...') if DEBUG;
  $self->{stream_id} = Mojo::IOLoop->client($self->_connect_args, sub { $self->_stream(@_) });
  $self->{host_port} = $self->url->host_port;    # must be done after _connect_args() is called
}

has_many dialogs => 'Convos::Core::Dialog' => sub {
  my ($self, $attrs) = @_;
  my $dialog = Convos::Core::Dialog->new($attrs);
  Scalar::Util::weaken($dialog->{connection} = $self);
  return $dialog;
};

sub disconnect_p { shift->_stream_remove(Mojo::Promise->new) }

sub id { my $from = $_[1] || $_[0]; lc join '-', @$from{qw(protocol name)} }

sub new {
  my $self = shift->SUPER::new(@_);
  $self->dialog($_) for @{delete($self->{dialogs}) || []};
  $self;
}

sub rtc_p {
  my ($self, $msg) = @_;
  return Mojo::Promise->reject('Missing property: event.')   unless $msg->{event};
  return Mojo::Promise->reject('Missing property: call_id.') unless $msg->{call_id};
  return Mojo::Promise->reject('Dialog not found.')
    unless $msg->{dialog_id} and my $dialog = $self->get_dialog($msg->{dialog_id});

  $msg->{from} = $self->_nick;

  # "signal" messages should only be sent to a single user
  return $self->_rtc_signal_p($msg) if $msg->{event} eq 'signal';

  # Every other message (call, hangup) should be broadcast to all other users
  $self->user->core->connections_by_id($self->id)->each(sub {
    my $other = shift;
    return if $other eq $self;
    my $dialog = $other->get_dialog($msg->{dialog_id});
    $other->emit(rtc => $msg->{event}, $dialog => $msg) if $dialog and !$dialog->frozen;
  });

  return Mojo::Promise->resolve($msg);
}

sub save_p {
  my $self = shift;
  return $self->user->core->backend->save_object_p($self, @_);
}

sub send_p { die 'Method "send_p" not implemented.' }

sub state {
  my ($self, $state, $message) = @_;

  # Get
  return $self->{state} ||= $self->wanted_state eq 'connected' ? 'queued' : 'disconnected'
    unless $state;

  # Set to same value
  return $self if +($self->{state} || '') eq $state;

  # Set to new value
  die "Invalid state: $state" unless grep { $state eq $_ } qw(connected queued disconnected);
  $self->{state} = $state;
  $self->_debug('state = %s (%s)', $state, $message) if DEBUG;
  $self->emit(state => connection => {state => $state, message => $message});

  return $self;
}

sub uri { Mojo::Path->new(sprintf '%s/%s/connection.json', $_[0]->user->email, $_[0]->id) }

sub _connect_args {
  my $self   = shift;
  my $url    = $self->url;
  my $params = $url->query;

  my %args;
  $args{address}       = $url->host;
  $args{local_address} = $params->param('local_address') if $params->param('local_address');
  $args{port}          = $url->port;
  $args{timeout}       = 20;

  $params->param(tls => 1) unless defined $params->param('tls');
  if ($params->param('tls')) {
    $args{tls}        = 1;
    $args{tls_ca}     = $ENV{CONVOS_TLS_CA} if $ENV{CONVOS_TLS_CA};
    $args{tls_cert}   = $ENV{CONVOS_TLS_CERT} if $ENV{CONVOS_TLS_CERT};
    $args{tls_key}    = $ENV{CONVOS_TLS_KEY} if $ENV{CONVOS_TLS_KEY};
    $args{tls_verify} = 0x00 unless $params->param('tls_verify');
  }

  $self->_debug('connect = %s', Mojo::JSON::encode_json(\%args)) if DEBUG;

  return \%args;
}

sub _debug {
  my ($self, $format, @args) = @_;
  chomp for @args;
  warn sprintf "[%s/%s] [$$/%s] $format\n", $self->user->email, $self->id, (time - $^T), @args;

#my @caller = caller 1;
#warn sprintf "[%s/%s] $format at %s line %s\n", $self->user->email, $self->id, @args, @caller[1, 2];
}

# The active nick
sub _nick {
  my $self = shift;
  my $nick;
  return $nick if $nick = $self->{myinfo}{nick};
  return $nick if $nick = $self->url->query->param('nick');
  $nick = $self->user->email =~ /^([^@]+)/ ? $1 : 'guest';
  $nick =~ s!\W!_!g;
  return $nick;
}

sub _notice {
  my ($self, $message) = (shift, shift);
  $self->emit(
    message => $self->messages,
    {from => $self->id, highlight => false, type => 'notice', @_, message => $message, ts => time},
  );
}

sub _remove_dialog {
  my ($self, $name) = @_;
  my $dialog = $self->remove_dialog($name);
  $self->emit(state => part => {dialog_id => lc $name, nick => $self->_nick});
  return $self;
}

sub _rtc_signal_p {
  my ($self, $msg) = @_;
  return Mojo::Promise->reject('Missing property: target.') unless $msg->{target};

  $self->user->core->connections_by_id($self->id)->each(sub {
    my $other = shift;
    return if $other eq $self or $other->_nick ne $msg->{target};
    my $dialog = $other->get_dialog($msg->{dialog_id});
    $other->emit(rtc => signal => $dialog => $msg) if $dialog and !$dialog->frozen;
  });

  return Mojo::Promise->resolve({});
}

sub _set_url {
  my $self = shift;
  my $url  = ref $_[0] ? shift : Mojo::URL->new(shift);
  $self->{url} = $url;
  return $self;
}

sub _stream {
  my ($self, $loop, $err, $stream) = @_;
  return $self->_stream_on_error($stream, $err) if $err;

  $stream->timeout(0);
  $self->{pid} //= $$;
  $self->{buffer}  = '';
  $self->{delayed} = 0;
  $self->{myinfo} ||= {};
  $self->state(connected => "Connected to @{[$self->url->host]}.");

  Scalar::Util::weaken($self);
  Scalar::Util::weaken($self->{stream} = $stream);
  $stream->on(read    => sub { $self and $self->_stream_on_read(@_) });
  $stream->on(close   => sub { $self and $self->_stream_on_close(@_) });
  $stream->on(error   => sub { $self and $self->_stream_on_error(@_) });
  $stream->on(timeout => sub { $self and $self->_stream_on_error($_[0], 'Timeout!') });
}

sub _stream_on_close {
  my ($self, $stream) = @_;
  return unless $self->{pid} == $$;

  my $state = delete $self->{disconnecting} ? 'disconnected' : 'queued';
  delete @$self{qw(stream stream_id)};
  return $self->state(disconnected => 'Closed.') if $state eq 'disconnected';

  if ($self->{failed_to_connect}) {
    my $n = 1 + $self->{failed_to_connect};
    return Mojo::IOLoop->timer(($n > 10 ? 10 : $n) * ($ENV{CONVOS_CONNECT_DELAY} || 4),
      sub { $self and $self->user->core->connect($self, 'You got disconnected.') });
  }

  return $self->user->core->connect($self, sprintf 'You got disconnected from %s.',
    $self->url->host);
}

sub _stream_on_error {
  my ($self, $stream, $err) = @_;

  $self->_notice($err, type => 'error');
  Mojo::IOLoop->remove(delete $self->{stream_id}) if $self->{stream_id};

  my $url = $self->url;
  if ($url->query->param('tls') and ($err =~ /IO::Socket::SSL/ or $err =~ /SSL.*HELLO/)) {
    $self->state(disconnected => $err);
    $url->query->param(tls => 0);
    $self->user->core->connect($self, $err);    # let's queue up to make irc admins happy
  }
  else {
    $self->state(disconnected => $err);
  }
}

sub _stream_on_read {
  my ($self, $stream, $buf) = @_;
  die 'Method "_stream_on_read" not implemented.';
}

sub _stream_remove {
  my ($self, $p) = @_;
  my $stream = delete $self->{stream};
  $stream->close if $stream;
  $p->resolve({});
}

sub _write_p {
  my ($self, @data) = @_;

  my $buf = join ' ', @data;
  my $p   = Mojo::Promise->new;
  return $p->resolve({})                  unless length $buf;
  return $p->reject('Not connected.')     unless $self->{stream_id};
  return $p->reject('Not yet connected.') unless $self->{stream};
  return $p->reject('Disconnecting.') if $self->{disconnecting};

  $self->_write("$buf\r\n", sub { $p->resolve({}) });

  return $p;
}

sub _write {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my ($self, $buf) = @_;

  unless ($self->{stream}) {
    Mojo::IOLoop->next_tick(sub { $self->$cb('Not connected.') }) if $cb;
    return;
  }

  $self->_debug('<<< %s', term_escape $buf) if DEBUG;
  $self->{stream}->write(Unicode::UTF8::encode_utf8($buf, sub { $_[0] }), $cb ? ($cb) : ());
}

sub TO_JSON {
  my ($self, $persist) = @_;
  my $url  = $self->url;
  my %json = map { ($_, $self->$_) } qw(name protocol wanted_state);

  $json{connection_id}       = $self->id;
  $json{on_connect_commands} = $self->on_connect_commands;
  $json{url}                 = $url->to_unsafe_string;

  if (!$persist and $url->query->param('forced')) {
    my $password = $url->password // '';
    $json{url} =~ s!:$password\@!@!;
  }

  if ($persist) {
    $json{dialogs} = [map { $_->TO_JSON($persist) } @{$self->dialogs}];
  }
  else {
    $json{state} = $self->state;
  }

  return \%json;
}

1;

=encoding utf8

=head1 NAME

Convos::Core::Connection - A Convos connection base class

=head1 DESCRIPTION

L<Convos::Core::Connection> is a base class for L<Convos> connections.

See also L<Convos::Core::Connection::Irc>.

=head1 EVENTS

=head2 dialog

  $conn->on(dialog => sub { my ($conn, $dialog) = @_; });

Emitted when a new L<$dialog|Convos::Core::Dialog> is created.

=head2 me

  $conn->on(me => sub { my ($conn, $me) = @_; });

Emitted when information about the representation of L</user> changes. C<$me>
contains:

  {
    nick                     => $str,
    real_host                => $str,
    version                  => $str,
    available_user_modes     => $str,
    available_channel_modes  => $str,
  }

Note that this hash is L<Convos::Core::Connection::Irc> specific.

=head2 message

  $conn->on(message => sub { my ($conn, $conn, $msg) = @_; });
  $conn->on(message => sub { my ($conn, $dialog, $msg) = @_; });

Emitted when a connection or dialog receives a new message. C<$msg>
will contain:

  {
    from    => $str,
    message => $str,
    type    => {action|error|notice|privmsg},
  }

=head2 state

  $conn->on(state => sub { my ($conn, $state, $reason) = @_; });

Emitted when the connection state change.

=head2 dialog

  $conn->on(dialog => sub { my ($conn, $dialog, $info) = @_; });

Emitted when the dialog change state. C<$info> will contain information about
the change:

  {join => $nick}
  {nick => $new_new, renamed_from => $old_nick_lc}
  {part => $nick, message => $reason, kicker => $kicker}
  {part => $nick, message => $reason}
  {updated => true}

=head1 ATTRIBUTES

L<Convos::Core::Connection> inherits all attributes from L<Mojo::Base> and implements
the following new ones.

=head2 id

  $str = $conn->id;
  $str = $class->id(\%attr);

Returns a unique identifier for a connection.

=head2 messages

  $obj = $conn->messages;

Holds a L<Convos::Core::Dialog> object with the conversation to the server.

=head2 name

  $str = $conn->name;

Holds the name of the connection.

=head2 protocol

  $str = $conn->protocol;

Holds the protocol name.

=head2 url

  $url = $conn->url;

Holds a L<Mojo::URL> object which describes where to connect to. This
attribute is read-only.

=head2 user

  $user = $conn->user;

Holds a L<Convos::Core::User> object that owns this connection.

=head2 wanted_state

  $conn = $conn->wanted_state("disconnected");
  $str = $conn->wanted_state;

Used to change the state that the user I<want> the connection to be in. Note
that it is also required to call L</connect> and L</disconnect> to actually
change the state.

=head1 METHODS

L<Convos::Core::Connection> inherits all methods from L<Mojo::Base> and implements
the following new ones.

=head2 connect

  $conn->connect;

Used to connect to L</url>. Meant to be overloaded in a subclass.

=head2 dialog

  $dialog = $conn->dialog(\%attrs);

Returns a new L<Convos::Core::Dialog> object or updates an existing object.

=head2 dialogs

  $objs = $conn->dialogs;

Returns an array-ref of of L<Convos::Core::Dialog> objects.

=head2 disconnect_p

  $p = $conn->disconnect_p;

Used to disconnect from server. Meant to be overloaded in a subclass.

=head2 get_dialog

  $dialog = $conn->get_dialog($id);
  $dialog = $conn->get_dialog(\%attrs);

Returns a L<Convos::Core::Dialog> object or undef.

=head2 new

  $conn = Convos::Core::Connection->new(\%attrs);

Creates a new connection object.

=head2 rtc_p

  $p = $conn->rtc_p->then(sub { my $msg = shift });

Used to handle WebRTC signalling.

=head2 save_p

  $p = $conn->save_p->then(sub { my $conn = shift });

Will save L</ATTRIBUTES> to persistent storage.
See L<Convos::Core::Backend/save_object> for details.

=head2 send_p

  $p = $conn->send_p($target => $message);

Used to send a C<$message> to C<$target>. C<$message> is a plain string and
C<$target> can be a user or room/channel name.

Meant to be overloaded in a subclass.

=head2 state

  $conn = $conn->state($state, $message);
  $state = $conn->state;

Holds the state of this object. C<$state> can be "disconnected", "connected"
or "queued" (default). "queued" means that the object is in the
process of connecting or that it want to connect.

=head2 uri

  $path = $conn->uri;

Holds a L<Mojo::Path> object, with the URI to where this object should be
stored.

=head1 SEE ALSO

L<Convos::Core>.

=cut
