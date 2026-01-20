package QBitcoin::TXO;
use warnings;
use strict;

use Scalar::Util qw(weaken refaddr);
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(:types dbh find DEBUG_ORM for_log);
use QBitcoin::Const;
use QBitcoin::Crypto qw(hash160 hash256);
use QBitcoin::RedeemScript;
use QBitcoin::Address qw(address_by_hash);
use Bitcoin::Serialized;

use Role::Tiny::With;
with 'QBitcoin::TXO::My';

use constant PRIMARY_KEY => qw(tx_in num);

use constant FIELDS => {
    value      => NUMERIC,
    num        => NUMERIC,
    tx_in      => NUMERIC,
    tx_out     => NUMERIC,
    siglist    => BINARY,
    scripthash => NUMERIC,
    data       => BINARY,
};

use constant TABLE => "txo";
use constant TRANSACTION_TABLE => "transaction";

mk_accessors(keys %{&FIELDS});
mk_accessors(qw(token_hash));

# hash by tx and out-num
# tx_out and siglist are saved for the best chain for prevent double-spending
# but reference to the TXO object may be from multiple transactions
my %TXO;

sub key {
    my $self = shift;
    return $self->tx_in . pack("v", $self->num);
}

sub save {
    my $self = shift;
    if ($self->tx_in) {
        my $key = $self->key;
        if (defined $TXO{$key}) {
            Errf("Attempt to override already loaded txo %s:%u", $self->tx_in_str, $self->num);
            die "Attempt to override already loaded txo " . $self->tx_in_str . ":" . $self->num . "\n";
        }
        $TXO{$key} = $self;
        # Keep the txo in the %TXO hash until at least one reference (input or output) exists
        weaken($TXO{$key});
    }
    return $self;
}

sub save_all {
    my $class = shift;
    my ($tx_hash, $out) = @_;
    my $num = 0;
    foreach (@$out) {
        $_->tx_in = $tx_hash;
        $_->num   = $num++;
        $_->save;
    }
}

sub get {
    my $class = shift;
    my ($in) = @_;
    return $TXO{$in->{tx_out} . pack("v", $in->{num})};
}

# Create new transaction output, it cannot be already cached
sub new_txo {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : { @_ };
    $hash->{data} //= "";
    return bless $hash, $class;
}

# Create TXO by load from the database, use cached if any but do not store in cache if not
# b/c we want to ignore already loaded (and used in some transaction) txo in produce new transaction
sub new {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : { @_ };
    return $class->get({ tx_out => $hash->{tx_in}, num => $hash->{num} })
        // $class->new_txo($hash);
}

sub load_siglist {
    my ($stored) = @_;
    my $data = Bitcoin::Serialized->new($stored);
    my $num = $data->get_varint();
    my @siglist = map { $data->get_string() } 1 .. $num;
    return \@siglist;
}

# Create TXO, use cached if any and save in cache otherwise
sub new_saved {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : { @_ };
    if (my $self = $class->get({ tx_out => $hash->{tx_in}, num => $hash->{num} })) {
        return $self;
    }
    else {
        $hash->{siglist} = load_siglist($hash->{siglist}) if defined($hash->{siglist});
        my $self = $class->new_txo($hash);
        $self->save;
        return $self;
    }
}

# For new transaction load list of its input txo
sub load {
    my $class = shift;
    my (@in) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, tx_out.hash AS tx_out, siglist, s.hash as scripthash, s.script as redeem_script, data";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` AS s ON (t.scripthash = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " WHERE (tx_in.hash, num) IN (" . (dbh->get_info(17) eq "SQLite" ? "VALUES" : "") . join(",",("(UNHEX(?),?)")x@in) . ")";
    DEBUG_ORM && Debugf("sql: [%s] values [%s]", $sql, join(',', map { "X'" . unpack("H*", $_->{tx_out}) . "'", $_->{num} } @in));
    my $sth = dbh->prepare($sql);
    $sth->execute(map { unpack("H*", $_->{tx_out}), $_->{num} } @in);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        push @txo, $class->new_saved($hash);
    }
    DEBUG_ORM && Debugf("found %u entries", scalar(@txo));
    return @txo;
}

# For new tokens transaction load list of its input txo
sub load_tokens {
    my $class = shift;
    my (@in) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, tx_out.hash AS tx_out, IFNULL(tx_token.hash, tx_in.hash) as token_hash, siglist, s.hash as scripthash, s.script as redeem_script, data";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` AS s ON (t.scripthash = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_token ON (tx_token.id = tx_in.token_id)";
    $sql .= " WHERE (tx_in.hash, num) IN (" . (dbh->get_info(17) eq "SQLite" ? "VALUES" : "") . join(",",("(UNHEX(?),?)")x@in) . ")";
    DEBUG_ORM && Debugf("sql: [%s] values [%s]", $sql, join(',', map { "X'" . unpack("H*", $_->{tx_out}) . "'", $_->{num} } @in));
    my $sth = dbh->prepare($sql);
    $sth->execute(map { unpack("H*", $_->{tx_out}), $_->{num} } @in);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        push @txo, $class->new_saved($hash);
    }
    DEBUG_ORM && Debugf("found %u entries", scalar(@txo));
    return @txo;
}

sub is_cached {
    my $self = shift;
    if ($self->tx_in) {
        my $key = $self->key;
        if (defined($TXO{$key}) && refaddr($self) == refaddr($TXO{$key})) {
            return 1;
        }
    }
    return 0;
}

sub DESTROY {
    my $self = shift;
    # Compare pointers to avoid removing from the cache by destroy unlinked object
    if ($self->tx_in) {
        my $key = $self->key;
        if (!defined($TXO{$key}) || refaddr($self) == refaddr($TXO{$key})) {
            delete $TXO{$key};
        }
    }
}

sub store {
    my $self = shift;
    my ($tx) = @_;
    my $script = QBitcoin::RedeemScript->store($self->scripthash);
    my $sql = "REPLACE INTO `" . TABLE . "` (value, num, tx_in, scripthash, tx_out, siglist, data) VALUES (?,?,?,?,NULL,NULL,UNHEX(?))";
    DEBUG_ORM && Debugf("dbi [%s] values [%lu,%u,%u,%u,'%s']", $sql, $self->value, $self->num, $tx->id, $script->id, unpack("H*", $self->data));
    my $res = dbh->do($sql, undef, $self->value, $self->num, $tx->id, $script->id, unpack("H*", $self->data));
    $res == 1
        or die "Can't store txo " . $self->tx_in_str . ":" . $self->num . ": " . (dbh->errstr // "no error") . "\n";
}

sub store_siglist {
    my ($siglist) = @_;
    return varint(scalar @$siglist) . join("", map { varstr($_) } @$siglist);
}

sub store_spend {
    my $self = shift;
    # We're already inside SQL transaction created in QBitcoin::Block->store()
    my ($tx) = @_;
    my ($tx_in_id) = dbh->selectrow_array("SELECT id FROM `" . TRANSACTION_TABLE . "` WHERE hash = UNHEX(?)", undef, unpack("H*", $self->tx_in));
    my $sql = "UPDATE `" . QBitcoin::RedeemScript->TABLE . "` SET script = UNHEX(?) WHERE hash = UNHEX(?) AND script IS NULL";
    DEBUG_ORM && Debugf("dbi [%s] values [%s,%s]", $sql, unpack("H*", $self->redeem_script), unpack("H*", $self->scripthash));
    my $res = dbh->do($sql, undef, unpack("H*", $self->redeem_script), unpack("H*", $self->scripthash));
    $res
        or die "Can't store txo " . $self->tx_in_str . ":" . $self->num . " as spend: " . (dbh->errstr // "no error") . "\n";
    $sql = "UPDATE `" . TABLE . "` SET tx_out = ?, siglist = UNHEX(?) WHERE tx_in = ? AND num = ?";
    my $siglist = store_siglist($self->siglist);
    DEBUG_ORM && Debugf("dbi [%s] values [%u,'%s',%u,%u]", $sql, $tx->id, unpack("H*", $siglist), $tx_in_id, $self->num);
    $res = dbh->do($sql, undef, $tx->id, unpack("H*", $siglist), $tx_in_id, $self->num);
    $res == 1
        or die "Can't store txo " . $self->tx_in_str . ":" . $self->num . " as spend: " . (dbh->errstr // "no error") . "\n";
}

# Load all inputs for stored transaction after load from database
sub load_stored_inputs {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, siglist, s.hash as scripthash, s.script as redeem_script, data";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` AS s ON (t.scripthash = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " WHERE tx_out = ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $tx_id);
    $sth->execute($tx_id);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_out} = $tx_hash;
        my $txo = $class->new_saved($hash);
        $txo->tx_out && $txo->tx_out eq $tx_hash
            or die sprintf("Cached txo %s:%u has no tx_out %s\n", $txo->tx_in_str, $txo->num, unpack("H*", substr($tx_hash, 0, 4)));
        push @txo, $txo;
    }
    DEBUG_ORM && Debugf("found %u entries", scalar(@txo));
    return @txo;
}

sub load_stored_token_inputs {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, siglist, IFNULL(tx_token.hash, tx_in.hash) AS token_hash, s.hash as scripthash, s.script as redeem_script, data";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` AS s ON (t.scripthash = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_token ON (tx_token.id = tx_in.token_id)";
    $sql .= " WHERE tx_out = ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $tx_id);
    $sth->execute($tx_id);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_out} = $tx_hash;
        my $txo = $class->new_saved($hash);
        $txo->tx_out && $txo->tx_out eq $tx_hash
            or die sprintf("Cached txo %s:%u has no tx_out %s\n", $txo->tx_in_str, $txo->num, unpack("H*", substr($tx_hash, 0, 4)));
        push @txo, $txo;
    }
    DEBUG_ORM && Debugf("found %u entries", scalar(@txo));
    return @txo;
}

# Load all outputs for stored transaction after load from database
sub load_stored_outputs {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_out.hash AS tx_out, siglist, s.hash as scripthash, s.script as redeem_script, data";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` AS s ON (t.scripthash = s.id)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " WHERE tx_in = ? ORDER BY num";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $tx_id);
    $sth->execute($tx_id);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_in} = $tx_hash;
        my $txo = $class->new_saved($hash);
        push @txo, $txo;
    }
    DEBUG_ORM && Debugf("found %u entries", scalar(@txo));
    return @txo;
}

# Called from find() just before create new object
# Used for load my UTXO on startup and for "produce" random transaction, so optimization is not a point here
sub pre_load {
    my $class = shift;
    my ($attr) = @_;
    # load tx_in, tx_out as hashes; scripthash and redeem_script as data instead of id
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, s.hash as scripthash, s.script as redeem_script, data";
    $sql .= ", tx_out.hash AS tx_out" if $attr->{tx_out};
    $sql .= ", IFNULL(tx_token.hash, tx_in.hash) AS token_hash" if $attr->{tx_type} == TX_TYPE_TOKENS;
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` s ON (t.scripthash = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_out ON (tx_out.id = t.tx_out)" if $attr->{tx_out};
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_token ON (tx_token.id = tx_in.token_id)" if $attr->{tx_type} == TX_TYPE_TOKENS;
    $sql .= " WHERE tx_in.id = ? AND num = ?";
    DEBUG_ORM && Debugf("sql: [%s] values [%u,%u]", $sql, $attr->{tx_in}, $attr->{num});
    my $hash = dbh->selectrow_hashref($sql, undef, $attr->{tx_in}, $attr->{num});
    if ($hash) {
        $attr->{tx_in}         = $hash->{tx_in};
        $attr->{tx_out}        = $hash->{tx_out} if $attr->{tx_out};
        $attr->{token_hash}    = $hash->{token_hash} if $attr->{tx_type} == TX_TYPE_TOKENS;
        $attr->{scripthash}    = $hash->{scripthash};
        $attr->{redeem_script} = $hash->{redeem_script};
        $attr->{data}          = $hash->{data};
    }
    return $attr;
}

# $self->{spent} is not complete list of spent transactions for the txo; here are only in-memory transactions (mempool dependency)
sub spent_add {
    my $self = shift;
    my ($tx) = @_;
    my $key = $tx->is_pending ? "spent_pending" : "spent";
    $self->{$key} //= {}; # I am suspicious of autovivification
    $self->{$key}->{$tx->hash} = $tx;
}

sub spent_del {
    my $self = shift;
    my ($tx) = @_;
    delete $self->{$tx->is_pending ? "spent_pending" : "spent"}->{$tx->hash};
}

sub spent_list {
    my $self = shift;
    return $self->{spent} ? values %{$self->{spent}} : ();
}

sub spent_pending {
    my $self = shift;
    return $self->{spent_pending} ? values %{$self->{spent_pending}} : ();
}

sub spent_confirm {
    my $self = shift;
    my ($tx) = @_;
    $self->{spent}->{$tx->hash} = delete $self->{spent_pending}->{$tx->hash};
}

sub unspent {
    my $self = shift;
    return 0 if $self->{spent} && %{$self->{spent}};
    return 0 if $self->tx_out; # MB for transaction in a pending block
    return 1;
}

sub set_redeem_script {
    my $self = shift;
    my ($script) = @_;

    if ($self->redeem_script) {
        $script eq $self->redeem_script
            or return -1;
        return 0;
    }
    my $scripthash;
    my $hashlength = length($self->scripthash);
    if ($hashlength == 20) {
        $scripthash = hash160($script);
    }
    elsif ($hashlength == 32) {
        $scripthash = hash256($script);
    }
    else {
        return -1;
    }
    $scripthash eq $self->scripthash
        or return -1;
    $self->{redeem_script} = $script;
    return 0;
}

sub redeem_script {
    my $self = shift;
    die "Can't set redeem_script by accessor" if @_;
    return $self->{redeem_script};
}

sub check_script {
    my $self = shift;
    my ($siglist, $tx, $input_num) = @_;
    return QBitcoin::RedeemScript->check_input($siglist, $self->redeem_script, $tx, $input_num);
}

sub tx_in_str {
    my $self = shift;
    return unpack("H*", substr($self->tx_in, 0, 4));
}

sub tx_out_str {
    my $self = shift;
    return unpack("H*", substr($self->tx_out, 0, 4));
}

sub address {
    my $self = shift;
    return address_by_hash($self->scripthash);
}

sub is_token_transfer {
    my $self = shift;
    return length($self->data) == 9 && substr($self->data, 0, 1) eq TOKEN_TXO_TYPE_TRANSFER;
}

1;
