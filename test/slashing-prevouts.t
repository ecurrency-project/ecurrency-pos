#! /usr/bin/env perl
use warnings;
use strict;

# The input scripts of the stakes in equivocation evidence are verified exactly as they
# were in the block. A script reading the output it spends (OP_INPUTSVALUE,
# OP_INPUTSCRIPTHASH: the delegation covenant does) must give the same result there,
# otherwise a stake valid in a block would be no proof, i.e. free to equivocate.
# The inputs shared by both stakes are the inputs of the slashing transaction, the real
# UTXO. The value and the scripthash of the other inputs are stated by the evidence
# (prevouts); only the scripts of the shared inputs are run.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(signature_hash generate_keypair hash160 hash256);
use QBitcoin::Address qw(wallet_import_format);
use QBitcoin::MyAddress;
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script::Util qw(pack_int);
use QBitcoin::Script::Delegation qw(delegation_script SELECTOR_DELEGATE);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Slashing;
use Bitcoin::Serialized qw(varstr);

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
        my $sig = signature_hash($stake->sign_hash($num, SIGHASH_ALL), $key, CRYPT_ALGO_ECDSA, SIGHASH_ALL);
        $stake->in->[$num]->{siglist} = [ $sig, @siglist_tail ];
    }
    $stake->calculate_hash;
    return $stake;
}

# The slashing transaction for the coins double-signed
sub double_sign {
    my ($coins1, $coins2, @siglist_tail) = @_;
    my $stake1 = signed_stake($coins1, $bsd[0], @siglist_tail);
    my $stake2 = signed_stake($coins2, $bsd[1], @siglist_tail);
    return (QBitcoin::Slashing->new_tx($stake1, $stake2), $stake1, $stake2);
}

sub slashing_tx {
    my ($evidence, @txo) = @_;
    my @in = map +{ txo => $_, siglist => [] }, @txo;
    my $tx = QBitcoin::Transaction->new(
        in       => \@in,
        out      => [ QBitcoin::Slashing->canonical_outputs(\@in) ],
        tx_type  => TX_TYPE_SLASHING,
        slashing => $evidence,
    );
    $tx->calculate_fee;
    $tx->calculate_hash;
    return $tx;
}

# The same slashing transaction with other prevouts stated in its evidence:
# $change gets the two proofs, each with its prevouts as a list of [ value, hash_len ]
sub restate {
    my ($slash, $change) = @_;
    my @proofs = map { +{ %$_ } } @{$slash->slashing->proofs};
    $_->{prevouts} = [ map { [ unpack("Q<C", $_) ] } unpack("(a9)*", $_->{prevouts}) ] foreach @proofs;
    $change->(@proofs);
    $_->{prevouts} = join("", map { pack("Q<C", @$_) } @{$_->{prevouts}}) foreach @proofs;
    return slashing_tx(QBitcoin::Slashing->new(proofs => \@proofs), map { $_->{txo} } @{$slash->in});
}

# A real output with the same reference but other data
sub other_coin {
    my ($coin, %data) = @_;
    return QBitcoin::TXO->new_txo({ tx_in => $coin->tx_in, num => $coin->num, value => $coin->value, scripthash => $coin->scripthash, %data });
}

sub deserialize {
    my ($tx) = @_;
    my $data = Bitcoin::Serialized->new($tx->serialize);
    my $res = QBitcoin::Transaction->deserialize($data);
    return $res && $data->length == 0 ? $res : undef;
}

# --- scripts reading the output they spend remain slashable
my $min_value = OP_INPUTSCRIPTHASH . OP_INPUTSVALUE . op_pushdata(pack_int(1000)) . OP_GREATERTHANOREQUAL . OP_VERIFY . $p2pk;
my @reading = (
    [ "value of the spent output", \&hash256, $min_value ],
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

# --- stakes of the same inputs: nothing to state, the shared outputs are the real ones
{
    my $coin = make_coin($min_value, \&hash256, 1000);
    my ($slash) = double_sign([ $coin ], [ $coin ]);
    my $evidence = $slash->slashing;
    is($slash->validate, 0, "shared: slashing tx validates");
    is(join("", map { $_->{prevouts} } @{$evidence->proofs}), "", "shared: no prevouts");
    is($evidence->serialize, join("", map { $_->{prev_hash} . pack("N", $_->{timeslot}) . $_->{digest} . varstr($_->{raw}) } @{$evidence->proofs}),
        "shared: the evidence is just the two proofs");
    is(deserialize($slash)->hash, $slash->hash, "shared: wire round-trip");

    isnt(slashing_tx($evidence, other_coin($coin, scripthash => hash256($p2pk)))->validate, 0,
        "shared: the redeem script of the stakes must be the script of the real output");
    isnt(slashing_tx($evidence, other_coin($coin, value => 999))->validate, 0,
        "shared: the scripts are run for the value of the real output");
    is(slashing_tx($evidence, other_coin($coin, value => 2000))->validate, 0,
        "shared: ...whatever value the stakes were made for");
}

# --- inputs of one stake only: the evidence states their value and scripthash
{
    # The address stakes at least 1000 in a transaction: the first coin alone is not enough
    my ($coin, $coin_a, $coin_b) = map { make_coin($min_value, \&hash160, $_) } 400, 600, 700;
    my ($slash, $stake1, $stake2) = double_sign([ $coin, $coin_a ], [ $coin, $coin_b ]);
    is($stake1->check_input_script, 0, "unshared: stake 1 is valid for its block");
    is($stake2->check_input_script, 0, "unshared: stake 2 is valid for its block");
    is(scalar @{$slash->in}, 1, "unshared: only the shared output is slashed");
    is_deeply([ map { $_->{prevouts} } @{$slash->slashing->proofs} ], [ pack("Q<C", 600, 20), pack("Q<C", 700, 20) ],
        "unshared: each proof states the output only its stake spends");
    is($slash->validate, 0, "unshared: slashing tx validates, the stated outputs are counted by the script");
    my $received = deserialize($slash);
    ok($received, "unshared: wire round-trip");
    is($received->hash, $slash->hash, "unshared: ...with the same hash");
    is_deeply($received->slashing->proofs, $slash->slashing->proofs, "unshared: ...and the same evidence");

    my %invalid = (
        "too low value"              => sub { $_[0]->{prevouts}->[0]->[0] = 599 },
        "another form of scripthash" => sub { $_[0]->{prevouts}->[0]->[1] = 32 },
        "unknown form of scripthash" => sub { $_[0]->{prevouts}->[0]->[1] = 21 },
        "nothing stated"             => sub { $_[0]->{prevouts} = [] },
        "more than inputs stated"    => sub { push @{$_[0]->{prevouts}}, [ 600, 20 ] },
    );
    foreach my $name (sort keys %invalid) {
        my $tx = restate($slash, $invalid{$name});
        isnt($tx->validate, 0, "unshared, $name: rejected");
    }
    is(deserialize(restate($slash, $invalid{"nothing stated"})), undef, "unshared, nothing stated: not a transaction on the wire");
    is(deserialize(restate($slash, $invalid{"more than inputs stated"})), undef, "unshared, more than inputs stated: not a transaction on the wire");

    # The stated data is not checked against anything: these outputs are not the
    # verifier's to know, so the validity of a slashing transaction never depends on
    # which outputs a node happens to have
    my $other = restate($slash, sub { $_->{prevouts}->[0]->[0] += 1_000_000 foreach @_ });
    isnt($other->hash, $slash->hash, "unshared restated: another transaction");
    is($other->validate, 0, "unshared restated: still valid");
    is($other->out->[0]->value, 360, "unshared restated: refund by the real slashed output");
}

# --- the scripts of the inputs of one stake only are not run: they are not slashed
{
    my ($coin, $coin_a) = map { make_coin($p2pk, \&hash256, $_) } 1000, 2000;
    my $stake1 = signed_stake([ $coin, $coin_a ], $bsd[0]);
    my $stake2 = signed_stake([ $coin ], $bsd[1]);
    $stake1->in->[1]->{siglist} = [ "\x01\x01" . "\x00" x 70 ]; # not a signature
    isnt($stake1->check_input_script, 0, "unsigned other input: the stake is not valid for a block");
    my $slash = QBitcoin::Slashing->new_tx($stake1, $stake2);
    is($slash->validate, 0, "unsigned other input: but it proves the shared output double-signed");
}

done_testing();
