export VIMRUNTIME := $(shell nvim -u NORC --headless +'echo $$VIMRUNTIME' +'quitall' 2>&1)

all: lint fmt-check test

lint:
	@echo "## Typechecking"
	@emmylua_check .

fmt-check:
	@echo "## Checking code format"
	@stylua --check .

fmt:
	@echo "## Formatting code"
	@stylua .

test:
	@echo "## Running tests"
	@busted --verbose

test-with-coverage:
	@rm -f luacov.*.out
	@echo "## Running tests"
	@busted --coverage --verbose
	@echo "## Generating coverage report"
	@luacov
	@awk '/^Summary$$/{flag=1;next} flag{print}' luacov.report.out

watch:
	@watchexec -c -e lua make
