package QBitcoin::Test::Tokens;
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
use QBitcoin::Test::MakeTx qw(%SCRIPT);
use QBitcoin::Test::Send qw($connection $last_tx);

use Exporter qw(import);
our @EXPORT = qw(make_tokens_tx send_tokens_tx);

sub make_tokens_tx {
    my ($prev_tx, $token_hash, $data, $inputs) = @_;
    state $value = 100;
    state $tx_num = 1;
    $prev_tx = [ $prev_tx ] if ref($prev_tx) ne 'ARRAY';
    my @in = $inputs ? @$inputs : map { $_->out->[0] } @$prev_tx;
    my $out_value = sum(map { $_->value } @in);
    my $script = op_pushdata(pack("v", $value)) . OP_DROP . OP_1;
    my $scripthash = hash160($script);
    $SCRIPT{$scripthash} = $script;
    $_->{redeem_script} = ($SCRIPT{$_->scripthash} // die "Unknown redeem script\n") foreach @in;
    my @out;
    foreach my $out_data (ref($data) ? @$data : $data) {
        push @out, QBitcoin::TXO->new_txo( value => $out_value, scripthash => $scripthash, num => $#out, data => $out_data // "" );
        $out_value = 0;
    }
    my $tx = QBitcoin::Transaction->new(
        out        => \@out,
        in         => [ map +{ txo => $_, siglist => [] }, @in ],
        fee        => 0,
        tx_type    => TX_TYPE_TOKENS,
        token_hash => $token_hash,
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

sub send_tokens_tx {
    my ($token_hash, $data, $inputs) = @_;
    my $tx = make_tokens_tx($last_tx, $token_hash, $data, $inputs);
    $connection->protocol->command("tx");
    $connection->protocol->cmd_tx($tx->serialize . "\x00"x16) == 0
        or return undef;
    $last_tx = $tx;
    return $tx;
}

1;
