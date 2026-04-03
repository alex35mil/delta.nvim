test: tests/deps/mini.test
	nvim --headless --noplugin -u ./tests/init.lua -c "lua dofile('./tests/run.lua')"

test-file: tests/deps/mini.test
	FILE='$(FILE)' nvim --headless --noplugin -u ./tests/init.lua -c "lua dofile('./tests/run.lua')"

tests/deps/mini.test:
	@mkdir -p tests/deps
	git clone --filter=blob:none https://github.com/nvim-mini/mini.test $@
