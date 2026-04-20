#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Block;
use QBitcoin::ProtocolState qw(blockchain_synced);
use Bitcoin::Serialized;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });
$config->{regtest} = 1;

# parent process accept and check results; child execute subchilds and wait them
pipe my $rh, my $wh;
my $base_pid = fork();
close($base_pid ? $wh : $rh);

# height, hash, prev_hash, weight [, self_weight]
send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "a3", "a2",  300 ],
], [ 2, "a3", 300 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "b3", "b2",  300 ],
], [ 1, "a2", 200 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "b3", "b2",  300, 150 ],
    [ 1, "b2", "a1",  150 ],
], [ 2, "b3", 300 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "a3", "a2",  300 ],
    [ 1, "b2", "a1",  210 ],
    [ 2, "b3", "b2",  290 ],
], [ 2, "a3", 300 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "b2", "a1",  210 ],
    [ 2, "b3", "b2",  290 ],
    [ 2, "a3", "a2",  300, 100 ],
    [ 1, "a2", "a1",  200 ],
], [ 2, "a3", 300 ]);

sub send_blocks {
    my ($blocks, $expect) = @_;

    # Create new blockchain from scratch for each send_blocks() call
    if ($base_pid) {
        my $res = <$rh>;
        chomp($res);
        my ($height, $hash, $weight) = split(/\s+/, $res);
        state $n=1;
        subtest "branch " . $n++ => sub {
            is($height, $expect->[0], "height");
            is($hash,   $expect->[1], "hash");
            is($weight, $expect->[2], "weight");
        };
        return;
    }
    my $pid = fork();
    if ($pid) {
        waitpid($pid, 0);
        die if $?;
    }
    elsif (defined($pid)) {
        # child
        my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => "127.0.0.1");
        my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
        $connection->protocol->command = "block";
        blockchain_synced(1); # for save blocks with unknown ancestors
        foreach my $block_data (@$blocks) {
            my $block = QBitcoin::Block->new(
                time         => GENESIS_TIME + $block_data->[0] * BLOCK_INTERVAL * FORCE_BLOCKS,
                hash         => $block_data->[1],
                prev_hash    => $block_data->[2],
                weight       => $block_data->[3],
                self_weight  => $block_data->[4],
                merkle_root  => ZERO_HASH,
                transactions => [],
            );
            my $block_data = $block->serialize;
            block_hash($block->hash);
            $connection->protocol->cmd_block($block_data);
        }
        my $height = QBitcoin::Block->blockchain_height;
        my $weight = QBitcoin::Block->best_weight;
        my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
        my $hash   = $block ? $block->hash : undef;
        print $wh join(' ', $height // "", $hash // "", $weight // "") . "\n";
        exit(0);
    }
    else {
        die "Can't fork: $!\n";
    }
}

if ($base_pid) {
    waitpid($base_pid, 0);
    die if $?;
    done_testing();
}
