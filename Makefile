NVIM     ?= nvim
SPEC_DIR  = spec
INIT      = $(SPEC_DIR)/minimal_init.lua

# Run all tests
.PHONY: test
test:
	$(NVIM) --headless -u $(INIT) \
		-c "lua require('plenary.test_harness').test_directory('$(SPEC_DIR)/', { minimal_init = '$(INIT)', sequential = true })" \
		2>&1

# Run a single spec file: make test-file FILE=spec/ora/config_spec.lua
.PHONY: test-file
test-file:
	@test -n "$(FILE)" || (echo "Usage: make test-file FILE=<path>"; exit 1)
	$(NVIM) --headless -u $(INIT) \
		-c "lua require('plenary.test_harness').test_file('$(FILE)', { minimal_init = '$(INIT)' })" \
		2>&1

# Launch Neovim with the plugin loaded for interactive development
.PHONY: dev
dev:
	$(NVIM) -u dev/init.lua
