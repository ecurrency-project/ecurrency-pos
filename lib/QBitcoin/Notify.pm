package QBitcoin::Notify;
use warnings;
use strict;

use Fcntl qw(O_WRONLY O_NONBLOCK O_APPEND);
use Errno qw(EAGAIN EPIPE ENXIO);
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::MyAddress;
use QBitcoin::Address qw(address_by_hash);

my $ENABLED;
my $FH;           # file handle for file/pipe mode
my $UDP_SOCKET;   # socket for UDP mode
my $NOTIFY_FILE;  # file path for reopen

sub init {
    my $class = shift;
    if ($config->{notify_file}) {
        $NOTIFY_FILE = $config->{notify_file};
        _open_file();
        $ENABLED = 1;
        Infof("Notify: file channel initialized: %s", $NOTIFY_FILE);
    }
    elsif ($config->{notify_udp}) {
        my ($host, $port) = split(/:/, $config->{notify_udp});
        if (!$host || !$port) {
            Errf("Notify: invalid notify-udp format, expected host:port, got: %s", $config->{notify_udp});
            return;
        }
        require IO::Socket::INET;
        $UDP_SOCKET = IO::Socket::INET->new(
            Proto    => 'udp',
            PeerAddr => $host,
            PeerPort => $port,
        );
        if (!$UDP_SOCKET) {
            Errf("Notify: failed to create UDP socket to %s:%s: %s", $host, $port, $!);
            return;
        }
        $ENABLED = 1;
        Infof("Notify: UDP channel initialized: %s:%s", $host, $port);
    }
}

sub enabled {
    return $ENABLED;
}

sub _open_file {
    if ($FH) {
        close $FH;
        undef $FH;
    }
    if (!sysopen($FH, $NOTIFY_FILE, O_WRONLY | O_NONBLOCK | O_APPEND)) {
        # ENXIO is expected for FIFO with no reader
        if ($! == ENXIO) {
            Debugf("Notify: no reader for pipe %s", $NOTIFY_FILE);
        }
        else {
            Warningf("Notify: failed to open %s: %s", $NOTIFY_FILE, $!);
        }
        undef $FH;
        return 0;
    }
    return 1;
}

sub notify {
    my $class = shift;
    my ($message) = @_;
    return unless $ENABLED;

    if ($NOTIFY_FILE) {
        if (!$FH) {
            _open_file() or return;
        }
        my $written = syswrite($FH, $message);
        if (!defined $written) {
            if ($! == EAGAIN) {
                # pipe buffer full, drop silently
                Debugf("Notify: pipe buffer full, dropping event");
            }
            elsif ($! == EPIPE) {
                # reader disconnected, close and reopen later
                Debugf("Notify: reader disconnected, will reopen");
                close $FH;
                undef $FH;
            }
            else {
                Warningf("Notify: write error: %s", $!);
                close $FH;
                undef $FH;
            }
        }
    }
    elsif ($UDP_SOCKET) {
        $UDP_SOCKET->send($message);
    }
}

sub check_output {
    my $class = shift;
    my ($txo, $tx, $block) = @_;
    return unless $ENABLED;

    my $my_address = QBitcoin::MyAddress->get_by_hash($txo->scripthash)
        or return;

    my $timestamp    = $block ? $block->time : time();
    my $address      = $my_address->address // address_by_hash($txo->scripthash);
    my $value        = $txo->value;
    my $txid         = unpack("H*", $tx->hash);
    my $block_height = $block ? $block->height : -1;

    my $message = join("\t", $timestamp, $address, $value, $txid, $block_height) . "\n";
    $class->notify($message);

    Debugf("Notify: %s event for address %s, value %lu, tx %s, height %d",
        $block ? "confirmed" : "mempool", $address, $value, substr($txid, 0, 8), $block_height);
}

sub check_block {
    my $class = shift;
    my ($block) = @_;
    return unless $ENABLED;

    foreach my $tx (@{$block->transactions}) {
        foreach my $txo (@{$tx->out}) {
            $class->check_output($txo, $tx, $block) if $txo->is_my;
        }
    }
}

1;
