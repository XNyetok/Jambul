# Shortcuts for the scripts in scripts/, to run from the repository's root: `make run`, `make test`, `make setup`.
.PHONY: run test setup

run:
	@./scripts/run.sh

test:
	@./scripts/test.sh

setup:
	@./scripts/setup.sh
