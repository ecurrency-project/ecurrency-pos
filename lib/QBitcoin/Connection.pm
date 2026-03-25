package QBitcoin::Connection;
use warnings;
use strict;

use Socket qw(inet_ntoa);
use POSIX qw(:errno_h);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ProtocolState qw(blockchain_synced sync_peer);
use QBitcoin::Protocol;
use QBitcoin::RPC;
use QBitcoin::ConnectionList;
use Bitcoin::Protocol;

mk_accessors(qw(peer ip socket id state_time state port my_ip my_port my_addr direction));
mk_accessors(qw(protocol type_id sendbuf recvbuf socket_fileno));

use constant MODULE_BY_TYPE => {
    &PROTOCOL_QBITCOIN => "QBitcoin::Protocol",
    &PROTOCOL_BITCOIN  => "Bitcoin::Protocol",
    &PROTOCOL_RPC      => "QBitcoin::RPC",
    &PROTOCOL_REST     => "QBitcoin::REST",
};

sub new {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    my $self = bless $attr, $class;
    $attr->{type_id} //= $attr->{peer}->type_id if $attr->{peer};
    $attr->{ip} //= inet_ntoa($attr->{peer}->ipv4) if $attr->{peer} && $attr->{peer}->ipv4;
    my $protocol_module = MODULE_BY_TYPE->{$attr->{type_id}}
        or die "Unknown connection type [$attr->{type_id}]";
    $self->protocol = $protocol_module->new(connection => $self);
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->socket_fileno = fileno($self->socket) if $self->socket;
    $self->id = $self->protocol->id;
    QBitcoin::ConnectionList->add($self);
    return $self;
}

sub host { $_[0]->peer->host }
sub addr { $_[0]->{addr} // $_[0]->peer->ip } # binary packed ipv6
sub type { PROTOCOL2NAME->{$_[0]->type_id} }

sub disconnect {
    my $self = shift;
    if ($self->socket) {
        shutdown($self->socket, 2);
        close($self->socket);
        $self->socket = undef;
        $self->socket_fileno = undef;
    }
    if ($self->state == STATE_CONNECTED) {
        if ($self->peer) {
            Infof("Disconnected from %s peer %s", $self->type, $self->ip);
            if (!blockchain_synced() && sync_peer() && sync_peer() == $self->protocol) {
                sync_peer(undef);
            }
            if ($self->protocol->can('drop_pending')) {
                $self->protocol->drop_pending();
            }
            $self->protocol->syncing(0); # allow to free non-best blocks and branches received in this connection
            # TODO: update peer data
        }
        else {
            # Debugf("Disconnected from %s API client %s:%u", $self->type, $self->ip, $self->port);
        }
    }
    $self->state = STATE_DISCONNECTED;
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->protocol = undef;
    QBitcoin::ConnectionList->del($self);
    return 0;
}

sub failed {
    my $self = shift;

    if ($self->peer && !$self->protocol->greeted && $self->direction == DIR_OUT) {
        $self->peer->failed_connect();
    }
    $self->disconnect();
}

sub send {
    my $self = shift;
    my ($data) = @_;

    if ($self->state != STATE_CONNECTED) {
        Errf("Attempt to send to %s peer %s with state %s", $self->type, $self->ip // "unknown", $self->state);
        return -1;
    }
    if ($self->sendbuf eq '' && $self->socket) {
        my $n = syswrite($self->socket, $data);
        if (!defined($n)) {
            if ($! == EAGAIN) {
                Debugf("Error write to socket: %s", $!);
            }
            else {
                Warningf("Error write to socket: %s", $!);
            }
            # May be EAGAIN (Resource temporarily unavailable), save data in savebuf and try to send it later
        }
        elsif ($n > 0) {
            return 0 if $n == length($data);
            substr($data, 0, $n, "");
        }
        $self->sendbuf = $data;
    }
    else {
        $self->sendbuf .= $data;
    }
    return 0;
}

1;
