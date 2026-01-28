package QBitcoin::Test::MakeTx;
use warnings;
use strict;
use feature 'state';

use List::Util qw(sum);
use QBitcoin::Const;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Crypto qw(hash160);

use Exporter qw(import);
our @EXPORT = qw(make_tx %SCRIPT);

our %SCRIPT;

sub make_tx {
    my ($prev_tx, $fee, $script) = @_;
    state $value = 100;
    state $tx_num = 1;
    $fee //= 0;
    $prev_tx = [ $prev_tx ] if $prev_tx && ref($prev_tx) ne 'ARRAY';
    my @in = $prev_tx ? map { $_->out->[0] } @$prev_tx : ();
    my $out_value = @in ? sum(map { $_->value } @in) : $value;
    $script //= op_pushdata(pack("v", $value)) . OP_DROP . OP_1;
    my $scripthash = hash160($script);
    $SCRIPT{$scripthash} = $script;
    $_->{redeem_script} = ($SCRIPT{$_->scripthash} // die "Unknown redeem script\n") foreach @in;
    my $out = QBitcoin::TXO->new_txo( value => $out_value - $fee, scripthash => $scripthash, num => 0, data => "" );
    my $tx = QBitcoin::Transaction->new(
        out     => [ $out ],
        in      => [ map +{ txo => $_, siglist => [] }, @in ],
        fee     => $fee,
        tx_type => $fee < 0 ? TX_TYPE_STAKE : @in ? TX_TYPE_STANDARD : TX_TYPE_COINBASE,
        @in ? () : ( coins_created => $out_value ),
    );
    $value += 100;
    $tx_num++;
    $tx->calculate_hash;
    my $num = 0;
    foreach my $out (@{$tx->out}) {
        $out->tx_in = $tx->hash;
        $out->num = $num++;
    }
    return $tx;
}

1;
