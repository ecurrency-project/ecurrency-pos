package QBitcoin::Protocol::Common;
use warnings;
use strict;

use Scalar::Util qw(weaken);
use Time::HiRes;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::Crypto qw(checksum32);

use constant ATTR => qw(
    greeted
    syncing
    has_pending
    command
    ping_sent
    last_cmd_ping
    connection
    peer
    last_recv_time
    last_traffic_time
    id
);

mk_accessors(ATTR);

sub new {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    weaken($args->{connection}) if $args->{connection};
    my $self = bless $args, $class;
    $self->peer //= $self->connection->peer if $self->connection;
    $self->last_recv_time = time();
    $self->last_traffic_time = Time::HiRes::time();
    $self->id = $self->connection->addr;
    return $self;
}

sub type_id {
   die "Unknown peer type " . ref($_[0]) . "\n";
}

sub type { PROTOCOL2NAME->{shift->type_id} }

sub magic { $config->{testnet} ? $_[0]->MAGIC_TESTNET : $_[0]->MAGIC }

sub receive {
    my $self = shift;
    while (length($self->connection->sendbuf) < WRITE_BUFFER_SIZE) {
        length($self->connection->recvbuf) >= 24 # sizeof(struct message_header)
            or return 0;
        my ($magic, $command, $length, $checksum) = unpack("a4a12Va4", substr($self->connection->recvbuf, 0, 24));
        $command =~ s/\x00+\z//;
        $self->command = $command;
        if ($magic ne $self->magic) {
            Noticef("Incorrect magic: 0x%s, expected 0x%s", unpack("H*", $magic), unpack("H*", $self->magic));
            $self->abort("protocol_error");
            return -1;
        }
        if ($length + 24 > READ_BUFFER_SIZE) {
            Errf("Too long data packet for command %s, %u bytes", $command, $length);
            $self->abort("too_long_packet");
            return -1;
        }
        length($self->connection->recvbuf) >= $length + 24
            or return 0;
        my $message = substr($self->connection->recvbuf, 0, 24+$length, "");
        my $data = substr($message, 24);
        my $checksum32 = checksum32($data);
        if ($checksum ne $checksum32) {
            Errf("Incorrect message checksum, 0x%s != 0x%s", unpack("H*", $checksum), unpack("H*", $checksum32));
            $self->abort("bad_crc32");
            return -1;
        }
        my $func = "cmd_" . $command;
        if ($self->can($func)) {
            $self->last_recv_time = time();
            Debugf("Received [%s] from %s peer %s", $command, $self->type, $self->peer->id);
            if ($command ne "pong") {
                # Reset "syncing" state if we received no commands between send "ping" and receive corresponding "pong"
                $self->last_cmd_ping = undef;
            }
            if ($command ne "version" && !$self->greeted) {
                Errf("command [%s] before greeting from %s peer %s", $command, $self->type, $self->peer->id);
                $self->abort("protocol_error");
                return -1;
            }
            $self->$func($data) == 0
                or return -1;
            $self->peer->recv_good_command($self->connection->direction);
        }
        else {
            Errf("Unknown command [%s] from %s peer %s", $command, $self->type, $self->peer->id);
            $self->abort("unknown_command");
            return -1;
        }
    }
}

sub send_message {
    my $self = shift;
    my ($cmd, $data) = @_;
    if (!$self->connection) {
        Debugf("Skip sending [%s] to closed %s connection peer %s", $cmd, $self->type, $self->peer->id);
        return -1;
    }
    else {
        Debugf("Send [%s] to %s peer %s", $cmd, $self->type, $self->peer->id);
        return $self->connection->send(pack("a4a12Va4", $self->magic, $cmd, length($data), checksum32($data)) . $data);
    }
}

1;
