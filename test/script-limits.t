#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;
use Time::HiRes qw(time);

use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(script_eval op_pushdata);
use QBitcoin::Script::Util qw(pack_int);
use QBitcoin::Crypto qw(signature hash160 hash256 sha256 generate_keypair);
use QBitcoin::Address qw(wallet_import_format);
use QBitcoin::MyAddress;

$config->{debug} = 0;

# Execution time must be linear in the input size (redeem script + siglist)

# Nested OP_IF: the if-state is maintained in O(1), not by scanning the if-stack
my $depth = 20000;
my $t = time;
ok(script_eval([], ((OP_1 . OP_IF) x $depth) . (OP_ENDIF x $depth) . OP_1, "", 0), "nested if $depth deep");
cmp_ok(time - $t, '<', 1, "nested if is linear");
ok(script_eval([], OP_0 . (OP_IF x $depth) . OP_RETURN . (OP_ENDIF x $depth) . OP_1, "", 0), "nested false if skips OP_RETURN");
ok(!script_eval([], ((OP_1 . OP_IF) x $depth) . (OP_ENDIF x ($depth-1)) . OP_1, "", 0), "unbalanced nested if");

# OP_EXEC: each executed command pays one unit of the budget, the input size, so the executions
# of an element are bounded by the input whatever the nesting and no count limit is needed
my $leaf = OP_1 . OP_DROP;
# n rounds of OP_DUP OP_EXEC run 4n+2 commands while the budget is the 2n+2 bytes of the script
# plus twice the leaf and the padding element
my $rounds = 100;
my $exec_rounds = ((OP_DUP . OP_EXEC) x $rounds) . OP_2DROP . OP_1;
ok(script_eval(["\x00" x ($rounds - 2), $leaf], $exec_rounds, "", 0), "leaf executed $rounds times within the budget");
ok(!script_eval(["\x00" x ($rounds - 3), $leaf], $exec_rounds, "", 0), "leaf executed $rounds times one byte short");
# A self-replicating element recurses until the budget is exhausted
my $self_exec = OP_DUP . OP_EXEC;
$t = time;
ok(!script_eval(["\x00" x 16000, $self_exec], $self_exec, "", 0), "self-replicating exec is stopped by the budget");
cmp_ok(time - $t, '<', 1, "deep exec recursion is fast");
# The leaf runs itself $m times with a counter decremented on each level: entry [leaf, n] -> exit [leaf, n]
my $counter_leaf = sub {
    my ($m) = @_;
    return OP_1SUB . OP_DUP . OP_IF . ((OP_OVER . OP_EXEC) x $m) . OP_ENDIF . OP_1ADD;
};
my $exec_redeem = OP_OVER . OP_EXEC . OP_2DROP . OP_DROP . OP_1;
ok(script_eval(["\x00" x 1000, $counter_leaf->(1), pack_int(100)], $exec_redeem, "", 0), "exec chain of 100");
ok(!script_eval([$counter_leaf->(1), pack_int(100)], OP_OVER . OP_EXEC . OP_2DROP . OP_1, "", 0), "exec chain of 100 without the budget");
# The fan-out would take $m**16 executions, the budget cuts it
$t = time;
ok(!script_eval(["\x00" x 60000, $counter_leaf->(2), pack_int(16)], $exec_redeem, "", 0), "exec fan-out exceeds the budget");
cmp_ok(time - $t, '<', 1, "exec fan-out is cut quickly");
$t = time;
ok(!script_eval(["\x00" x 60000, $counter_leaf->(8), pack_int(16)], $exec_redeem, "", 0), "wide exec fan-out exceeds the budget");
cmp_ok(time - $t, '<', 1, "wide exec fan-out is cut quickly");
ok(script_eval(["\x00" x 1000, $counter_leaf->(2), pack_int(4)], $exec_redeem, "", 0), "small exec fan-out (15 executions)");

# Stack + altstack at most MAX_STACK_SIZE (1000) elements, as in bitcoin, so OP_ROLL costs a bounded time
my $fill = (OP_1 x 3) . (OP_3DUP x 332); # 999 elements, the pushed roll index makes 1000
my $roll = op_pushdata(pack_int(998)) . OP_ROLL;
my $cleanup = (OP_2DROP x 499) . OP_DROP;
ok(script_eval([], $fill . ($roll x 5000) . $cleanup . OP_1, "", 0), "1000 elements, 5000 deep rolls");
ok(!script_eval([], $fill . OP_1 . OP_1 . OP_2DROP . $cleanup . OP_1, "", 0), "1001 elements");
ok(!script_eval([], $fill . OP_TOALTSTACK . OP_1 . OP_1 . OP_2DROP . OP_FROMALTSTACK . $cleanup . OP_1, "", 0), "1001 elements over stack and altstack");
ok(script_eval([], $fill . OP_TOALTSTACK . OP_1 . OP_DROP . OP_FROMALTSTACK . $cleanup . OP_1, "", 0), "1000 elements over stack and altstack");
ok(!script_eval([("") x 1001], (OP_2DROP x 500) . OP_DROP . OP_1, "", 0), "1001 siglist elements");
ok(script_eval([("") x 1000], (OP_2DROP x 500) . OP_1, "", 0), "1000 siglist elements");
$t = time;
script_eval([], $fill . ($roll x 10000) . $cleanup . OP_1, "", 0);
cmp_ok(time - $t, '<', 1, "10000 deep rolls are fast");

# A hash pays the bytes it hashes. The siglist counts twice in the budget, so an element of it can be
# hashed twice whatever its size, and the third hash exceeds the budget
my $big = "\xaa" x 60000;
my $hash_loop = OP_DUP . OP_HASH256 . OP_DROP;
ok(script_eval([$big], ($hash_loop x 2) . OP_DROP . OP_1, "", 0), "a 60KB element hashed twice, exact budget");
ok(!script_eval([$big], ($hash_loop x 3) . OP_DROP . OP_1, "", 0), "a 60KB element hashed three times");
# Hashes of hashes are new 32-byte elements and pay 32 each: 100 of them need 3200 of budget beyond
# the 102 commands, 64 of which come from the hashed element and the rest from the padding
ok(script_eval(["\x00" x 1568, "\x55" x 32], (OP_HASH256 x 100) . OP_2DROP . OP_1, "", 0), "100 hashes of hashes, exact budget");
ok(!script_eval(["\x00" x 1567, "\x55" x 32], (OP_HASH256 x 100) . OP_2DROP . OP_1, "", 0), "100 hashes of hashes one byte short");
# Many distinct elements: each pays its own hashing, twice at most
my @same = map { ("\x55" x 520) . pack("C", $_) } 0 .. 125; # 126 elements of 521 bytes
my $pick_loop = join("", map { op_pushdata(pack_int($_)) . OP_PICK . OP_HASH256 . OP_DROP } 0 .. 125);
ok(script_eval([@same], ($pick_loop x 2) . (OP_2DROP x 63) . OP_1, "", 0), "126 elements hashed twice each");
ok(!script_eval([@same], ($pick_loop x 3) . (OP_2DROP x 63) . OP_1, "", 0), "126 elements hashed three times each");
# OP_MASTVERIFY hashes 64 bytes per node of the path and pays them: the path is verified once
my $leaf_hash = hash256("leaf");
my @path = map { hash256("node $_") } 1 .. 1000;
my $root = $leaf_hash;
$root = hash256($_ lt $root ? $_ . $root : $root . $_) foreach @path;
ok(script_eval([$leaf_hash, join("", @path), $root], OP_MASTVERIFY . OP_1, "", 0), "mastverify with a 1000-level path");
ok(!script_eval([$leaf_hash, join("", @path), $root], OP_3DUP . OP_MASTVERIFY . OP_MASTVERIFY . OP_1, "", 0), "mastverify of the path twice exceeds the budget");
ok(!script_eval([$leaf_hash, join("", @path), hash256("wrong")], OP_MASTVERIFY . OP_1, "", 0), "mastverify with a wrong root");

# Signatures
my @addr = map { QBitcoin::MyAddress->new(private_key => wallet_import_format(generate_keypair(CRYPT_ALGO_ECDSA)->pk_serialize)) } 1 .. 20;
my $sign_data = "\x55\xaa" x 700;
my $tx = TestTx->new(sign_data => $sign_data);
my @sig = map { signature($sign_data, $_, CRYPT_ALGO_ECDSA, SIGHASH_ALL) } @addr;
my @pubkey = map { op_pushdata($_->pubkey) } @addr;

# A check pays the key once and the signature twice while the siglist counts twice in the budget,
# so any k-of-n with explicit keys and signatures is spendable whatever the number of keys
my $multisig_1_of_2 = OP_1 . join("", @pubkey[0..1]) . OP_2 . OP_CHECKMULTISIG;
ok(script_eval([$sig[1]], $multisig_1_of_2, $tx, 0), "1-of-2 multisig with the last key");
ok(script_eval([$sig[0]], $multisig_1_of_2, $tx, 0), "1-of-2 multisig with the first key");
ok(!script_eval([$sig[3]], $multisig_1_of_2, $tx, 0), "1-of-2 multisig with a wrong key");
my $multisig_1_of_20 = OP_1 . join("", @pubkey) . op_pushdata(pack_int(20)) . OP_CHECKMULTISIG;
ok(script_eval([$sig[19]], $multisig_1_of_20, $tx, 0), "1-of-20 multisig with the last key");
ok(script_eval([$sig[0]], $multisig_1_of_20, $tx, 0), "1-of-20 multisig with the first key");
ok(!script_eval([$sig[0], $sig[19]], $multisig_1_of_20, $tx, 0), "1-of-20 multisig with two signatures");
my $multisig_19_of_20 = op_pushdata(pack_int(19)) . join("", @pubkey) . op_pushdata(pack_int(20)) . OP_CHECKMULTISIG;
ok(script_eval([@sig[1..19]], $multisig_19_of_20, $tx, 0), "19-of-20 multisig");
ok(!script_eval([@sig[0..17], $sig[0]], $multisig_19_of_20, $tx, 0), "19-of-20 multisig with a repeated signature");
# The budget is exact: the key in the siglist and the bare OP_CHECKSIG as the script
ok(script_eval([$sig[0], $addr[0]->pubkey], OP_CHECKSIG, $tx, 0), "checksig with the key in the siglist");
# Operands made cheaply (OP_2DUP, OP_3DUP, OP_HASH256) pay their full size, and a signature is paid
# twice, so the same check cannot be repeated
ok(!script_eval([$sig[0], $addr[0]->pubkey], OP_2DUP . OP_CHECKSIG . OP_DROP . OP_CHECKSIG, $tx, 0), "the same check twice exceeds the budget");
ok(!script_eval([$sig[0]], OP_1 . join("", @pubkey[0..2]) . OP_3DUP . OP_3DUP . OP_9 . OP_CHECKMULTISIG, $tx, 0), "multisig keys made by OP_3DUP are paid in full");
# The cheapest signature which is fully verified is a DER with one-byte r and s
my $short_sig = pack("CC", SIGHASH_ALL, CRYPT_ALGO_ECDSA) . pack("H*", "3006020101020101");
ok(!script_eval([$short_sig], $pubkey[0] . OP_CHECKSIG, $tx, 0), "a 10-byte signature is checked and fails");
# The executed element pays nothing by itself: a key inside it is paid by the check, once per check,
# and the doubled siglist lets the element be executed twice with two signatures
my $leaf_checksig = $pubkey[0] . OP_CHECKSIG;
ok(script_eval([$sig[0], $leaf_checksig], OP_EXEC, $tx, 0), "checksig inside an executed element");
ok(script_eval([$sig[0], $leaf_checksig, $sig[0], $leaf_checksig], OP_EXEC . OP_VERIFY . OP_EXEC, $tx, 0), "two explicit copies of the element");
ok(script_eval([$sig[0], $sig[0], $leaf_checksig], OP_DUP . OP_TOALTSTACK . OP_EXEC . OP_VERIFY . OP_FROMALTSTACK . OP_EXEC, $tx, 0), "the element duplicated and executed twice, exact budget");
# A key is hashed and then checked: these two uses of its bytes are what the doubled siglist pays for
my $p2pkh = OP_DUP . OP_HASH256 . op_pushdata(hash256($addr[0]->pubkey)) . OP_EQUALVERIFY . OP_CHECKSIG;
ok(script_eval([$sig[0], $addr[0]->pubkey], $p2pkh, $tx, 0), "key hashed and checked");
ok(!script_eval([$sig[0], $addr[0]->pubkey], OP_DUP . OP_HASH256 . OP_DROP . $p2pkh, $tx, 0), "key hashed twice and checked exceeds the budget");
# One key may check two signatures, not three
my $two_sigs = OP_DUP . OP_TOALTSTACK . OP_CHECKSIGVERIFY . OP_FROMALTSTACK . OP_CHECKSIG;
ok(script_eval([$sig[0], $sig[0], $addr[0]->pubkey], $two_sigs, $tx, 0), "two signatures with one key, exact budget");
ok(!script_eval([$sig[0], $sig[0], $sig[0], $addr[0]->pubkey], OP_DUP . OP_TOALTSTACK . OP_CHECKSIGVERIFY . OP_FROMALTSTACK . $two_sigs, $tx, 0), "three signatures with one key exceed the budget");

# An empty signature costs nothing and counts as a failed check (BIP-342), so k-of-n via OP_CHECKSIGADD works
my $checksigadd_1_of_3 = $pubkey[0] . OP_CHECKSIG . $pubkey[1] . OP_CHECKSIGADD . $pubkey[2] . OP_CHECKSIGADD . OP_1 . OP_NUMEQUAL;
ok(script_eval([$sig[2], "", ""], $checksigadd_1_of_3, $tx, 0), "1-of-3 checksigadd with the last key");
ok(script_eval(["", "", $sig[0]], $checksigadd_1_of_3, $tx, 0), "1-of-3 checksigadd with the first key");
ok(!script_eval(["", "", ""], $checksigadd_1_of_3, $tx, 0), "1-of-3 checksigadd without signatures");
ok(!script_eval([$sig[2], "", $sig[0]], $checksigadd_1_of_3, $tx, 0), "1-of-3 checksigadd with two signatures");
ok(!script_eval(["", "", $sig[3]], $checksigadd_1_of_3, $tx, 0), "1-of-3 checksigadd with a wrong key");
ok(script_eval([$sig[0]], $pubkey[0] . OP_CHECKSIGVERIFY . OP_1, $tx, 0), "checksigverify");
ok(!script_eval([""], $pubkey[0] . OP_CHECKSIGVERIFY . OP_1, $tx, 0), "checksigverify fails with an empty signature");
ok(!script_eval([$sig[0], "\x01" x 9], op_pushdata("") . OP_SWAP . $pubkey[0] . OP_CHECKSIGADD, $tx, 0), "checksigadd rejects an invalid accumulator");

done_testing();

package TestTx;
use warnings;
use strict;

use QBitcoin::Accessors qw(new);
use QBitcoin::Crypto qw(hash256);
sub sign_data { $_[0]->{sign_data} }
sub sign_hash { $_[0]->{sign_hash} //= hash256($_[0]->{sign_data}) }

1;
