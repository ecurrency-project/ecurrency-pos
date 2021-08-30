# It's highly recommended to run the docker container with volume /database mounted to external directory
# for save blockchain and wallet data on restart container
# Example for run container from this image:
# docker run --volume $(pwd)/database:/database --read-only --rm --detach -p 9555:9555 --name qbitcoin qbitcoin
# or:
# docker run -e dbi=mysql --mount type=bind,source=/etc/qbitcoin.conf,target=/etc/qbitcoin.conf,readonly -mount type=bind,source=/var/run/mysqld/mysqld.sock,target=/var/lib/mysql.sock --rm --detach -p 9555:9555 --name qbitcoin qbitcoin
# then you can run "docker exec qbitcoin qbitcoin-cli help"
FROM alpine:latest AS builder
LABEL stage=builder

WORKDIR /build

RUN apk add --no-cache \
    perl perl-dev make clang gmp-dev \
    openssl-dev curl wget git

# pqclean does not build with alpine gcc due to musl; clang is ok
RUN ln -s -f /usr/bin/clang /usr/bin/cc

RUN cpan -i Encode::Base58::GMP Math::GMPz Crypt::PK::ECC::Schnorr Crypt::PQClean::Sign Crypt::Digest::Scrypt

# Run tests
RUN apk add --no-cache \
    perl openssl sqlite-libs gmp \
    perl-json-xs perl-dbi perl-dbd-sqlite \
    perl-http-message perl-hash-multivalue perl-params-validate \
    perl-role-tiny perl-tie-ixhash perl-cryptx
RUN apk add --no-cache perl-test-mockmodule
COPY . /qbitcoin
RUN cd /qbitcoin; make test || exit 1
RUN apk del --no-cache perl-test-mockmodule

# Final minimized image
FROM alpine:latest

WORKDIR /database

RUN apk add --no-cache \
    perl openssl sqlite-libs gmp \
    perl-json-xs perl-dbd-sqlite perl-dbd-mysql perl-dbi \
    perl-http-message perl-hash-multivalue perl-params-validate \
    perl-role-tiny perl-tie-ixhash perl-cryptx

COPY --from=builder /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=builder /usr/local/share/perl5 /usr/local/share/perl5
COPY . /qbitcoin
RUN { \
  echo "#! /bin/sh"; \
  echo '\
  if [ "${dbi}" = "sqlite" ]; then \
    if mount | grep -q " on /database "; then :; \
    else \
      echo "Please mount /database as an external volume" >&2; \
      exit 1; \
    fi; \
  elif [ "${dbi}" = "mysql" ]; then \
    if mount | grep -q " on /var/lib/mysql.sock " && mount | grep -q " on /etc/qbitcoin.conf "; then :; \
    else \
      echo "Please mount /var/lib/mysql.sock and /etc/qbitcoin.conf as external files" >&2; \
      exit 1; \
    fi; \
  else \
    echo "Unsupported dbi ${dbi}, choose sqlite or mysql" >&2; \
    exit 1; \
  fi; \
  /qbitcoin/bin/qbitcoin-init --dbi=${dbi} --database=${database} /qbitcoin/db && \
  exec /qbitcoin/bin/qbitcoind \
      --peer=node.qbitcoin.net \
      --dbi=${dbi} \
      --database=${database} \
      --rpc="*:9556" \
      --log=/dev/null \
      --verbose ${debug:+$( [ "$debug" = "0" ] || echo --debug )} \
      $@'; \
  } > /qbitcoin/bin/run-qbitcoin.sh \
  && chmod +x /qbitcoin/bin/run-qbitcoin.sh

ENV PERL5LIB=/qbitcoin/lib
ENV PATH=${PATH}:/qbitcoin/bin
ENV dbi=sqlite
ENV database=qbitcoin
ENV debug=

ENTRYPOINT ["/qbitcoin/bin/run-qbitcoin.sh"]

EXPOSE 9555 9556
