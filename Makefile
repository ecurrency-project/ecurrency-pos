
DESTDIR=/usr/local
DST_BIN=${DESTDIR}/bin
DST_LIB=${DESTDIR}/lib
DST_ETC=${DESTDIR}/etc

all:
	@echo 'Did you mean "make test" or "make install"?'

install::
	mkdir -p ${DST_LIB} && cp -r lib/* ${DST_LIB}
	mkdir -p ${DST_BIN} && cp -r bin/* ${DST_BIN}
	#mkdir -p ${DST_ETC} && cp -r -n etc/* ${DST_ETC} || true
	@echo "Install done"

docker:: Dockerfile
	docker build --rm -t qecurrency:latest . && docker image prune --force --filter label=stage=builder

PM_FILES := $(shell find lib -type f -name '*.pm')

check_syntax:: bin/* ${PM_FILES}
${PM_FILES} bin/*::
	@CONFIG_DIR=etc perl -I lib -c $@

test:: check_syntax test/*.t
test/*.t::
	@echo $@
	@CONFIG_DIR=etc LOG_NULL=1 perl -I lib $@

.PHONY: test check_syntax
