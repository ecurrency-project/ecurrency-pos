package QBitcoin::Protocol::BTC;
use warnings;
use strict;
use feature 'state';

# ihave_btc <block_hash>
# on receive, if we have no such block, send "send_btc_header <block_hash>"
# on receive btc_header, if we have prev_block, then simple add the new block to the chain
# if no prev block - send "send_btc_header <prev_hash>"

use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::ProtocolState qw(blockchain_synced btc_synced);
use Bitcoin::Block;
use Bitcoin::Serialized;

use Role::Tiny;
use Role::Tiny::With;
with 'Bitcoin::Protocol::ProcessBlock';

use constant PROTOCOL_VERSION => 1;
use constant MAX_BTC_HEADERS  => 2000;
use constant MAX_BTC_LOCATORS => 101;

sub genesis_time() {
    state $genesis_time = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
    return $genesis_time;
}

sub announce_btc_block {
    my $self = shift;
    my ($block) = @_;
    $self->send_message("btc_ihave", pack("a32", $block->hash));
}

sub announce_best_btc_block {
    my $self = shift;
    my ($best_btc_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
    if ($best_btc_block) {
        $self->announce_btc_block($best_btc_block);
    }
}

sub cmd_btc_ihave {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    if (btc_synced()) {
        my ($hash) = unpack("a32", $data);
        if (!Bitcoin::Block->find(hash => $hash)) {
            $self->send_message("btcgetheader", pack("a32", $hash));
        }
    }
    return 0;
}

sub cmd_btcgetheader {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $hash = unpack("a32", $data);
    my ($block) = Bitcoin::Block->find(hash => $hash);
    if ($block) {
        $self->send_message("btcblockhdr", $block->serialize);
    }
    else {
        Warningf("I have no ecr-pow block with hash %s requested by peer %s", unpack("H*", scalar reverse $hash), $self->peer->id);
    }
    return 0;
}

sub cmd_btcblockhdr {
    my $self = shift;
    my ($payload) = @_;
    my $data = Bitcoin::Serialized->new($payload);
    my $block = Bitcoin::Block->deserialize($data);
    if (!$block) {
        Err("ECR-PoW block deserialization error");
        $self->abort("bad_btcblockhdr");
        return -1;
    }
    if (!$block->validate) {
        Errf("ECR-PoW block %s validation error", $block->hash_hex);
        $self->abort("bad_btcblockhdr");
        return -1;
    }
    Debugf("Received ecr-pow block header: %s, prev_hash %s", $block->hash_hex, $block->prev_hash_hex);
    return 0 if Bitcoin::Block->find(hash => $block->hash);
    my $db_transaction = QBitcoin::ORM::Transaction->new;
    if ($self->process_btc_block($block)) {
        $block->scanned = $block->time >= genesis_time ? 0 : 1;
        $block->create();
        $self->have_block0(1);
        $db_transaction->commit;
    }
    else {
        $db_transaction->rollback;
        $self->request_btc_blocks();
    }

    return 0;
}

sub request_btc_blocks {
    my $self = shift;
    my @locators = @_;
    my @blocks = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 10);
    push @locators, map { $_->hash } @blocks;
    if (@locators == 0) {
        @locators = (ZERO_HASH);
    }
    elsif ($blocks[-1]->height > 0) { # It's not possible to have only blocks with undefined height
        my $step = 4;
        my $height = $blocks[-1]->height - $step;
        my @height;
        while ($height > 0) {
            push @height, $height;
            last if @height + @locators >= MAX_BTC_LOCATORS-1;
            $step *= 2;
            $step = 100000 if $step > 100000;
            $height -= $step;
        };
        push @height, 0;
        push @locators, map { $_->hash } Bitcoin::Block->find(-sortby => 'height DESC', height => \@height);
    }
    $self->send_message("btcgethdrs", pack("V", PROTOCOL_VERSION) . varint(scalar(@locators)) . join("", @locators) . ZERO_HASH);
}

sub cmd_btcgethdrs {
    my $self = shift;
    my ($payload) = @_;
    if (length($payload) < 5) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($payload));
        $self->abort("incorrect_params");
        return -1;
    }
    my $data = Bitcoin::Serialized->new($payload);
    my $protocol = $data->get(4);
    my $locators = $data->get_varint;
    my $height = 0;
    while (my $hash = $data->get(32)) {
        last if $hash eq ZERO_HASH;
        my ($block) = Bitcoin::Block->find(hash => $hash);
        if ($block && defined($block->height)) {
            $height = $block->height+1;
            last;
        }
    }
    my @blocks = Bitcoin::Block->find(height => { '>=' => $height }, -sortby => 'height ASC', -limit => MAX_BTC_HEADERS);
    $self->send_message("btcheaders", varint(scalar(@blocks)) . join('', map { $_->serialize } @blocks));
    return 0;
}

sub cmd_btcheaders {
    my $self = shift;
    my ($payload) = @_;
    if (length($payload) == 0) {
        Errf("Incorrect params from peer %s cmd %s data length %u", $self->peer->id, $self->command, length($payload));
        $self->abort("incorrect_params");
        return -1;
    }
    my $data = Bitcoin::Serialized->new($payload);
    my $num = $data->get_varint();
    if ($data->length != $num*80) {
        Errf("Incorrect params from peer %s cmd %s data length %u expected %u", $self->peer->id, $self->command, $data->length, $num*80);
        $self->abort("incorrect_params");
        return -1;
    }
    my $known_block;
    my $new_block;
    my $orphan_block;
    my $last_orphan_block;
    for (my $i = 0; $i < $num; $i++) {
        my $block = Bitcoin::Block->deserialize($data);
        if (!$block) {
            Errf("Bad ecr-pow block header, deserializes error");
            $self->abort("bad_block_header");
            return -1;
        }
        elsif (!$block->validate) {
            Errf("Bad ecr-pow block %s header, validate error", $block->hash_hex);
            $self->abort("bad_block_header");
            return -1;
        }
        Debugf("Received ecr-pow block header: %s, prev_hash %s", $block->hash_hex, $block->prev_hash_hex);
        my $existing = Bitcoin::Block->find(hash => $block->hash);
        if ($existing) {
            $known_block = $existing;
        }
        else {
            my $db_transaction = QBitcoin::ORM::Transaction->new;
            if ($self->process_btc_block($block)) {
                $new_block = $block;
                $block->scanned = $block->time >= genesis_time ? 0 : 1;
                $block->create();
                $self->have_block0(1);
                $db_transaction->commit;
            }
            else {
                $orphan_block //= $block;
                $last_orphan_block = $block;
                $db_transaction->rollback;
            }
        }
        # my $tx_num = $data->get_varint(); # always 0
    }
    if ($orphan_block) {
        if ($self->have_block0) {
            $self->request_btc_blocks();
        }
        else {
            # Is it genesis block? Request it
            Debugf("Request genesis block %s", $orphan_block->prev_hash_hex);
            $self->send_message("btcgetheader", pack("a32", $orphan_block->prev_hash));
        }
    }
    elsif ($new_block) {
        $self->request_btc_blocks();
    }
    elsif ($known_block && $num == MAX_BTC_HEADERS) {
        # All received block are known for us. Was it deep rollback?
        if (defined(my $start_height = $known_block->height)) {
            my @blocks = Bitcoin::Block->find(height => [ map { $start_height + $_*int(MAX_BTC_HEADERS*0.95) } 1 .. 250 ], -sortby => "height DESC");
            $self->send_message("btcgethdrs", pack("V", PROTOCOL_VERSION) .
                varint(scalar(@blocks) + 1) . join("", map { $_->hash } @blocks) . $known_block->hash . ZERO_HASH);
        }
        else {
            # This block is not in our best brunch, request blocks started on it
            # We have no orphan ecr-pow blocks in our database
            my @hashes = ($known_block->hash);
            push @hashes, $known_block->prev_hash if $known_block->prev_hash ne ZERO_HASH;
            $self->send_message("btcgethdrs", pack("V", PROTOCOL_VERSION) .
                varint(scalar(@hashes) + 1) . join("", @hashes) . ZERO_HASH);
        }
    }
    elsif ($self->have_block0) {
        if (!btc_synced()) {
            Debugf("Set btc_synced to 1");
            btc_synced(1);
            $self->syncing(0);
            foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
                blockchain_synced() ? $connection->protocol->request_mempool : $connection->protocol->request_new_block();
            }
        }
    }
    return 0;
}

1;
