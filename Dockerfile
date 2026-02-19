# It's highly recommended to run the docker container with volume /database mounted to external directory
# for save blockchain and wallet data on restart container
# Example for run container from this image:
# docker run --volume $(pwd)/database:/database --read-only --rm --detach -p 9666:9666 9669:9669 --name qecurrency qecurrency
# or:
# docker run -e dbi=mysql --mount type=bind,source=/etc/qecurrency.conf,target=/etc/qecurrency.conf,readonly -mount type=bind,source=/var/run/mysqld/mysqld.sock,target=/var/lib/mysql.sock --rm --detach -p 9666:9666 -p 9669:9669 --name qecurrency qecurrency
# then you can run "docker exec qecurrency qecurrency-cli help"
FROM alpine:latest AS builder
LABEL stage=builder

WORKDIR /build

RUN apk add --no-cache \
    perl perl-dev make clang gmp-dev \
    openssl-dev curl wget git pnpm

# pqclean does not build with alpine gcc due to musl; clang is ok
RUN ln -s -f /usr/bin/clang /usr/bin/cc

RUN cpan -i Encode::Base58::GMP Math::GMPz Crypt::PK::ECC::Schnorr Crypt::PQClean::Sign Crypt::Digest::Scrypt JSON::PP

# Run tests
RUN apk add --no-cache \
    perl openssl sqlite-libs gmp \
    perl-json-xs perl-dbi perl-dbd-sqlite \
    perl-http-message perl-hash-multivalue perl-params-validate \
    perl-role-tiny perl-tie-ixhash perl-cryptx
RUN apk add --no-cache perl-test-mockmodule
COPY . /qecurrency
RUN cd /qecurrency; make test || exit 1
RUN cd /qecurrency/admin; CI=true make || exit 1
RUN cd /qecurrency; rm -rf test systemd Dockerfile Makefile
RUN cd /qecurrency/admin; find . -mindepth 1 -maxdepth 1 ! -name 'www' ! -name 'etc' -exec rm -rf {} +
RUN apk del --no-cache perl-test-mockmodule

# Final minimized image
FROM alpine:latest

WORKDIR /database

RUN apk add --no-cache \
    perl openssl sqlite-libs gmp \
    perl-json-xs perl-dbd-sqlite perl-dbd-mysql perl-dbi \
    perl-http-message perl-hash-multivalue perl-params-validate \
    perl-role-tiny perl-tie-ixhash perl-cryptx busybox-extras

COPY --from=builder /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=builder /usr/local/share/perl5 /usr/local/share/perl5
COPY --from=builder /qecurrency /qecurrency
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
  /bin/busybox-extras httpd -p 9669 -u nobody -c /qecurrency/admin/etc/httpd.conf; \
  /qecurrency/bin/qecurrency-init --dbi=${dbi} --database=${database} /qecurrency/db && \
  notify_args=""; \
  if [ -n "${notify_url}" ]; then \
    url_args=""; \
    IFS=","; for u in ${notify_url}; do \
      url_args="${url_args} --url=${u}"; \
    done; unset IFS; \
    /qecurrency/bin/qecurrency-notify --source-udp=9665 ${url_args} --verbose & \
    notify_args="--notify-udp=127.0.0.1:9665"; \
  fi; \
  exec /qecurrency/bin/qecurrencyd \
      --peer=seed.ecurrency.org \
      --dbi=${dbi} \
      --database=${database} \
      --rpc="*:9667" \
      --rest="127.0.0.1:9668" \
      --log=/dev/null \
      --verbose ${debug:+$( [ "$debug" = "0" ] || echo --debug )} \
      ${notify_args:+${notify_args}} \
      $@'; \
  } > /qecurrency/bin/run-qecurrency.sh \
  && chmod +x /qecurrency/bin/run-qecurrency.sh

ENV PERL5LIB=/qecurrency/lib
ENV PATH=${PATH}:/qecurrency/bin
ENV dbi=sqlite
ENV database=qecurrency
ENV debug=
ENV notify_url=
# Workaround mariadb-connector-c 3.4x in alpine 3.23 which fail to connect without SSL by default
ENV MARIADB_TLS_DISABLE_PEER_VERIFICATION=1

ENTRYPOINT ["/qecurrency/bin/run-qecurrency.sh"]

EXPOSE 9666 9667 9669
