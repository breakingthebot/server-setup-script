# Build Notes

This log documents key architecture decisions, testing approaches, and design considerations for the Server Setup project.

## Architectural Decisions

### 1. Testability and Portability
- **Dry-run Mode**: Added a `--dry-run` flag to print simulated actions without modifying system state. This makes it possible to run verification and tests in non-root or non-Linux environments.
- **Custom Directories**: Paths for configuration, logs, and cron directories are fully parameterized. This allows our automated tests to execute setup inside a local sandbox folder rather than accessing protected root folders.

### 2. Dependency Management & Verification
- **Flexible Package Lists**: Added support for reading package names from an input dependencies file, stripping comments and extra whitespace.
- **Robust Verification**: Implemented package-manager query commands (`dpkg`, `rpm`, `pacman`) to query database state, falling back to executable existence (`command -v`) to check package status.
- **Graceful Developer Warning**: When package managers are unavailable (e.g., running locally on developer machines), failed verifications result in warnings rather than setup abortions.

### 3. Fail-Safe Execution and Rollback
- **Execution Traps**: Configured a `trap` on `EXIT` in the setup script that monitors the execution status. If the script exits with a non-zero exit status, rollback is automatically initiated.
- **Dynamic Path Recording**: Created a path-tracking registry (`CREATED_PATHS`) that dynamically records each file or directory created *only* during the active setup run. Files are deleted and directories are removed only if empty, preventing any accidental deletion of pre-existing user configurations or shared folders.

### 4. Configuration Templating & Overrides
- **Placeholder Substitution**: Replaced static environment generation with a template renderer capable of replacing `{{KEY}}` placeholders in custom template files.
- **Variable Override Chains**: Created a two-tiered configuration model: users can pass direct string overrides (via `--template-vars`) which take highest priority, with standard setup script parameters (like `APP_ENV`, `LOG_PATH`) serving as automatic fallback defaults.
- **Early Configuration Validation**: Enforces template file existence checking at option-parsing time, protecting against downstream configuration compilation failures before any setup operations begin.

## Iterations Log

### Iteration 1 (v0.1.0) - Base Setup
- Created base `setup_server.sh` with root check, package manager detection, configuration creation, and health check cron setup.
- Added automated test suite `tests/test_setup.sh`.

### Iteration 2 (v0.2.0) - Package Parameterization & Verification
- Added support for `--dependencies-file` (`-f`) flag.
- Added post-installation dependency verification checking (`dpkg`/`rpm`/`pacman`/`command -v`).

### Iteration 3 (v0.3.0) - Fail-Safe Automatic Rollback
- Implemented `trap` on exit for non-zero statuses to trigger cleanups.
- Added path-tracking and cleanup loops for safe directory/file removal.
- Added Test 8 (`test_rollback_on_failure`) verifying cleanup occurs if directories are blocked.

### Iteration 4 (v0.4.0) - Configuration Templating & Overrides
- Added support for `--template` (`-t`) and `--template-vars` parameters.
- Implemented pure Bash template compiler with override and default fallback chains.
- Added Test 9 (`test_template_rendering`) and Test 10 (`test_missing_template_file`).
