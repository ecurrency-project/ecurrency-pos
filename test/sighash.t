#! /usr/bin/env perl
use warnings;
use strict;

# The hash signed by a transaction input (Transaction::sign_hash): which changes of the transaction each
# sighash type covers, that one hash is never for two different things signed, and how much data is hashed,
# serialized and kept for the signatures of a transaction with many inputs. The amounts are counted instead
# of measuring the time: they must be linear in the size of the transaction. The format of the signed data
# is not checked here, it is not the same in all the coins.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use Scalar::Util qw(reftype refaddr);
use Digest::SHA;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(hash256 signature_hash generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::TXO;
use QBitcoin::Transaction;

$config->{regtest} = 1;

my %SIGHASH = (
    "ALL"                 => SIGHASH_ALL,
    "NONE"                => SIGHASH_NONE,
    "SINGLE"              => SIGHASH_SINGLE,
    "ALL|ANYONECANPAY"    => SIGHASH_ALL | SIGHASH_ANYONECANPAY,
    "NONE|ANYONECANPAY"   => SIGHASH_NONE | SIGHASH_ANYONECANPAY,
    "SINGLE|ANYONECANPAY" => SIGHASH_SINGLE | SIGHASH_ANYONECANPAY,
);
my @SIGHASH = sort { $SIGHASH{$a} <=> $SIGHASH{$b} } keys %SIGHASH;

my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my ($address) = addresses_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
my $myaddr = QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $address,
    staked      => 1,
});
my $p2pk = op_pushdata($myaddr->pubkey) . OP_CHECKSIG;

# The inputs of a transaction are sorted by tx_in, so the coins are in the order of their numbers
sub coin {
    my ($n) = @_;
    my $coin = QBitcoin::TXO->new_txo({ tx_in => sprintf("%032u", $n), num => 0, value => 1000, scripthash => hash256($p2pk) });
    $coin->set_redeem_script($p2pk) == 0 or die "set_redeem_script\n";
    return $coin;
}

sub out {
    my ($n) = @_;
    return QBitcoin::TXO->new_txo({ value => 100 + $n, scripthash => hash256("address $n") });
}

# Transaction of the given coins and outputs as a node gets it: nothing is cached in it
sub tx {
    my ($in, $out, %attr) = @_;
    return QBitcoin::Transaction->new(
        in      => [ map +{ txo => coin($_), siglist => [] }, @$in ],
        out     => [ map { out($_) } @$out ],
        fee     => 0,
        tx_type => TX_TYPE_STANDARD,
        hash    => hash256("transaction"),
        %attr,
    );
}

sub sign {
    my ($tx, $num, $sighash_type) = @_;
    return signature_hash($tx->sign_hash($num, $sighash_type), $myaddr, CRYPT_ALGO_ECDSA, $sighash_type);
}

# What a sighash type signs: the hash of input 1 of the transaction with the inputs 10, 20, 30 and the outputs
# 0, 1, 2 is the same in a changed transaction if and only if the signature is valid for it too
my @in = (10, 20, 30);
my @out = (0, 1, 2);
my %changed = (
    "its input replaced"      => [ [ 10, 25, 30 ], \@out ],
    "another input replaced"  => [ [ 10, 20, 35 ], \@out ],
    "an input added"          => [ [ 10, 20, 30, 40 ], \@out ],
    "its output replaced"     => [ \@in, [ 0, 8, 2 ] ],
    "another output replaced" => [ \@in, [ 0, 1, 9 ] ],
    "an output added"         => [ \@in, [ 0, 1, 2, 3 ] ],
);
my @other_inputs  = ("another input replaced", "an input added");
my @other_outputs = ("another output replaced", "an output added");
my %valid_with = (
    "ALL"                 => [],
    "NONE"                => [ @other_outputs, "its output replaced" ],
    "SINGLE"              => [ @other_outputs ],
    "ALL|ANYONECANPAY"    => [ @other_inputs ],
    "NONE|ANYONECANPAY"   => [ @other_inputs, @other_outputs, "its output replaced" ],
    "SINGLE|ANYONECANPAY" => [ @other_inputs, @other_outputs ],
);
foreach my $type (@SIGHASH) {
    my $hash = tx(\@in, \@out)->sign_hash(1, $SIGHASH{$type});
    is(length($hash), 32, "$type: sign hash");
    my %valid = map { $_ => 1 } @{$valid_with{$type}};
    foreach my $change (sort keys %changed) {
        my $changed_hash = tx(@{$changed{$change}})->sign_hash(1, $SIGHASH{$type});
        if ($valid{$change}) {
            ok($changed_hash eq $hash, "$type: signature is valid with $change");
        }
        else {
            ok($changed_hash ne $hash, "$type: signature is not valid with $change");
        }
    }
    # The block signed by a stake and the token are signed with any sighash type
    my ($stake1, $stake2) = map { tx(\@in, \@out, tx_type => TX_TYPE_STAKE, block_sign_data => $_ x 68) } "a", "b";
    ok($stake1->sign_hash(1, $SIGHASH{$type}) ne $stake2->sign_hash(1, $SIGHASH{$type}), "$type: signs the block of a stake");
    my ($token1, $token2) = map { tx(\@in, \@out, tx_type => TX_TYPE_TOKENS, token_hash => $_ x 32) } "a", "b";
    ok($token1->sign_hash(1, $SIGHASH{$type}) ne $token2->sign_hash(1, $SIGHASH{$type}), "$type: signs the token hash");
}
{
    # The hash without SIGHASH_ANYONECANPAY and SIGHASH_SINGLE is one for all the inputs, it is cached this way.
    # The other ones are for their input only, even if all the inputs have the same output
    my $tx = tx(\@in, [ 5, 5, 5 ]);
    foreach my $type (@SIGHASH) {
        my $per_input = $type ne "ALL" && $type ne "NONE";
        is($tx->sign_hash(0, $SIGHASH{$type}) ne $tx->sign_hash(2, $SIGHASH{$type}), $per_input,
            "$type: sign hash is " . ($per_input ? "its own for each input" : "the same for all the inputs"));
    }
    # An input without the output of its number signs no outputs with SIGHASH_SINGLE
    my $short = tx(\@in, [ 0 ]);
    ok($short->sign_hash(2, SIGHASH_SINGLE) eq $short->sign_hash(2, SIGHASH_NONE), "SINGLE without its output signs as NONE");
    ok($short->sign_hash(2, SIGHASH_SINGLE | SIGHASH_ANYONECANPAY) eq $short->sign_hash(2, SIGHASH_NONE | SIGHASH_ANYONECANPAY),
        "SINGLE|ANYONECANPAY without its output signs as NONE|ANYONECANPAY");
    ok($short->sign_hash(0, SIGHASH_SINGLE) ne $short->sign_hash(0, SIGHASH_NONE), "SINGLE with its output does not sign as NONE");
}

# The sighash type is not a part of the signed data, so the data itself must tell what is signed: two signatures
# of any sighash types in any transactions have the same hash if and only if they sign the same inputs and outputs.
# The own output of SIGHASH_SINGLE is signed as the output of its input and not just as an output.
# The transactions are random ones of a few coins and outputs, so many of them have the same inputs or outputs
{
    srand(1);
    my %kind = (
        "standard"       => [],
        "stake, block a" => [ tx_type => TX_TYPE_STAKE, block_sign_data => "a" x 68 ],
        "stake, block b" => [ tx_type => TX_TYPE_STAKE, block_sign_data => "b" x 68 ],
        "token a"        => [ tx_type => TX_TYPE_TOKENS, token_hash => "a" x 32 ],
        "token b"        => [ tx_type => TX_TYPE_TOKENS, token_hash => "b" x 32 ],
        "new token"      => [ tx_type => TX_TYPE_TOKENS ],
    );
    my @kind = sort keys %kind;
    my (%signed_by, %hash_of, %wrong);
    my $signatures = 0;
    foreach (1 .. 500) {
        my @in = grep { rand() < 0.5 } 1 .. 4;
        @in = (1 + int(rand(4))) if !@in;
        my @out = map { 1 + int(rand(3)) } 0 .. int(rand(4));
        my $kind = $kind[rand(@kind)];
        my $tx = tx(\@in, \@out, @{$kind{$kind}});
        foreach my $num (0 .. $#in) {
            foreach my $sighash_type (values %SIGHASH) {
                my $outputs_type = $sighash_type & ~SIGHASH_ANYONECANPAY;
                my $signed = join(", ", $kind,
                    $sighash_type & SIGHASH_ANYONECANPAY ? "input $in[$num]" : "inputs @in",
                    $outputs_type == SIGHASH_ALL ? "outputs @out"
                        : $outputs_type == SIGHASH_SINGLE && defined($out[$num]) ? "output $out[$num] of input $in[$num]" : "no outputs");
                my $hash = $tx->sign_hash($num, $sighash_type);
                $wrong{"one hash for different things signed"}++ if ($signed_by{$hash} //= $signed) ne $signed;
                $wrong{"different hashes for the same signed"}++ if ($hash_of{$signed} //= $hash) ne $hash;
                $signatures++;
            }
        }
    }
    is_deeply(\%wrong, {}, "$signatures signatures of random transactions: " . keys(%hash_of) . " different things signed, each has its own hash");
}

# The signatures of each sighash type are checked by the script of the input. Both inputs are of the same key
# and have the same output, so only what is signed tells a signature of one input from a signature of another one
foreach my $type (@SIGHASH) {
    my $signed = tx([ 0, 1 ], [ 5, 5 ]);
    my @sig = map { sign($signed, $_, $SIGHASH{$type}) } 0, 1;
    my $tx = tx([ 0, 1 ], [ 5, 5 ]);
    is($tx->in->[$_]->{txo}->check_script([ $sig[$_] ], $tx, $_), 0, "$type: signature of input $_") foreach 0, 1;
    isnt($tx->in->[1]->{txo}->check_script([ $sig[0] ], $tx, 1), 0, "$type: signature of another input")
        if $type ne "ALL" && $type ne "NONE";
    my $other = tx([ 0, 1 ], [ 5, 9 ]);
    is($other->in->[0]->{txo}->check_script([ $sig[0] ], $other, 0) == 0, $type !~ /ALL/, "$type: signature of input 0 with output 1 replaced");
}
{
    my $tx = tx([ 0, 1 ], [ 0, 1 ]);
    my $sig = sign($tx, 0, SIGHASH_ALL);
    substr($sig, 0, 1) = pack("C", SIGHASH_NONE);
    isnt($tx->in->[0]->{txo}->check_script([ $sig ], $tx, 0), 0, "the sighash type of a signature cannot be changed");
    foreach my $type (0, 4, SIGHASH_ANYONECANPAY, SIGHASH_ANYONECANPAY | 4) {
        is($tx->sign_hash(0, $type), undef, "no sign hash for unsupported sighash type $type");
        substr($sig, 0, 1) = pack("C", $type);
        isnt($tx->in->[0]->{txo}->check_script([ $sig ], $tx, 0), 0, "signature with unsupported sighash type $type");
    }
}

# A stake signs its block: the cached hashes are reset when it is validated for another block,
# whatever is kept from the previous check
{
    my @block = map { TestBlock->new(sign_data => $_ x 68, time => GENESIS_TIME + 1000, height => 1) } "a", "b";
    my $signed = tx(\@in, \@out, tx_type => TX_TYPE_STAKE, block_sign_data => $block[0]->sign_data);
    my @type = (SIGHASH_ALL, SIGHASH_SINGLE, SIGHASH_ALL | SIGHASH_ANYONECANPAY);
    my $stake = tx(\@in, \@out, tx_type => TX_TYPE_STAKE);
    $stake->in->[$_]->{siglist} = [ sign($signed, $_, $type[$_]) ] foreach 0 .. 2;
    is($stake->valid_for_block($block[0]),  0, "stake is valid for the block it signs");
    is($stake->valid_for_block($block[1]), -1, "stake is not valid for another block");
    is($stake->valid_for_block($block[0]),  0, "stake is valid for its block again");
}

# The amount of data hashed, serialized and kept for the sign hashes of all the inputs of a transaction
my ($hashed, $serialized) = (0, 0);
my $sha_module = Test::MockModule->new('Digest::SHA');
$sha_module->mock(add => sub { $hashed += sum0(map { length } @_[1 .. $#_]); $sha_module->original('add')->(@_) });
my @sha256_module = map { Test::MockModule->new($_) } 'QBitcoin::Crypto', 'QBitcoin::Transaction';
$_->mock(sha256 => sub { $hashed += length($_[0]); Digest::SHA::sha256($_[0]) }) foreach @sha256_module;
my $tx_module = Test::MockModule->new('QBitcoin::Transaction');
foreach my $func (qw(serialize_input_for_sign serialize_output)) {
    my $orig = QBitcoin::Transaction->can($func);
    $tx_module->mock($func => sub { $serialized++; $orig->(@_) });
}

# Total length of the strings kept by an object
sub kept {
    my ($value, $seen) = @_;
    return length($value // "") unless ref($value);
    return 0 if $seen->{refaddr($value)}++;
    my $type = reftype($value);
    return sum0(map { kept($_, $seen) } @$value) if $type eq 'ARRAY';
    return sum0(map { kept($_, $seen) } values %$value) if $type eq 'HASH';
    return kept($$value, $seen) if $type eq 'SCALAR' || $type eq 'REF';
    return 0;
}

my $n = 200; # inputs and outputs, so anything done for each input with all of them is $n times over the limit
my $inputs_size  = sum0(map { length(QBitcoin::Transaction::serialize_input_for_sign({ txo => coin($_) })) } 1 .. $n);
my $outputs_size = sum0(map { length(QBitcoin::Transaction::serialize_output(out($_))) } 1 .. $n);
# The signed data of the transaction is hashed once, the own data of an input (the transaction type,
# the second hash round, the cached hash) is within $own bytes
my $own = 100;
my $linear = $inputs_size + $outputs_size + $own * $n;
foreach my $type (@SIGHASH) {
    my $tx = tx([ 1 .. $n ], [ 1 .. $n ]);
    my $kept = kept($tx, {});
    ($hashed, $serialized) = (0, 0);
    my @hash = map { $tx->sign_hash($_, $SIGHASH{$type}) } 0 .. $n - 1;
    cmp_ok($hashed, '<=', $linear, "$type: the transaction is hashed once for all the inputs");
    cmp_ok($serialized, '<=', 2 * $n + $n, "$type: inputs and outputs are serialized once");
    cmp_ok(kept($tx, {}) - $kept, '<=', $linear, "$type: the signed data is not kept for each input");
    # Many checks of an input (multisig) do not repeat the hash
    ($hashed, $serialized) = (0, 0);
    my @again = map { $tx->sign_hash($_, $SIGHASH{$type}) } 0 .. $n - 1;
    is_deeply(\@again, \@hash, "$type: the same hashes on the second check");
    is($hashed + $serialized, 0, "$type: nothing is hashed on the second check");
}
{
    # All the sighash types in one transaction share the hashed inputs. The outputs are hashed twice:
    # after all the inputs (SIGHASH_ALL) and without them (SIGHASH_ALL | SIGHASH_ANYONECANPAY)
    my $tx = tx([ 1 .. $n ], [ 1 .. $n ]);
    my %hash = map { $_ => tx([ 1 .. $n ], [ 1 .. $n ])->sign_hash(7, $SIGHASH{$_}) } @SIGHASH;
    ($hashed, $serialized) = (0, 0);
    foreach my $type (reverse @SIGHASH) {
        ok($tx->sign_hash(7, $SIGHASH{$type}) eq $hash{$type}, "$type: the same hash after the other sighash types");
    }
    cmp_ok($hashed, '<=', $inputs_size + 2 * $outputs_size + 2 * $own * @SIGHASH, "all the sighash types hash the inputs once and the outputs twice");
    cmp_ok($serialized, '<=', 3 * $n + 2 * @SIGHASH, "all the sighash types serialize the inputs once and the outputs twice");
    # A signature with unsupported sighash type fails without any work with the whole transaction
    my $checks = 10 * $n;
    ($hashed, $serialized) = (0, 0);
    foreach my $type (0, 4, SIGHASH_ANYONECANPAY, SIGHASH_ANYONECANPAY | 4) {
        $tx->sign_hash($_ % $n, $type) foreach 1 .. $checks;
    }
    cmp_ok($hashed, '<=', $own * 4 * $checks, "unsupported sighash type: the transaction is not hashed for each check");
    cmp_ok($serialized, '<=', 4 * $checks, "unsupported sighash type: the inputs are not serialized for each check");
}

# Signing: the hash signed by all the inputs is calculated once, so twice as many inputs hash twice as much
sub hashed_by_signing {
    my ($inputs) = @_;
    my $stake = QBitcoin::Transaction->new(
        in      => [ map +{ txo => QBitcoin::TXO->new_txo({ tx_in => hash256("stake coin $_"), num => 0, value => 1000, scripthash => scalar $myaddr->scripthash }) }, 1 .. $inputs ],
        out     => [ QBitcoin::TXO->new_txo({ value => 1000 * $inputs, scripthash => scalar $myaddr->scripthash }) ],
        fee     => 0,
        tx_type => TX_TYPE_STAKE,
        block_sign_data => "a" x 68,
    );
    $hashed = 0;
    $stake->sign_transaction;
    my $hashed_by_signing = $hashed;
    is($stake->check_input_script, 0, "stake of $inputs inputs is signed");
    return $hashed_by_signing;
}
cmp_ok(hashed_by_signing(2 * $n), '<', 3 * hashed_by_signing($n), "signing hashes the transaction once for all the inputs");

done_testing();

package TestBlock;
use warnings;
use strict;

use QBitcoin::Accessors qw(new);
sub sign_data { $_[0]->{sign_data} }
sub time      { $_[0]->{time} }
sub height    { $_[0]->{height} }

1;
