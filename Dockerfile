# It's highly recommended to run the docker container with volume /database mounted to external directory
# for save blockchain and wallet data on restart container
# Example for run container from this image:
# docker run --volume $(pwd)/database:/database --read-only --rm --detach -p 9666:9666 --name qecurrency qecurrency
# or:
# docker run -e dbi=mysql --mount type=bind,source=/etc/qecurrency.conf,target=/etc/qecurrency.conf,readonly -mount type=bind,source=/var/run/mysqld/mysqld.sock,target=/var/lib/mysql.sock --rm --detach -p 9666:9666 --name qecurrency qecurrency
# then you can run "docker exec qecurrency qecurrency-cli help"
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
COPY . /qecurrency
RUN cd /qecurrency; make test || exit 1
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
COPY . /qecurrency
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
    if mount | grep -q " on /var/lib/mysql.sock " && mount | grep -q " on /etc/qecurrency.conf "; then :; \
    else \
      echo "Please mount /var/lib/mysql.sock and /etc/qecurrency.conf as external files" >&2; \
      exit 1; \
    fi; \
  else \
    echo "Unsupported dbi ${dbi}, choose sqlite or mysql" >&2; \
    exit 1; \
  fi; \
  /qecurrency/bin/qecurrency-init --dbi=${dbi} --database=${database} /qecurrency/db && \
  exec /qecurrency/bin/qecurrencyd \
      --peer=seed.ecurrency.org \
      --dbi=${dbi} \
      --database=${database} \
      --rpc="*:9667" \
      --log=/dev/null \
      --verbose ${debug:+$( [ "$debug" = "0" ] || echo --debug )} \
      $@'; \
  } > /qecurrency/bin/run-qecurrency.sh \
  && chmod +x /qecurrency/bin/run-qecurrency.sh

ENV PERL5LIB=/qecurrency/lib
ENV PATH=${PATH}:/qecurrency/bin
ENV dbi=sqlite
ENV database=qecurrency
ENV debug=

ENTRYPOINT ["/qecurrency/bin/run-qecurrency.sh"]

EXPOSE 9666 9667
