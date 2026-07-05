# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-07-05

### Added
- Added support for `--webhook-url` (`-w`) option to send status updates.
- Added `send_webhook_notification` function to assemble JSON payloads containing setup status (`SUCCESS`/`FAILURE`), server hostname, duration, and details.
- Integrated background dispatching using `curl` with a 10-second timeout to protect setups from slow networks.
- Added automated Test 11 (`test_webhook_dry_run`) verifying dry-run webhook payloads.

## [0.4.0] - 2026-07-05

### Added
- Added support for `--template` (`-t`) option to load custom configuration template files.
- Added support for `--template-vars` option to specify space-separated `KEY=VAL` parameter overrides.
- Implemented template placeholder compilation with variable override lookup and default setup parameter fallbacks.
- Added automated test cases checking rendering overrides and missing template failures in `tests/test_setup.sh`.

## [0.3.0] - 2026-07-05

### Added
- Implemented automatic rollback trap mechanism triggered on non-zero exit codes to clean up configuration and log folders on failure.
- Added file/directory tracking registry to safely remove files and directories without altering pre-existing files.
- Added `test_rollback_on_failure` test case verifying rollback execution and pre-existing file safety.

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
