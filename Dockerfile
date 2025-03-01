# It's highly recommended to run the docker container with volume /database mounted to external directory
# for save blockchain and wallet data on restart container
# Example for run container from this image:
# docker run --volume $(pwd)/database:/database --read-only --rm --detach -p 9555:9555 --name qbitcoin qbitcoin
# then you can run "docker exec qbitcoin qbitcoin-cli help"
FROM alpine:latest AS builder
LABEL stage=builder

WORKDIR /build

RUN apk add --no-cache \
    perl perl-dev make clang gmp-dev \
    openssl-dev curl wget git

# pqclean does not muild with alpine gcc due to musl; clang is ok
RUN ln -s -f /usr/bin/clang /usr/bin/cc

RUN cpan -i Encode::Base58::GMP Math::GMPz Crypt::PK::ECC::Schnorr Crypt::PQClean::Sign

# Final minimized image
FROM alpine:latest

WORKDIR /database

RUN apk add --no-cache \
    perl openssl sqlite-libs gmp \
    perl-json-xs perl-dbd-sqlite perl-dbi \
    perl-http-message perl-hash-multivalue perl-params-validate \
    perl-role-tiny perl-tie-ixhash perl-cryptx

COPY --from=builder /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=builder /usr/local/share/perl5 /usr/local/share/perl5
COPY . /qbitcoin

ENV PERL5LIB=/qbitcoin/lib
ENV PATH=${PATH}:/qbitcoin/bin
ENV dbi=sqlite
ENV database=qbitcoin
ENV debug=

CMD if mount | grep -q " on /database "; then \
      /qbitcoin/bin/qbitcoin-init --dbi=${dbi} --database=${database} /qbitcoin/db && \
      exec /qbitcoin/bin/qbitcoind --peer=node.qcoin.info --dbi=${dbi} --database=${database} \
         --log=/dev/null --verbose ${debug:+$( [ "$debug" = "0" ] || echo --debug )}; \
    else echo "Please mount /database as external volume"; \
    fi

EXPOSE 9555
