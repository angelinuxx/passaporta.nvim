.PHONY: test integration

test:
	nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

integration:
	bash scripts/integration-sftp.sh
