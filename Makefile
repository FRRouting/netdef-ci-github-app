# Convenience targets. Dependencies are installed from requirements*.txt only (no other package manager).
PYTHON ?= python3.13
VENV   ?= .venv
BIN    := $(VENV)/bin
export PYTHONPATH := src

.PHONY: venv install install-dev migrate run worker watch-dog test lint typecheck check smoke docs-tables github-app

venv:
	$(PYTHON) -m venv $(VENV)

install: venv
	$(BIN)/pip install --only-binary=:all: -r requirements.txt

install-dev: venv
	$(BIN)/pip install --only-binary=:all: -r requirements-dev.txt

migrate:
	$(BIN)/python -m netdef_ci migrate

run:
	$(BIN)/python -m uvicorn --factory netdef_ci.app.github_app:app_factory --host 0.0.0.0 --port $${PORT:-9292}

worker:
	$(BIN)/python -m netdef_ci worker

watch-dog:
	$(BIN)/python -m netdef_ci watch-dog

test:
	$(BIN)/python -m pytest tests --cov --cov-report=term-missing

lint:
	$(BIN)/ruff check src tests migrations
	$(BIN)/ruff format --check src tests migrations
	$(BIN)/python scripts/align_md_tables.py --check

docs-tables:
	$(BIN)/python scripts/align_md_tables.py

typecheck:
	$(BIN)/mypy src

check: lint typecheck test

smoke:
	$(BIN)/python scripts/smoke_test.py

# First GitHub App of a new environment (doc/13-github-app-setup.md):
#   make github-app ENV=dev REPO=<owner>/<repo> URL=https://<public-host>/githubcheck
github-app:
	$(BIN)/python -m netdef_ci create-github-app --inventory deploy/ansible/inventories/$(ENV) --repo $(REPO) \
		--webhook-url $(URL)
