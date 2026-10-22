.PHONY: test lint

test:
	nvim --headless --clean -l tests/run.lua

lint:
	stylua --check lua plugin tests demo
