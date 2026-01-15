package QBitcoin::RPC;
use warnings;
use strict;

use JSON::PP;
use Time::HiRes;
use HTTP::Headers;
use HTTP::Response;
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use parent qw(QBitcoin::HTTP);

use Role::Tiny::With;
with 'QBitcoin::RPC::Validate';
with 'QBitcoin::RPC::Commands';

mk_accessors(qw( cmd args ));

my $JSON = JSON::PP->new->allow_bignum;

sub type_id() { PROTOCOL_RPC }

sub timeout {
    my $self = shift;
    my $time = shift // time();
    my $timeout = RPC_TIMEOUT + $self->update_time - $time;
    if ($timeout < 0) {
        Infof("RPC client timeout");
        $self->connection->disconnect;
        $timeout = 0;
    }
    return $timeout;
}

sub process_request {
    my $self = shift;
    my ($http_request) = @_;
    if ($http_request->headers->content_type && lc($http_request->headers->content_type) ne "application/json") {
        Warningf("Incorrect content-type: [%s]", $http_request->headers->content_type // "");
        return $self->response_error("Incorrect content-type", ERR_INVALID_REQUEST);
    }
    my $body = eval { $JSON->decode($http_request->decoded_content) };
    if (!$body) {
        Warningf("Can't decode json request: [%s]", $http_request->decoded_content // "");
        return $self->response_error("Incorrect request body", ERR_INVALID_REQUEST);
    }
    # {"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}';
    if (ref($body) eq "ARRAY") {
        $body = $body->[0]; # Some explorers send such requests
    }
    if (ref($body) ne "HASH") {
        Warningf("Incorrect json request, not hashref: [%s]", $http_request->decoded_content);
        return $self->response_error("Incorrect request body", ERR_INVALID_REQUEST);
    }
    if (!$body->{method} || !$body->{params} ||
        ref($body->{method}) || ref($body->{params}) ne 'ARRAY') {
        Warningf("Incorrect rpc request: [%s]", $http_request->decoded_content);
        return $self->response_error("Incorrect request", ERR_INVALID_REQUEST);
    }
    my $func = "cmd_" . $body->{method};
    if (!$self->can($func)) {
        Warningf("Incorrect rpc method [%s]", $body->{method});
        return $self->response_error("Unknown method", ERR_UNKNOWN_METHOD);
    }
    Debugf("RPC request %s from %s:%u", $body->{method}, $self->connection->ip, $self->connection->port);
    $self->args = $body->{params};
    $self->cmd  = $body->{method};
    $self->validate_args == 0
        or return -1;
    return $self->$func(@{$self->{params}});
}

sub validate_args {
    my $self = shift;
    if (defined(my $spec = $self->params($self->cmd))) {
        if ($self->validate($spec) != 0) {
            return -1;
        }
    }
    else {
        Warningf("No params specification for RPC command [%s]", $self->cmd);
    }
    return 0;
}

sub response_error {
    my $self = shift;
    my ($message, $code, $result) = @_;
    my $http_code = $code == ERR_INTERNAL_ERROR ? 500 : $code == ERR_UNKNOWN_METHOD ? 404 : 400;
    return $self->http_response($http_code, $message, { error => { code => $code, message => $message }, result => $result });
}

sub response_ok {
    my $self = shift;
    my ($result) = @_; # optional, undef by default
    return $self->http_response(200, "OK", { result => $result, error => undef });
}

sub http_response {
    my $self = shift;
    my ($code, $message, $content) = @_;
    my $body = $JSON->encode($content);
    my $headers = HTTP::Headers->new(
        Content_Type   => 'application/json',
        Content_Length => length($body),
        #Connection     => 'close',
    );
    my $response = HTTP::Response->new($code, $message, $headers, $body);
    $response->protocol("HTTP/1.1");
    return $self->send($response->as_string("\r\n"));
}

1;
