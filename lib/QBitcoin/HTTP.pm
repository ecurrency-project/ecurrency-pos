package QBitcoin::HTTP;
use warnings;
use strict;

use JSON::XS;
use Time::HiRes;
use Scalar::Util qw(weaken);
use HTTP::Request;
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::Block;

use constant ATTR => qw(
    ip
    host
    port
    addr
    command
    state
    update_time
    connection
    id
);

mk_accessors(ATTR);

my $JSON = JSON::XS->new;

sub direction() { DIR_IN }
sub startup()   {}
sub type        { PROTOCOL2NAME->{shift->type_id} }

sub new {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    weaken($args->{connection}) if $args->{connection};
    $args->{update_time} //= time();
    $args->{id} = $args->{connection}->addr . pack("v", $args->{connection}->port);
    return bless $args, $class;
}

sub receive {
    my $self = shift;
    $self->update_time = time();
    $self->connection->recvbuf =~ /\n\r?\n/s
        or return 0;
    my $http_request = HTTP::Request->parse($self->connection->recvbuf);
    my $length = $http_request->headers->content_length;
    return 0 if defined($length) && length($http_request->content) < $length;
    $self->connection->recvbuf = "";
    my $res = eval { $self->process_request($http_request) };
    if ($@) {
        Errf("process_http exception: %s", "$@");
        $self->response_error("Internal error", ERR_INTERNAL_ERROR);
        return -1;
    }
    return $res;
}

sub send {
    my $self = shift;
    my ($data) = @_;

    if ($self->connection->sendbuf eq '' && $self->connection->socket) {
        my $n = syswrite($self->connection->socket, $data);
        if (!defined($n)) {
            Errf("Error write to socket: %s", $!);
            return -1;
        }
        elsif ($n > 0) {
            if ($n < length($data)) {
                substr($data, 0, $n, "");
            }
            else {
                $self->connection->disconnect();
                return 0;
            }
        }
        $self->connection->sendbuf = $data;
    }
    else {
        $self->connection->sendbuf .= $data;
    }
    return 0;
}

# Called from $tx->process_pending() for transactions received by "sendrawtransaction"
sub process_tx {
    my $self = shift;
    my ($tx) = @_;

    my $rc = $tx->receive();
    return $rc if !defined($rc) || $rc != 0; # propagate undef (mempool full) or error
    if (defined(my $height = QBitcoin::Block->recv_pending_tx($tx))) {
        return -1 if $height == -1;
        # $self->request_new_block($height+1);
    }
    if ($tx->fee >= 0) {
        # announce to other peers
        $tx->announce();
    }
    elsif (!$tx->in_blocks && !$tx->block_height) {
        Debugf("Ignore stake transactions %s not related to any known block", $tx->hash_str);
        $tx->drop();
    }
    return 0;
}

sub get_block_by_hash {
    my $self = shift;
    my ($hash) = @_;

    my $block = QBitcoin::Block->block_pool($hash) // QBitcoin::Block->find(hash => $hash);
    return $block;
}

1;
