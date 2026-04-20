package QBitcoin::Test::BlockSerialize;
use warnings;
use strict;

use JSON::XS;
use Test::MockModule;
use QBitcoin::Const;
BEGIN {
    no warnings 'redefine';
    *QBitcoin::Const::UPGRADE_POW = sub () { 0 };
    *QBitcoin::Const::GENESIS_TIME = sub () { 1767220000 };
};
use QBitcoin::Config;
use QBitcoin::Block;
use Bitcoin::Serialized;

use Exporter qw(import);
our @EXPORT = qw(block_hash);

sub mock_block_serialize {
    my $self = shift;
    varstr(encode_json({
        time        => $self->time+0,
        weight      => $self->weight+0,
        hash        => $self->hash,
        prev_hash   => $self->prev_hash,
        tx_hashes   => $self->tx_hashes,
        merkle_root => $self->merkle_root,
    }));
}

sub mock_block_deserialize {
    my $class = shift;
    my ($data) = @_;
    my $block = $class->new(decode_json($data->get_string));
    $block->reward_fund = 0;
    return $block;
}

sub mock_self_weight {
    my $self = shift;
    return $self->{self_weight} //= !defined($self->weight) ? 10 :
        $self->prev_block ? $self->weight - $self->prev_block->weight : $self->weight;
}

my $block_hash;

sub block_hash {
    $block_hash = shift;
}

my $block_module;
CHECK {
    $block_module = Test::MockModule->new('QBitcoin::Block');
    $block_module->mock('serialize', \&mock_block_serialize);
    $block_module->mock('deserialize', \&mock_block_deserialize);
    $block_module->mock('self_weight', \&mock_self_weight);
    $block_module->mock('calculate_hash', sub { $_[0]->{hash} // $block_hash });
    $config->{fake_coinbase} = 1;
};

1;
