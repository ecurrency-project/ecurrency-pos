#! /usr/bin/env perl
use warnings;
use strict;

# The equivocation evidence states the value and the scripthash of every output its
# stakes spend, so the input scripts of the stakes are verified exactly as they were in
# the block. A script reading the spent output (OP_INPUTSVALUE, OP_INPUTSCRIPTHASH: the
# delegation covenant does) must give the same result there, otherwise a stake valid in
# a block would be no proof, i.e. free to equivocate.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(signature generate_keypair hash160 hash256);
use QBitcoin::Address qw(wallet_import_format);
use QBitcoin::MyAddress;
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script::Util qw(pack_int);
use QBitcoin::Script::Delegation qw(delegation_script SELECTOR_DELEGATE);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Slashing;

$config->{regtest} = 1;

my $timeslot = timeslot(GENESIS_TIME + 1000);
# Two different blocks of one timeslot
my @bsd = map { $_->[0] . pack("N", $timeslot) . $_->[1] } [ "\x11" x 32, "\xa1" x 32 ], [ "\x22" x 32, "\xb2" x 32 ];

my $key    = QBitcoin::MyAddress->new(private_key => wallet_import_format(generate_keypair(CRYPT_ALGO_ECDSA)->pk_serialize));
my $pubkey = $key->pubkey;
my $p2pk   = op_pushdata($pubkey) . OP_CHECKSIG;

my $coin_num = 0;
sub make_coin {
    my ($script, $hash_func, $value) = @_;
    my $coin = QBitcoin::TXO->new_txo({
        tx_in      => pack("C", ++$coin_num) x 32,
        num        => 0,
        value      => $value,
        scripthash => $hash_func->($script),
    });
    $coin->set_redeem_script($script) == 0 or die "set_redeem_script failed\n";
    return $coin;
}

# A stake returning the coins to their addresses, every input really signed for the
# block; @siglist_tail follows the signature (pubkey, branch selector)
sub signed_stake {
    my ($coins, $bsd, @siglist_tail) = @_;
    my $stake = QBitcoin::Transaction->new(
        in              => [ map +{ txo => $_, siglist => [] }, @$coins ],
        out             => [ map { QBitcoin::TXO->new_txo({ value => $_->value, scripthash => $_->scripthash }) } @$coins ],
        fee             => 0,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $bsd,
    );
    foreach my $num (0 .. $#{$stake->in}) {
        my $sig = signature($stake->sign_data($num, SIGHASH_ALL), $key, CRYPT_ALGO_ECDSA, SIGHASH_ALL);
        $stake->in->[$num]->{siglist} = [ $sig, @siglist_tail ];
    }
    $stake->calculate_hash;
    return $stake;
}

# The slashing transaction for the same coins double-signed
sub double_sign {
    my ($coins1, $coins2, @siglist_tail) = @_;
    my $stake1 = signed_stake($coins1, $bsd[0], @siglist_tail);
    my $stake2 = signed_stake($coins2, $bsd[1], @siglist_tail);
    return (QBitcoin::Slashing->new_tx($stake1, $stake2), $stake1, $stake2);
}

# The same slashing transaction with other spent outputs stated in its evidence:
# $change gets the two proofs, each with its prevouts as a list of [ value, hash_len ]
sub restate {
    my ($slash, $change) = @_;
    my @proofs = map { +{ %$_ } } @{$slash->slashing->proofs};
    $_->{prevouts} = [ map { [ unpack("Q<C", $_) ] } unpack("(a9)*", $_->{prevouts}) ] foreach @proofs;
    $change->(@proofs);
    $_->{prevouts} = join("", map { pack("Q<C", @$_) } @{$_->{prevouts}}) foreach @proofs;
    my $tx = QBitcoin::Transaction->new(
        in       => $slash->in,
        out      => $slash->out,
        tx_type  => TX_TYPE_SLASHING,
        slashing => QBitcoin::Slashing->new(proofs => \@proofs),
    );
    $tx->calculate_fee;
    $tx->calculate_hash;
    return $tx;
}

# --- scripts reading the spent output remain slashable
my @reading = (
    [ "value of the spent output", \&hash256,
        OP_INPUTSCRIPTHASH . OP_INPUTSVALUE . OP_1 . OP_GREATERTHANOREQUAL . OP_VERIFY . $p2pk ],
    [ "form of the own scripthash", \&hash160,
        OP_INPUTSCRIPTHASH . OP_SIZE . OP_NIP . op_pushdata(pack_int(20)) . OP_NUMEQUALVERIFY . $p2pk ],
);
foreach my $case (@reading) {
    my ($name, $hash_func, $script) = @$case;
    my $coin = make_coin($script, $hash_func, 1000);
    my ($slash, $stake1, $stake2) = double_sign([ $coin ], [ $coin ]);
    is($stake1->check_input_script, 0, "$name: stake 1 is valid for its block");
    is($stake2->check_input_script, 0, "$name: stake 2 is valid for its block");
    ok($slash, "$name: slashing tx built");
    is($slash->validate, 0, "$name: the double-signed stake is slashable");
    is($slash->out->[0]->value, 900, "$name: refund is the value minus the fine");
}

# --- a delegate with two clients, a short (hash160) and a long (hash256) delegated
# address: each covenant compares the inputs and the outputs of its own address
{
    my @coins = (
        make_coin(delegation_script("\x77" x 20, hash160($pubkey)), \&hash160, 1000),
        make_coin(delegation_script("\x88" x 32, hash160($pubkey)), \&hash256, 5000),
    );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my ($slash, $stake1) = double_sign(\@coins, \@coins, $pubkey, SELECTOR_DELEGATE);
    is($stake1->check_input_script, 0, "delegation: the stake is valid for its block");
    is($slash->validate, 0, "delegation: the double-signed stake of both clients is slashable");
    is_deeply([ sort { $a <=> $b } map { $_->value } @{$slash->out} ], [ 900, 4500 ], "delegation: each client is refunded minus the fine");
    is("@warnings", "", "delegation: no perl warnings verifying the evidence");
}

# --- the evidence must state the real slashed output
{
    my $coin = make_coin($p2pk, \&hash256, 1000);
    my ($slash) = double_sign([ $coin ], [ $coin ]);
    is($slash->validate, 0, "p2pk: slashing tx validates");
    is($slash->slashing->proofs->[0]->{prevouts}, pack("Q<C", 1000, 32), "p2pk: the proof states the value and the scripthash length");
    is(restate($slash, sub {})->hash, $slash->hash, "restated unchanged: the same transaction");

    my %invalid = (
        "another value"               => sub { $_->{prevouts}->[0]->[0] = 999 foreach @_ },
        "another form of scripthash"  => sub { $_->{prevouts}->[0]->[1] = 20 foreach @_ },
        "the proofs disagree"         => sub { $_[0]->{prevouts}->[0]->[0] = 999 },
        "unknown form of scripthash"  => sub { $_->{prevouts}->[0]->[1] = 21 foreach @_ },
        "no data for an input"        => sub { $_->{prevouts} = [] foreach @_ },
        "data for a missing input"    => sub { push @{$_->{prevouts}}, [ 1000, 32 ] foreach @_ },
    );
    foreach my $name (sort keys %invalid) {
        isnt(restate($slash, $invalid{$name})->validate, 0, "slashed output, $name: rejected");
    }
}

# --- the other inputs of the stakes are not the verifier's to know: their stated data
# is not checked against anything, so that the validity of a slashing transaction never
# depends on which outputs a node happens to have
{
    my ($coin_a, $coin_b, $coin_c) = map { make_coin($p2pk, \&hash256, $_) } 1000, 2000, 4000;
    my ($slash) = double_sign([ $coin_a, $coin_b ], [ $coin_b, $coin_c ]);
    is($slash->validate, 0, "partial overlap: slashing tx validates");
    is(scalar @{$slash->in}, 1, "partial overlap: only the shared output is slashed");
    my $other = restate($slash, sub {
        my ($p1, $p2) = @_;
        $p1->{prevouts}->[0]->[0] = 1; # coin_a in stake 1
        $p2->{prevouts}->[1]->[0] = 2; # coin_c in stake 2
    });
    isnt($other->hash, $slash->hash, "other inputs restated: another transaction");
    is($other->validate, 0, "other inputs restated: still valid");
    is($other->out->[0]->value, 1800, "other inputs restated: refund by the real slashed output");
}

done_testing();
