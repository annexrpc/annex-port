PROJECT = annex_port

# dependencies

DEPS = fast_key

dep_fast_key = git https://github.com/camshaft/fast_key.git

include erlang.mk

repl: all bin/start
	@bin/start rl make

bin/start:
	@mkdir -p bin
	@curl https://gist.githubusercontent.com/camshaft/372cc332241ac95ae335/raw/start -o $@
	@chmod a+x $@

.PHONY: repl
