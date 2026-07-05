# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-05

### Added
- Added support for `--dependencies-file` (`-f`) option in `setup_server.sh` to read system dependencies from an input text file.
- Added `verify_dependencies` function post-package-installation. Performs package manager-specific query (`dpkg`, `rpm`, `pacman`) or fallback executable command checks.
- Added automated test cases for `--dependencies-file` parsing and verification behaviors in `tests/test_setup.sh`.

## [0.1.0] - 2026-07-05

### Added
- Created `setup_server.sh` script to install dependencies, write configuration environment, and set up cron jobs.
- Implemented options like `--dry-run`, `--skip-root-check`, `--config-dir`, `--cron-dir`, and `--log-dir`.
- Added automated test suite `tests/test_setup.sh` that mocks target directories and validates dry-run and configuration flows.
- Added standard MIT `LICENSE` file.
- Added `README.md` containing script documentation, usage guidelines, and test instructions.
