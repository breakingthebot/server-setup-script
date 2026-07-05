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

### 5. Webhook Status Notifications
- **JSON Payload Assembly**: Compiles key metrics (setup status: `SUCCESS`/`FAILURE`, hostname, run duration, and detailed messages) into a structured JSON string.
- **Asynchronous Execution Guard**: Dispatches network requests via background/timeout tasks (using `curl --max-time 10`) to prevent slow or unreachable networks from hanging the script.
- **Dual Trigger Hooks**: Integrates status notification firing at setup success (end of script) and setup failure (inside the EXIT trap after rollback), ensuring teams receive real-time build states.

### 6. Logging Levels & Diagnostic Archiving
- **Standardized Logging Utilities**: Introduced `log_debug`, `log_info`, `log_warn`, and `log_error` utility print commands. Output is automatically filtered based on the numerical priority mapping of the `--log-level` parameter.
- **Early-State Diagnostics Capture**: On execution failure, the script generates a diagnostics report (system-info containing timestamp, hostname, OS uname details, disk utilization, and free memory) and copies the config/log folders *before* triggering the rollback sequence.
- **Diagnostics Tarball Compilation**: Compresses diagnostic files into a `setup-diagnostics-<timestamp>.tar.gz` archive, saving it to the parent directory for troubleshooting reference while maintaining a clean final system state.

### 7. Active Resource Monitoring & Alerting
- **Threshold Configuration Persistence**: Exposed `--disk-threshold` and `--mem-threshold` configuration flags. Threshold values are persisted inside `env.conf` (or templated during generation) to allow runtime tuning without modifying cron script code.
- **Automated Resource Monitoring**: Programmed `health-check.sh` to extract active disk usage (via `df`) and memory utilization (via `free`), evaluating them against the configured limit percentages.
- **Dual alert triggers**: Real-time threshold breaches log standard warning messages to `server.log` and asynchronously POST a JSON formatted webhook alert containing details and target hostname to operations.

### 8. Systemd Service Configuration & Enablement Helper
- **Automated Service Unit File Generation**: Added support for creating custom Systemd unit configuration files (`<service-name>.service`) specifying custom commands (`--service-cmd`), execution users (`--service-user`), auto-restart strategies, and unit descriptions.
- **Dynamic Service Lifecycle Management**: Integrated lifecycle calls to reload the systemd daemon (`systemctl daemon-reload`), register the service to auto-start on system boot (`systemctl enable`), and launch it immediately (`systemctl start`).
- **Target OS Fail-Safe**: Validates availability of the `systemctl` executable first. On non-Linux or test platforms (such as local Windows environments), enablement instructions are safely bypassed with a standard warning, avoiding build errors.

### 9. Health Check Cron Schedule Customization
- **Parameterizable Schedule Overrides**: Added the `--cron-schedule` option to allow overriding the default 5-minute health check interval with custom cron expressions.
- **Shortcut Expressions Mapping**: Implemented validation and translation of shortcut schedules (`hourly`, `daily`, `weekly`) to standard cron expressions (`0 * * * *`, `0 0 * * *`, `0 0 * * 0`).
- **Schedule Syntax Verification**: Validates custom expressions by verifying they contain exactly 5 whitespace-separated fields, failing early on incorrect specifications.

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

### Iteration 5 (v0.5.0) - Webhook Status Notifications
- Added `--webhook-url` (`-w`) option to send status updates.
- Integrated `send_webhook_notification` helper triggered on both script success and error/rollback events.
- Added Test 11 (`test_webhook_dry_run`) validating dry-run notification output and payload metrics.

### Iteration 6 (v0.6.0) - Logging Levels & Diagnostic Archiving
- Added support for `--log-level` (`-l`) command parameter.
- Implemented logging utility helper functions and output level filtering.
- Implemented `export_diagnostics` packaging up configurations, setup logs, and system details into a compressed tarball on script failure.
- Added Test 12 (`test_logging_filtering`) and Test 13 (`test_diagnostics_archive_on_failure`).

### Iteration 7 (v0.7.0) - Active Resource Monitoring Alerts
- Added `--disk-threshold` and `--mem-threshold` options.
- Saved active thresholds and webhook URLs inside target `env.conf` files.
- Programmed generated `health-check.sh` to extract resource usage, check thresholds, and trigger alert webhooks.
- Added Test 14 (`test_custom_thresholds_written`) and Test 15 (`test_health_check_threshold_alert`).

### Iteration 8 (v0.8.0) - Systemd Service Configuration Helper
- Added `--service-name`, `--service-cmd`, `--service-user`, and `--systemd-dir` flags.
- Built Systemd unit template generator producing robust unit configuration files.
- Integrated systemctl lifecycle controls (`daemon-reload`, `enable`, `start`) with OS capability fallbacks.
- Added Test 16 (`test_systemd_service_creation`) and Test 17 (`test_systemd_empty_cmd_fails`).

### 9. Health Check Cron Schedule Customization
- **Parameterizable Schedule Overrides**: Added the `--cron-schedule` option to allow overriding the default 5-minute health check interval with custom cron expressions.
- **Shortcut Expressions Mapping**: Implemented validation and translation of shortcut schedules (`hourly`, `daily`, `weekly`) to standard cron expressions (`0 * * * *`, `0 0 * * *`, `0 0 * * 0`).
- **Schedule Syntax Verification**: Validates custom expressions by verifying they contain exactly 5 whitespace-separated fields, failing early on incorrect specifications.

### 10. Automated Rolling Log Rotation
- **Hybrid Rotation Strategy**: Combines native system policies (`/etc/logrotate.d/server-setup`) and a lightweight internal shell-based fallback check directly in `health-check.sh`.
- **Target OS Non-Writable Fallbacks**: Added write permissions validation for `--logrotate-dir` configurations. If directories are non-writable (like `/etc/logrotate.d` in test sandbox modes), the script outputs warnings and moves forward cleanly.
- **Self-Contained copytruncate Checks**: The health checker portably monitors log file byte size against threshold values (`--max-log-size KB`), triggering safe copytruncate rotations (backing up to `.log.1` and clearing logs) without breaking open file descriptors.

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

### Iteration 5 (v0.5.0) - Webhook Status Notifications
- Added `--webhook-url` (`-w`) option to send status updates.
- Integrated `send_webhook_notification` helper triggered on both script success and error/rollback events.
- Added Test 11 (`test_webhook_dry_run`) validating dry-run notification output and payload metrics.

### Iteration 6 (v0.6.0) - Logging Levels & Diagnostic Archiving
- Added support for `--log-level` (`-l`) command parameter.
- Implemented logging utility helper functions and output level filtering.
- Implemented `export_diagnostics` packaging up configurations, setup logs, and system details into a compressed tarball on script failure.
- Added Test 12 (`test_logging_filtering`) and Test 13 (`test_diagnostics_archive_on_failure`).

### Iteration 7 (v0.7.0) - Active Resource Monitoring Alerts
- Added `--disk-threshold` and `--mem-threshold` options.
- Saved active thresholds and webhook URLs inside target `env.conf` files.
- Programmed generated `health-check.sh` to extract resource usage, check thresholds, and trigger alert webhooks.
- Added Test 14 (`test_custom_thresholds_written`) and Test 15 (`test_health_check_threshold_alert`).

### Iteration 8 (v0.8.0) - Systemd Service Configuration Helper
- Added `--service-name`, `--service-cmd`, `--service-user`, and `--systemd-dir` flags.
- Built Systemd unit template generator producing robust unit configuration files.
- Integrated systemctl lifecycle controls (`daemon-reload`, `enable`, `start`) with OS capability fallbacks.
- Added Test 16 (`test_systemd_service_creation`) and Test 17 (`test_systemd_empty_cmd_fails`).

### Iteration 9 (v0.9.0) - Health Check Cron Schedule Customization
- Added `--cron-schedule` option to customize periodic monitoring executions.
- Implemented validations for standard shortcuts (`hourly`, `daily`, `weekly`) and raw 5-field cron syntax.
- Appended configuration templates and defaults to save active schedules inside target directories.
- Added Test 18 (`test_cron_schedule_custom`) and Test 19 (`test_cron_schedule_invalid_fails`).

### Iteration 10 (v1.0.0) - Log Rotation & Size Constraints
- Added `--max-log-size` and `--logrotate-dir` options.
- Implemented logrotate configuration file generator and non-writable directory fallbacks.
- Implemented copytruncate log size check loop inside generated health-check scripts.
- Added Test 20 (`test_log_rotation_config`) and Test 21 (`test_health_check_log_rotation`).
