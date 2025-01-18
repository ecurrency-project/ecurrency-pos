
DESTDIR=/usr/local
DST_BIN=${DESTDIR}/bin
DST_LIB=${DESTDIR}/lib
DST_ETC=/etc

all:
	@echo 'Did you mean "make test" or "make install"?'

install::
	mkdir -p ${DST_LIB} && cp -r lib/* ${DST_LIB}
	mkdir -p ${DST_BIN} && cp -r bin/* ${DST_BIN}
	mkdir -p ${DST_ETC} && cp -r -n etc/* ${DST_ETC} || true
	@echo "Install done"

installdeps::
	@for module in Encode::Base58::GMP Math::GMPz Crypt::PK::ECC::Schnorr Crypt::Digest::Scrypt Crypt::PQClean::Sign JSON::XS DBI DBD::SQLite DBD::mysql HTTP::Message Hash::MultiValue Params::Validate Role::Tiny Tie::IxHash CryptX Test::MockModule; do \
		perl -M$${module} -e '' 2>/dev/null && continue || cpan -i $${module}; \
		perl -M$${module} -e '' 2>/dev/null || exit 1; \
	done

DOCKER = $(shell (docker -h >/dev/null 2>&1 && echo docker) || (podman -h >/dev/null 2>&1 && echo podman))

docker:: Dockerfile
	@[ -n "$(DOCKER)" ] || { echo "Neither docker nor podman found" >&2; exit 1; }
	$(DOCKER) build --rm -t qecurrency:latest . && $(DOCKER) image prune --force --filter label=stage=builder

PM_FILES := $(shell find lib -type f -name '*.pm')

check_syntax:: bin/* ${PM_FILES}
${PM_FILES} bin/*::
	@CONFIG_DIR=etc perl -I lib -c $@

test:: check_syntax test/*.t
test/*.t::
	@echo $@
	@CONFIG_DIR=etc LOG_NULL=1 perl -I lib $@

.PHONY: test check_syntax
