package QBitcoin::RPC::Const;
use warnings;
use strict;

# Error codes: https://github.com/bitcoin/bitcoin/blob/v0.21.1/src/rpc/protocol.h#L23-L87
use constant ERR_CODES => {
    ERR_INVALID_REQUEST         => -32600,
    ERR_UNKNOWN_METHOD          => -32601,
    ERR_INVALID_PARAMS          => -32602,
    ERR_INTERNAL_ERROR          => -32603,
    ERR_PARSE_ERROR             => -32700,

    ERR_MISC                    => -1,
    ERR_INVALID_ADDRESS_OR_KEY  => -5,
    ERR_DESERIALIZATION_ERROR   => -22,
    ERR_VERIFY_ALREADY_IN_CHAIN => -27,

    # Wallet password flow. qbitcoin-cli reacts to these codes: on
    # ERR_WALLET_PASSWORD_REQUIRED it prompts for the password and retries the
    # request with a top-level "password" field; on ERR_CONFIRMATION_REQUIRED it
    # shows the error message, asks for confirmation and retries with "force".
    ERR_WALLET_UNLOCK_NEEDED      => -13,
    ERR_WALLET_PASSWORD_INCORRECT => -14,
    ERR_WALLET_PASSWORD_REQUIRED  => -17,
    ERR_CONFIRMATION_REQUIRED     => -18,
};

use constant ERR_CODES;

use JSON::XS;
use constant {
    FALSE => JSON::XS::false,
    TRUE  => JSON::XS::true,
};

use Exporter qw(import);
our @EXPORT = keys %{&ERR_CODES};
push @EXPORT, qw(FALSE TRUE);

1;
