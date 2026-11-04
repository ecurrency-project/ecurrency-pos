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

# OP_EXEC: at most MAX_SCRIPT_EXEC_COUNT (16) executions per input, whatever the nesting
my $leaf = OP_1 . OP_DROP;
ok(script_eval([$leaf], ((OP_DUP . OP_EXEC) x 16) . OP_DROP . OP_1, "", 0), "leaf executed 16 times");
ok(!script_eval([$leaf], ((OP_DUP . OP_EXEC) x 17) . OP_DROP . OP_1, "", 0), "leaf executed 17 times");
# The leaf runs itself $m times with a counter decremented on each level: entry [leaf, n] -> exit [leaf, n]
my $counter_leaf = sub {
    my ($m) = @_;
    return OP_1SUB . OP_DUP . OP_IF . ((OP_OVER . OP_EXEC) x $m) . OP_ENDIF . OP_1ADD;
};
my $exec_redeem = OP_OVER . OP_EXEC . OP_2DROP . OP_1;
ok(script_eval([$counter_leaf->(1), pack_int(16)], $exec_redeem, "", 0), "exec chain of 16");
ok(!script_eval([$counter_leaf->(1), pack_int(17)], $exec_redeem, "", 0), "exec chain of 17");
# Without the count limit the fan-out would take $m**16 executions
$t = time;
ok(!script_eval([$counter_leaf->(2), pack_int(16)], $exec_redeem, "", 0), "exec fan-out exceeds the count");
ok(!script_eval([$counter_leaf->(8), pack_int(16)], $exec_redeem, "", 0), "wide exec fan-out exceeds the count");
cmp_ok(time - $t, '<', 1, "exec fan-out is cut quickly");
ok(script_eval([$counter_leaf->(2), pack_int(4)], $exec_redeem, "", 0), "small exec fan-out (15 executions)");

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

# Hashes of long elements are cached per input: a long element comes only from the input or is a copy,
# so hashing it once per few bytes of code is linear in time
my $big = "\xaa" x 60000;
my $big2 = ("\xaa" x 59999) . "\xab";
my $hash_loop = OP_DUP . OP_HASH256 . OP_DROP;
$t = time;
ok(script_eval([$big], ($hash_loop x 20000) . OP_HASH256 . op_pushdata(hash256($big)) . OP_EQUAL, "", 0), "20000 hashes of a 60KB element");
cmp_ok(time - $t, '<', 1, "repeated hashing of a long element is fast");
ok(script_eval([$big, $big2], OP_HASH256 . op_pushdata(hash256($big2)) . OP_EQUALVERIFY . OP_SHA256 . op_pushdata(sha256($big)) . OP_EQUAL, "", 0), "distinct elements of the same size hash separately");
# Many distinct elements of the same size with a common prefix: the worst case for the cache scan
my @same = map { ("\x55" x 520) . pack("C", $_) } 0 .. 125; # 126 elements of 521 bytes
my $pick_loop = join("", map { op_pushdata(pack_int($_)) . OP_PICK . OP_HASH256 . OP_DROP } 0 .. 125);
$t = time;
ok(script_eval([@same], ($pick_loop x 130) . (OP_2DROP x 63) . OP_1, "", 0), "16380 hashes of 126 same-size elements");
cmp_ok(time - $t, '<', 1, "scanning the cache among same-size elements is fast");
# OP_MASTVERIFY hashes the whole merkle path, cached the same way
my $leaf_hash = hash256("leaf");
my @path = map { hash256("node $_") } 1 .. 1000;
my $root = $leaf_hash;
$root = hash256($_ lt $root ? $_ . $root : $root . $_) foreach @path;
my $mast_loop = OP_3DUP . OP_MASTVERIFY;
$t = time;
ok(script_eval([$leaf_hash, join("", @path), $root], ($mast_loop x 2000) . OP_MASTVERIFY . OP_1, "", 0), "2000 mastverify with a 1000-level path");
cmp_ok(time - $t, '<', 1, "repeated mastverify of a long path is fast");
ok(!script_eval([$leaf_hash, join("", @path), hash256("wrong")], $mast_loop . OP_MASTVERIFY . OP_1, "", 0), "mastverify with a wrong root is cached as failed");

# Signatures
my @addr = map { QBitcoin::MyAddress->new(private_key => wallet_import_format(generate_keypair(CRYPT_ALGO_ECDSA)->pk_serialize)) } 1 .. 20;
my $sign_data = "\x55\xaa" x 700;
my $tx = TestTx->new(sign_data => $sign_data);
my @sig = map { signature($sign_data, $_, CRYPT_ALGO_ECDSA, SIGHASH_ALL) } @addr;
my @pubkey = map { op_pushdata($_->pubkey) } @addr;

# OP_CHECKMULTISIG costs nkeys sigops: a signature is tried against each key until it matches
my $multisig_1_of_2 = OP_1 . join("", @pubkey[0..1]) . OP_2 . OP_CHECKMULTISIG;
ok(script_eval([$sig[1]], $multisig_1_of_2, $tx, 0), "1-of-2 multisig with the last key");
ok(script_eval([$sig[0]], $multisig_1_of_2, $tx, 0), "1-of-2 multisig with the first key");
ok(!script_eval([$sig[3]], $multisig_1_of_2, $tx, 0), "1-of-2 multisig with a wrong key");
my $multisig_1_of_20 = OP_1 . join("", @pubkey) . op_pushdata(pack_int(20)) . OP_CHECKMULTISIG;
ok(!script_eval([$sig[0]], $multisig_1_of_20, $tx, 0), "1-of-20 multisig exceeds the sigops budget even with the first key");

# An empty signature costs no sigops and counts as a failed check (BIP-342), so k-of-n via OP_CHECKSIGADD works
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
