package QBitcoin::Script;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::Crypto qw(hash160 ripemd160 sha1 sha256 hash256);
use QBitcoin::Script::OpCodes qw(OPCODES :OPCODES);
use QBitcoin::Script::Const;
use QBitcoin::Script::State;
use QBitcoin::Script::Util qw(pack_int unpack_int);

use Role::Tiny::With;
with 'QBitcoin::Script::CheckSig';

use Exporter qw(import);
our @EXPORT_OK = qw(script_eval op_pushdata);

# bitcoin script
# https://en.bitcoin.it/wiki/Script
# https://wiki.bitcoinsv.io/index.php/Opcodes_used_in_Bitcoin_Script
# useful links:
# https://blockgeeks.com/guides/best-bitcoin-script-guide/
# https://komodoplatform.com/en/blog/bitcoin-script/
# https://hedgetrade.com/bitcoin-script-explained/
# https://bitcoin.stackexchange.com/questions/3374/how-to-redeem-a-basic-tx
# https://en.bitcoin.it/w/images/en/7/70/Bitcoin_OpCheckSig_InDetail.png
# https://developer.bitcoin.org/devguide/transactions.html
# https://academy.bit2me.com/en/what-is-bitcoin-script/# (?)

use constant LOCKTIME_THRESHOLD => 500000000;
use constant SEQUENCE_LOCKTIME_DISABLE_FLAG  => 1 << 31;
use constant SEQUENCE_LOCKTIME_TYPE_FLAG     => 1 << 22;
use constant QBT_SEQUENCE_LOCKTIME_TYPE_FLAG => 1 << 27;

use constant MAX_SCRIPT_EXEC_DEPTH => 16;

# Allow attributes "in1", "in2", etc
sub MODIFY_CODE_ATTRIBUTES {
    my ($class, $code, @attrs) = @_;
    return grep { !/^in[0-9]+$/ } @attrs;
}

my %INT_2_1 = (
    add         => sub { $a + $b },
    sub         => sub { $a - $b },
    min         => sub { $a < $b ? $a : $b },
    max         => sub { $a > $b ? $a : $b },
    numequal    => sub { $a == $b ? 1 : 0 },
    numnotequal => sub { $a == $b ? 0 : 1 },
    lessthan    => sub { $a < $b ? 1 : 0 },
    greaterthan => sub { $a > $b ? 1 : 0 },
    lessthanorequal    => sub { $a <= $b ? 1 : 0 },
    greaterthanorequal => sub { $a >= $b ? 1 : 0 },
);
my %INT_1_1 = (
    '1add' => sub { $a + 1 },
    '1sub' => sub { $a - 1 },
    negate => sub { -$a },
    abs    => sub { $a >= 0 ? $a : -$a },
);
my %PUSH_CONST = (
    false     => "",
    "1negate" => pack_int(-1),
    map { $_ => pack_int($_) } 1 .. 16,
);
my %COMMON_CMD = (
    drop    => sub :in1 { pop },
    dup     => sub :in1 { push @_, $_[-1] },
    equal   => sub :in2 { push @_, pop eq pop },
    '2drop' => sub :in2 { splice(@_,-2) },
    '2dup'  => sub :in2 { push @_, @_[-2,-1] },
    '3dup'  => sub :in3 { push @_, @_[-3,-2,-1] },
    '2over' => sub :in4 { push @_, @_[-4,-3] },
    '2rot'  => sub :in6 { push @_, splice(@_,-6,2) },
    '2swap' => sub :in4 { push @_, splice(@_,-4,2) },
    ifdup   => sub :in4 { push @_, $_[-1] if is_true($_[-1]) },
    depth   => sub :in4 { push @_, pack_int(scalar @_) },
    nip     => sub :in2 { splice(@_,-2,1) },
    over    => sub :in2 { push @_, $_[-2] },
    rot     => sub :in2 { push @_, splice(@_,-3,1) },
    swap    => sub :in2 { push @_, splice(@_,-2,1) },
    tuck    => sub :in2 { splice(@_,-2,0,$_[-1]) },
    size    => sub :in1 { push @_, pack_int(length($_[-1])) },
    not     => sub :in1 { push @_, is_true(pop) ? FALSE : TRUE },
    '0notequal' => sub :in1 { push @_, is_true(pop) ? TRUE : FALSE },
    booland => sub :in2 { push @_, is_true(pop) && is_true(pop) ? TRUE : FALSE },
    boolor  => sub :in2 { push @_, is_true(pop) || is_true(pop) ? TRUE : FALSE },

    hash160   => sub :in1 { push @_, hash160(pop) },
    ripemd160 => sub :in1 { push @_, ripemd160(pop) },
    sha1      => sub :in1 { push @_, sha1(pop) },
    sha256    => sub :in1 { push @_, sha256(pop) },
    hash256   => sub :in1 { push @_, hash256(pop) },
);

my @OP_CMD;

sub opcode_to_cmd($) {
    my ($opcode) = @_;
    $opcode =~ s/^OP_//;
    return lc($opcode);
}

foreach my $opcode (keys %{&OPCODES}) {
    my $cmd = opcode_to_cmd($opcode);
    if (my $cmd_func = __PACKAGE__->can("cmd_$cmd")) {
        $OP_CMD[OPCODES->{$opcode}] = $cmd_func;
    }
    elsif (my $common_func = $COMMON_CMD{$cmd}) {
        my $input = 0;
        foreach (attributes::get($common_func)) {
            $input = $1 if /^in([0-9]+)$/;
        }
        $OP_CMD[OPCODES->{$opcode}] = sub {
            my ($state) = @_;
            return unless $state->ifstate;
            @{$state->stack} >= $input or return 0;
            local *_ = \@{$state->stack}; # localized alias @_ as @{$state->stack} without copying arrays
            &$common_func; # inherits @_ and can modify it; it's not the same as $func->(@_)
            return undef;
        }
    }
    elsif ($INT_1_1{$cmd}) {
        $OP_CMD[OPCODES->{$opcode}] = sub {
            my ($state) = @_;
            return unless $state->ifstate;
            my $stack = $state->stack;
            @$stack >= 1 or return 0;
            local $a = unpack_int(pop @$stack) // return 0;
            push @$stack, pack_int($INT_1_1{$cmd}->());
            return undef;
        };
    }
    elsif ($INT_2_1{$cmd}) {
        $OP_CMD[OPCODES->{$opcode}] = sub {
            my ($state) = @_;
            return unless $state->ifstate;
            my $stack = $state->stack;
            @$stack >= 2 or return 0;
            local ($a, $b) = map { unpack_int($_) // return 0 } splice(@$stack, -2);
            push @$stack, pack_int($INT_2_1{$cmd}->());
            return undef;
        };
    }
    elsif (exists $PUSH_CONST{$cmd}) {
        $OP_CMD[OPCODES->{$opcode}] = sub {
            my ($state) = @_;
            return unless $state->ifstate;
            push @{$state->stack}, $PUSH_CONST{$cmd};
            return undef;
        };
    }
}

foreach my $opcode (keys %{&OPCODES}) {
    if (!__PACKAGE__->can(opcode_to_cmd($opcode))) {
        $OP_CMD[OPCODES->{$opcode}] //= sub { unimplemented(OPCODES->{$opcode}, @_) };
    }
}
foreach my $opcode (0x01 .. 0x4b) {
    $OP_CMD[$opcode] = sub { pushdatan($opcode, @_) };
}
foreach (1 .. 10) {
    my $opcode = OPCODES->{"OP_NOP$_"} or next;
    $OP_CMD[$opcode] = sub { undef };
}

sub unimplemented($$) {
    my ($opcode, $state) = @_;
    Infof("Unimplemented opcode 0x%02x", $opcode);
    return 0;
}

sub op_pushdata($) {
    my ($data) = @_;
    my $cmd;
    my $length = length($data);
    if ($length <= 0x4b) {
        $cmd = pack("C", $length);
    }
    elsif ($length <= 0xff) {
        $cmd = OP_PUSHDATA1 . pack("C", $length);
    }
    elsif ($length <= 0xffff) {
        $cmd = OP_PUSHDATA2 . pack("v", $length);
    }
    else {
        die "Too long data: $length bytes\n";
    }
    return $cmd . $data;
}

sub is_true($) {
    my ($data) = @_;
    return $data !~ /^\x80?\x00*\z/;
}

sub pushdatan($$) {
    my ($bytes, $state) = @_;
    my $data = $state->get_script($bytes) // return 0;
    return unless $state->ifstate;
    push @{$state->stack}, $data;
    return undef;
}

sub pushdatac($$$) {
    my ($c, $unpack, $state) = @_;
    my $bytes = unpack($unpack, $state->get_script($c) // return 0);
    my $data = $state->get_script($bytes) // return 0;
    return unless $state->ifstate;
    push @{$state->stack}, $data;
    return undef;
}

sub cmd_pushdata1 { pushdatac(1, "C", $_[0]) }
sub cmd_pushdata2 { pushdatac(2, "v", $_[0]) }
sub cmd_pushdata4 { pushdatac(4, "V", $_[0]) }

sub cmd_return($) {
    my ($state) = @_;
    return unless $state->ifstate;
    return 0;
}

sub cmd_if($) {
    my ($state) = @_;
    my $stack = $state->stack;
    @$stack or return 0;
    my $new_state = is_true(pop @$stack);
    push @{$state->ifstack}, $new_state;
    $state->ifstate &&= $new_state;
    return undef;
}

sub cmd_notif($) {
    my ($state) = @_;
    my $stack = $state->stack;
    @$stack or return 0;
    my $new_state = !is_true(pop @$stack);
    push @{$state->ifstack}, $new_state;
    $state->ifstate &&= $new_state;
    return undef;
}

sub cmd_else($) {
    my ($state) = @_;
    my $ifstack = $state->ifstack;
    @$ifstack or return 0;
    $ifstack->[-1] = !$ifstack->[-1];
    $state->set_ifstate();
    return undef;
}

sub cmd_endif($) {
    my ($state) = @_;
    my $ifstack = $state->ifstack;
    @$ifstack or return 0;
    pop @$ifstack;
    $state->set_ifstate();
    return undef;
}

sub cmd_nop($) { undef }
sub cmd_reserved($)  { shift->ifstate ? 0 : undef }
sub cmd_reserved1($) { shift->ifstate ? 0 : undef }
sub cmd_reserved2($) { shift->ifstate ? 0 : undef }
sub cmd_ver($)       { shift->ifstate ? 0 : undef }
sub cmd_invalidopcode($) { 0 }
sub cmd_pubkey($)        { 0 }
sub cmd_pubkeyhash($)    { 0 }
sub cmd_verif($)         { 0 }
sub cmd_vernotif($)      { 0 }

# in bitcoin script last processed codeseparator is stored and used during checksig
sub cmd_codeseparator($) { undef }

sub cmd_verify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    return @$stack && is_true(pop @$stack) ? undef : 0;
}

sub cmd_equalverify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $data1 = pop @$stack;
    my $data2 = pop @$stack;
    return $data1 eq $data2 ? undef : 0;
}

sub cmd_toaltstack($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack or return 0;
    push @{$state->altstack}, pop @$stack;
    return undef;
}

sub cmd_fromaltstack($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $altstack = $state->altstack;
    @$altstack or return 0;
    push @{$state->stack}, pop @$altstack;
    return undef;
}

sub cmd_pick($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    my $n = unpack_int(pop @$stack) // return 0;
    @$stack > $n or return 0;
    push @$stack, $stack->[-$n-1];
    return undef;
}

sub cmd_roll($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    my $n = unpack_int(pop @$stack) // return 0;
    @$stack > $n or return 0;
    push @$stack, splice(@$stack,-$n-1,1);
    return undef;
}

sub cmd_numequalverify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $n1 = unpack_int(pop @$stack) // return 0;
    my $n2 = unpack_int(pop @$stack) // return 0;
    return $n1 == $n2 ? undef : 0;
}

sub cmd_within($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 3 or return 0;
    my ($x, $min, $max) = map { unpack_int($_) // return 0 } splice(@$stack, -3);
    push @$stack, $x >= $min && $x < $max ? TRUE : FALSE;
    return undef;
}

# BIP-0065
sub cmd_checklocktimeverify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack or return 0;
    my $n = unpack_int($stack->[-1]) // return 0;
    $n >= 0 or return 0;
    if ($n < LOCKTIME_THRESHOLD) {
        if ($state->tx->can("nLockTime")) {
            # Bitcoin
            if ($state->tx->nLockTime >= LOCKTIME_THRESHOLD || $state->tx->nLockTime < $n) {
                return 0;
            }
        }
        else {
            # QBitcoin
            $state->tx->set_min_tx_block_height($n);
        }
    }
    else {
        if ($state->tx->can("nLockTime")) {
            if ($state->tx->nLockTime < $n) {
                return 0;
            }
        }
        else {
            # QBitcoin
            $state->tx->set_min_tx_time($n);
        }
    }
    # Also for Bitcoin we have to check that input nSequense is not SEQUENCE_FINAL (0xffffffff),
    # but it does not make sense for QBitcoin
    return undef;
}

# BIP-0112
sub cmd_checksequenceverify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack or return 0;
    my $val = unpack_int($stack->[-1]) // return 0;
    my $in = $state->tx->in->[$state->input_num];
    if ($state->tx->isa("Bitcoin::Transaction")) {
        # Bitcoin
        my $nSequence = $in->{txo}->nSequence;
        if ($nSequence & SEQUENCE_LOCKTIME_DISABLE_FLAG) {
            return 0;
        }
        my $n = $val & (SEQUENCE_LOCKTIME_TYPE_FLAG - 1);
        if ($val & SEQUENCE_LOCKTIME_TYPE_FLAG) {
            if (($nSequence & SEQUENCE_LOCKTIME_TYPE_FLAG) == 0 || $nSequence < $n) {
                return 0;
            }
        }
        else {
            if (($nSequence & SEQUENCE_LOCKTIME_TYPE_FLAG) != 0 || $nSequence < $n) {
                return 0;
            }
        }
    }
    else {
        # QBitcoin
        my $n = $val & (QBT_SEQUENCE_LOCKTIME_TYPE_FLAG - 1);
        if ($val & QBT_SEQUENCE_LOCKTIME_TYPE_FLAG) {
            $in->{min_rel_time} = $n*BLOCK_INTERVAL if ($in->{min_rel_time} // -1) < $n*BLOCK_INTERVAL;
        }
        else {
            $in->{min_rel_block_height} = $n if ($in->{min_rel_block_height} // -1) < $n;
        }
    }
    return undef;
}

sub cmd_exec {
    my ($state) = @_;
    return unless $state->ifstate;
    $state->execdepth <= MAX_SCRIPT_EXEC_DEPTH
        or return 0;
    my $stack = $state->stack;
    @$stack or return 0;
    my $script = pop @$stack;
    my $new_state = QBitcoin::Script::State->new($script, $stack, $state->tx, $state->input_num);
    $new_state->execdepth = $state->execdepth + 1;
    return execute($new_state);
}

# Params: <leaf_hash> <merkle_path> <merkle_root>
# Verify that the merkle path from leaf_hash leads to merkle_root
# Result: <leaf_hash> in stack if verified, else error
sub cmd_mastverify {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 3 or return 0;
    my ($hash, $merkle_path, $merkle_root) = splice(@$stack, -3);
    _check_merkle_path($hash, $merkle_path, $merkle_root)
        or return 0;
    return undef;
}

sub _merkle_hash {
    return hash256($_[0] . $_[1]);
}

sub _check_merkle_path {
    my ($hash, $merkle_path, $merkle_root) = @_;

    my $cur_hash = $hash;
    my $hashlen = length($cur_hash);
    my $pathlen = length($merkle_path);
    $hashlen == 32 or return 0;
    length($merkle_root) == $hashlen or return 0;
    $pathlen % $hashlen == 0 or return 0;
    my $ndx = 0;
    while ($ndx < $pathlen) {
        my $next_hash = substr($merkle_path, $ndx, $hashlen);
        $ndx += $hashlen;
        $cur_hash = _merkle_hash($next_hash lt $cur_hash ? ( $next_hash, $cur_hash ) : ( $cur_hash, $next_hash ));
    }
    return $cur_hash eq $merkle_root;
}

sub execute {
    my ($state) = @_;
    while (defined(my $cmd_code = $state->get_script(1))) {
        if (my $cmd_func = $OP_CMD[ord($cmd_code)]) {
            my $res = $cmd_func->($state);
            return $res if defined $res;
        }
        else {
            return 0; # Invalid opcode
        }
    }
    return undef;
}

sub script_eval($$$$) {
    my ($siglist, $redeem_script, $tx, $input_num) = @_;

    my @stack = $siglist ? @$siglist : (); # make a copy to prevent modifying original siglist
    my $state = QBitcoin::Script::State->new($redeem_script, \@stack, $tx, $input_num);
    my $res = execute($state);
    return $res if defined($res);

    return $state->ok;
}

1;
