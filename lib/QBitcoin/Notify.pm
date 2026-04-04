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
my $BASE_CHANNEL;  # default (untagged) channel
my %CHANNELS;      # tag_name => channel hashref

sub init {
    my $class = shift;

    # Base channel
    if ($config->{notify_file}) {
        $BASE_CHANNEL = _init_file_channel($config->{notify_file});
        $ENABLED = 1 if $BASE_CHANNEL;
    }
    elsif ($config->{notify_udp}) {
        $BASE_CHANNEL = _init_udp_channel($config->{notify_udp});
        $ENABLED = 1 if $BASE_CHANNEL;
    }

    # Per-tag channels: scan config for notify_file.TAG and notify_udp.TAG
    my %seen;
    for my $key ($config->keys) {
        next if $seen{$key}++;
        if ($key =~ /^notify_file\.(.+)$/) {
            my $tag = $1;
            $CHANNELS{$tag} = _init_file_channel($config->{$key});
            $ENABLED = 1 if $CHANNELS{$tag};
        }
        elsif ($key =~ /^notify_udp\.(.+)$/) {
            my $tag = $1;
            $CHANNELS{$tag} = _init_udp_channel($config->{$key});
            $ENABLED = 1 if $CHANNELS{$tag};
        }
    }
}

sub enabled {
    return $ENABLED;
}

sub _init_file_channel {
    my ($path) = @_;
    my $channel = { type => 'file', path => $path, fh => undef };
    _reopen_file($channel);
    Infof("Notify: file channel initialized: %s", $path);
    return $channel;
}

sub _init_udp_channel {
    my ($addr) = @_;
    my ($host, $port) = split(/:/, $addr);
    if (!$host || !$port) {
        Errf("Notify: invalid notify-udp format, expected host:port, got: %s", $addr);
        return undef;
    }
    require IO::Socket::INET;
    my $socket = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerAddr => $host,
        PeerPort => $port,
    );
    if (!$socket) {
        Errf("Notify: failed to create UDP socket to %s:%s: %s", $host, $port, $!);
        return undef;
    }
    Infof("Notify: UDP channel initialized: %s:%s", $host, $port);
    return { type => 'udp', socket => $socket };
}

sub _reopen_file {
    my ($channel) = @_;
    if ($channel->{fh}) {
        close $channel->{fh};
        undef $channel->{fh};
    }
    my $fh;
    if (!sysopen($fh, $channel->{path}, O_WRONLY | O_NONBLOCK | O_APPEND)) {
        # ENXIO is expected for FIFO with no reader
        if ($! == ENXIO) {
            Debugf("Notify: no reader for pipe %s", $channel->{path});
        }
        else {
            Warningf("Notify: failed to open %s: %s", $channel->{path}, $!);
        }
        return 0;
    }
    $channel->{fh} = $fh;
    return 1;
}

sub _notify_channel {
    my ($channel, $message) = @_;
    return unless $channel;

    if ($channel->{type} eq 'file') {
        if (!$channel->{fh}) {
            _reopen_file($channel) or return;
        }
        my $written = syswrite($channel->{fh}, $message);
        if (!defined $written) {
            if ($! == EAGAIN) {
                # pipe buffer full, drop silently
                Debugf("Notify: pipe buffer full, dropping event");
            }
            elsif ($! == EPIPE) {
                # reader disconnected, close and reopen later
                Debugf("Notify: reader disconnected, will reopen");
                close $channel->{fh};
                undef $channel->{fh};
            }
            else {
                Warningf("Notify: write error: %s", $!);
                close $channel->{fh};
                undef $channel->{fh};
            }
        }
    }
    elsif ($channel->{type} eq 'udp') {
        $channel->{socket}->send($message);
    }
}

sub notify {
    my $class = shift;
    my ($message) = @_;
    return unless $ENABLED;
    _notify_channel($BASE_CHANNEL, $message);
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

    # Route to the appropriate channel based on address tag
    my $tag = $my_address->tag;
    my $channel = ($tag && $CHANNELS{$tag}) ? $CHANNELS{$tag} : $BASE_CHANNEL;
    _notify_channel($channel, $message);

    Debugf("Notify: %s event for address %s, value %lu, tx %s, height %d%s",
        $block ? "confirmed" : "mempool", $address, $value, substr($txid, 0, 8), $block_height,
        $tag ? ", tag $tag" : "");
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
