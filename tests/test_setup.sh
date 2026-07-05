#!/bin/bash
# tests/test_setup.sh - Test suite for setup_server.sh

set -euo pipefail

# Find the directory of this script
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"
SETUP_SCRIPT="$PROJECT_ROOT/setup_server.sh"

# Set up a temporary sandbox directory for testing
SANDBOX="$TEST_DIR/sandbox"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"

# Define mock directories inside our sandbox
MOCK_CONFIG="$SANDBOX/config"
MOCK_CRON="$SANDBOX/cron"
MOCK_LOG="$SANDBOX/log"

# Define test runner helper
run_test() {
  local test_name="$1"
  shift
  echo -n "Running test: $test_name... "
  if "$@"; then
    echo "PASSED"
  else
    echo "FAILED"
    exit 1
  fi
}

# --- TEST CASES ---

# Test 1: Help option displays usage and exits with 0
test_help_option() {
  local output
  output=$("$SETUP_SCRIPT" --help)
  echo "$output" | grep -q "Usage:"
}

# Test 2: Unknown options fail with non-zero status
test_invalid_option() {
  if "$SETUP_SCRIPT" --invalid-flag &>/dev/null; then
    return 1 # Should fail
  else
    return 0 # Failed as expected
  fi
}

# Test 3: Running setup in dry-run mode does not create any files
test_dry_run() {
  local test_sandbox="$SANDBOX/dry_run"
  mkdir -p "$test_sandbox"
  
  "$SETUP_SCRIPT" --dry-run --skip-root-check \
    --config-dir "$test_sandbox/config" \
    --cron-dir "$test_sandbox/cron" \
    --log-dir "$test_sandbox/log" > /dev/null
    
  # Check that no directories or files were created
  if [ -d "$test_sandbox/config" ] || [ -d "$test_sandbox/cron" ] || [ -d "$test_sandbox/log" ]; then
    return 1
  fi
  return 0
}

# Test 4: Setup successfully configures directories and files
test_successful_setup() {
  rm -rf "$MOCK_CONFIG" "$MOCK_CRON" "$MOCK_LOG"
  
  "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$MOCK_CONFIG" \
    --cron-dir "$MOCK_CRON" \
    --log-dir "$MOCK_LOG" > /dev/null
    
  # Check config directory and environment config file
  if [ ! -f "$MOCK_CONFIG/env.conf" ]; then
    echo "env.conf missing" >&2
    return 1
  fi
  
  # Verify config contents
  grep -q "APP_ENV=production" "$MOCK_CONFIG/env.conf"
  grep -q "LOG_PATH=$MOCK_LOG/server.log" "$MOCK_CONFIG/env.conf"
  
  # Check cron file
  if [ ! -f "$MOCK_CRON/server-health-check" ]; then
    echo "cron file missing" >&2
    return 1
  fi
  
  # Verify cron file content references root and the health-check script
  grep -q "root" "$MOCK_CRON/server-health-check"
  grep -q "$MOCK_CONFIG/health-check.sh" "$MOCK_CRON/server-health-check"
  
  # Check health check script exists and is executable
  if [ ! -x "$MOCK_CONFIG/health-check.sh" ]; then
    echo "health check script missing or not executable" >&2
    return 1
  fi
  
  return 0
}

# Test 5: Running health-check.sh generates logs correctly
test_health_check_execution() {
  # Clean old logs
  rm -f "$MOCK_LOG/server.log"
  
  # Execute the health check script
  "$MOCK_CONFIG/health-check.sh"
  
  # Verify log file is created
  if [ ! -f "$MOCK_LOG/server.log" ]; then
    echo "server.log missing after running health-check.sh" >&2
    return 1
  fi
  
  # Verify log content contains "Health Check" and "Uptime" or "Disk usage"
  grep -q "=== Health Check:" "$MOCK_LOG/server.log"
  grep -q "Uptime:" "$MOCK_LOG/server.log"
  grep -q "Disk usage:" "$MOCK_LOG/server.log"
  
  return 0
}

# Test 6: Custom dependencies file parsing and dry-run verification output
test_custom_dependencies_file() {
  local dep_file="$SANDBOX/deps.txt"
  # Create a custom dependencies file with comments and empty lines
  cat <<EOF > "$dep_file"
# This is a comment
  
bash
curl
# Another comment
git
EOF

  local test_sandbox="$SANDBOX/custom_deps"
  mkdir -p "$test_sandbox/config" "$test_sandbox/cron" "$test_sandbox/log"

  # We use dry-run to print output and capture it
  local output
  output=$("$SETUP_SCRIPT" --dry-run --skip-root-check \
    --config-dir "$test_sandbox/config" \
    --cron-dir "$test_sandbox/cron" \
    --log-dir "$test_sandbox/log" \
    --dependencies-file "$dep_file")
    
  # Check if dry-run installs only the packages listed in deps.txt (bash, curl, git)
  if ! echo "$output" | grep -q "Would use package manager '.*' to install: bash curl git"; then
    echo "Dry-run installation output mismatch" >&2
    return 1
  fi

  # Check if dry-run verifies packages listed in deps.txt
  if ! echo "$output" | grep -q "Would verify package installation for: bash" || \
     ! echo "$output" | grep -q "Would verify package installation for: curl" || \
     ! echo "$output" | grep -q "Would verify package installation for: git"; then
    echo "Dry-run verification output mismatch" >&2
    return 1
  fi
  return 0
}

# Test 7: Missing dependencies file fails
test_missing_dependencies_file() {
  local non_existent_file="$SANDBOX/does_not_exist.txt"
  
  if "$SETUP_SCRIPT" --dry-run --skip-root-check --dependencies-file "$non_existent_file" &>/dev/null; then
    return 1 # Should fail
  else
    return 0 # Failed as expected
  fi
}

# Test 8: Automatic rollback cleans up created files on failure
test_rollback_on_failure() {
  local rollback_sandbox="$SANDBOX/rollback_test"
  rm -rf "$rollback_sandbox"
  mkdir -p "$rollback_sandbox"
  
  local mock_config="$rollback_sandbox/config"
  local mock_log="$rollback_sandbox/log"
  # Force failure in setup_cron_jobs by making mock_cron a file rather than a directory
  local mock_cron="$rollback_sandbox/cron_blocked_file"
  touch "$mock_cron"

  # Run script which should configure config/log, then fail on cron setup and rollback
  if "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$mock_config" \
    --cron-dir "$mock_cron" \
    --log-dir "$mock_log" &>/dev/null; then
    echo "Expected script to fail due to blocked cron directory, but it succeeded." >&2
    return 1
  fi

  # After failure, verify rollback cleaned up config and log directories we created
  if [ -d "$mock_config" ]; then
    echo "Rollback failed: $mock_config was not deleted" >&2
    return 1
  fi
  
  if [ -d "$mock_log" ]; then
    echo "Rollback failed: $mock_log was not deleted" >&2
    return 1
  fi

  # Verify the blocking file still exists (we didn't delete things we didn't create)
  if [ ! -f "$mock_cron" ]; then
    echo "Error: The pre-existing file $mock_cron was deleted!" >&2
    return 1
  fi

  return 0
}

# Test 9: Configuration template rendering with overrides
test_template_rendering() {
  local temp_dir="$SANDBOX/template_test"
  mkdir -p "$temp_dir"
  
  local template_file="$temp_dir/my_env.template"
  cat <<'EOF' > "$template_file"
# Template Test file
ENVIRONMENT={{APP_ENV}}
PORT={{PORT}}
DB_HOST={{DB_HOST}}
CHECK_INTERVAL={{SYS_CHECK_INTERVAL}}
LOG_FILE={{LOG_PATH}}
EOF

  local mock_config="$temp_dir/config"
  local mock_log="$temp_dir/log"
  local mock_cron="$temp_dir/cron"

  # Run setup using the template and overrides
  "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$mock_config" \
    --cron-dir "$mock_cron" \
    --log-dir "$mock_log" \
    --template "$template_file" \
    --template-vars "APP_ENV=staging PORT=8080 DB_HOST=db.local" >/dev/null

  # Verify env.conf was generated from template
  local generated_file="$mock_config/env.conf"
  if [ ! -f "$generated_file" ]; then
    echo "env.conf not generated" >&2
    return 1
  fi

  # Check replaced placeholders
  if ! grep -q "ENVIRONMENT=staging" "$generated_file"; then
    echo "Placeholder ENVIRONMENT=staging failed" >&2
    return 1
  fi
  if ! grep -q "PORT=8080" "$generated_file"; then
    echo "Placeholder PORT=8080 failed" >&2
    return 1
  fi
  if ! grep -q "DB_HOST=db.local" "$generated_file"; then
    echo "Placeholder DB_HOST=db.local failed" >&2
    return 1
  fi
  
  # Check standard fallbacks
  if ! grep -q "CHECK_INTERVAL=300" "$generated_file"; then
    echo "Fallback CHECK_INTERVAL=300 failed" >&2
    return 1
  fi
  if ! grep -q "LOG_FILE=$mock_log/server.log" "$generated_file"; then
    echo "Fallback LOG_FILE=$mock_log/server.log failed" >&2
    return 1
  fi

  return 0
}

# Test 10: Missing template file fails
test_missing_template_file() {
  local non_existent_file="$SANDBOX/no_template_here.template"
  
  if "$SETUP_SCRIPT" --dry-run --skip-root-check --template "$non_existent_file" &>/dev/null; then
    return 1 # Should fail
  else
    return 0 # Failed as expected
  fi
}

# Test 11: Webhook notifications in dry-run mode
test_webhook_dry_run() {
  local output
  output=$("$SETUP_SCRIPT" --dry-run --skip-root-check --webhook-url "http://example.com/webhook-test")
  
  if ! echo "$output" | grep -q "Would send POST request to http://example.com/webhook-test"; then
    echo "Dry-run webhook message missing" >&2
    return 1
  fi
  if ! echo "$output" | grep -q "Status"; then
    echo "Dry-run webhook status key missing" >&2
    return 1
  fi
  if ! echo "$output" | grep -q "Host"; then
    echo "Dry-run webhook host key missing" >&2
    return 1
  fi
  if ! echo "$output" | grep -q "Duration"; then
    echo "Dry-run webhook duration key missing" >&2
    return 1
  fi
  return 0
}

# Test 12: Logging level filtering
test_logging_filtering() {
  local output_warn
  # If log-level is set to WARN, INFO logs (like setup start) should NOT appear
  output_warn=$("$SETUP_SCRIPT" --dry-run --skip-root-check --log-level WARN)
  
  if echo "$output_warn" | grep -q "=== Server Setup Started ==="; then
    echo "Expected INFO logs to be filtered out at WARN level, but they were displayed." >&2
    return 1
  fi
  
  local output_debug
  output_debug=$("$SETUP_SCRIPT" --dry-run --skip-root-check --log-level DEBUG)
  
  # INFO logs should appear at DEBUG level
  if ! echo "$output_debug" | grep -q "=== Server Setup Started ==="; then
    echo "Expected INFO logs to be displayed at DEBUG level, but they were missing." >&2
    return 1
  fi
  
  return 0
}

# Test 13: Diagnostics archive creation on failure
test_diagnostics_archive_on_failure() {
  local diag_sandbox="$SANDBOX/diag_test"
  rm -rf "$diag_sandbox"
  mkdir -p "$diag_sandbox"
  
  local mock_config="$diag_sandbox/config"
  local mock_log="$diag_sandbox/log"
  # Block cron directory creation by creating a file
  local mock_cron="$diag_sandbox/cron_blocked_file"
  touch "$mock_cron"

  # Run script which should fail
  if "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$mock_config" \
    --cron-dir "$mock_cron" \
    --log-dir "$mock_log" &>/dev/null; then
    echo "Expected script to fail, but it succeeded." >&2
    return 1
  fi

  # Verify that a diagnostics archive tarball was created in $diag_sandbox (parent of mock_config)
  local archive
  archive=$(find "$diag_sandbox" -name "setup-diagnostics-*.tar*" | head -n 1)
  if [ -z "$archive" ]; then
    echo "Diagnostics archive was not generated on failure" >&2
    return 1
  fi

  # Check inside the tarball to ensure it contains system-info.txt
  if ! tar -tf "$archive" | grep -q "system-info.txt"; then
    echo "Diagnostics archive does not contain system-info.txt" >&2
    return 1
  fi

  return 0
}

# Test 14: Custom threshold parameters are written to env.conf
test_custom_thresholds_written() {
  local temp_dir="$SANDBOX/thresholds_test"
  mkdir -p "$temp_dir/config" "$temp_dir/cron" "$temp_dir/log"
  
  "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --disk-threshold 80 \
    --mem-threshold 75 >/dev/null
    
  local gen_config="$temp_dir/config/env.conf"
  if [ ! -f "$gen_config" ]; then
    echo "env.conf not generated" >&2
    return 1
  fi
  
  if ! grep -q "ALERT_DISK_THRESHOLD=80" "$gen_config"; then
    echo "ALERT_DISK_THRESHOLD not written correctly" >&2
    return 1
  fi
  if ! grep -q "ALERT_MEM_THRESHOLD=75" "$gen_config"; then
    echo "ALERT_MEM_THRESHOLD not written correctly" >&2
    return 1
  fi
  
  return 0
}

# Test 15: Health-check active monitoring alert threshold triggers
test_health_check_threshold_alert() {
  local temp_dir="$SANDBOX/alert_test"
  mkdir -p "$temp_dir/config" "$temp_dir/cron" "$temp_dir/log"
  
  # Configure setup with 0% thresholds so it will always alert
  "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --disk-threshold 0 \
    --mem-threshold 0 \
    --webhook-url "http://example.com/alert-webhook" >/dev/null
    
  # Execute health-check.sh helper
  "$temp_dir/config/health-check.sh" >/dev/null 2>&1
  
  local log_file="$temp_dir/log/server.log"
  if [ ! -f "$log_file" ]; then
    echo "server.log not found after running health-check.sh" >&2
    return 1
  fi
  
  # Assert that alert messages are written to log file
  if ! grep -q "\[ALERT\]" "$log_file"; then
    echo "Alert message was not logged in server.log under 0% thresholds" >&2
    return 1
  fi
  
  # Also check if it logged the alert details for Disk or Memory
  if ! grep -q "Disk usage is at" "$log_file" && ! grep -q "Memory usage is at" "$log_file"; then
    echo "Specific resource alert description missing in server.log" >&2
    return 1
  fi
  
  return 0
}

# Test 16: Systemd service unit creation
test_systemd_service_creation() {
  local temp_dir="$SANDBOX/systemd_test"
  mkdir -p "$temp_dir/config" "$temp_dir/cron" "$temp_dir/log" "$temp_dir/systemd"
  
  "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --systemd-dir "$temp_dir/systemd" \
    --service-name "my-test-service" \
    --service-cmd "/usr/local/bin/dummy-cmd" \
    --service-user "test-user" >/dev/null
    
  local service_file="$temp_dir/systemd/my-test-service.service"
  if [ ! -f "$service_file" ]; then
    echo "Systemd service file was not generated" >&2
    return 1
  fi
  
  if ! grep -q "Description=Server Setup Custom Service - my-test-service" "$service_file"; then
    echo "Systemd service Description incorrect" >&2
    return 1
  fi
  if ! grep -q "ExecStart=/usr/local/bin/dummy-cmd" "$service_file"; then
    echo "Systemd service ExecStart incorrect" >&2
    return 1
  fi
  if ! grep -q "User=test-user" "$service_file"; then
    echo "Systemd service User incorrect" >&2
    return 1
  fi
  
  return 0
}

# Test 17: Service configuration fails if command is empty
test_systemd_empty_cmd_fails() {
  local temp_dir="$SANDBOX/systemd_fail_test"
  mkdir -p "$temp_dir/config" "$temp_dir/cron" "$temp_dir/log" "$temp_dir/systemd"
  
  if "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --systemd-dir "$temp_dir/systemd" \
    --service-name "my-test-service" >/dev/null 2>&1; then
    echo "Expected setup script to fail when service-name is set but service-cmd is empty" >&2
    return 1
  fi
  
  return 0
}

# Test 18: Custom cron schedule parameters written
test_cron_schedule_custom() {
  local temp_dir="$SANDBOX/cron_sched_test"
  mkdir -p "$temp_dir/config" "$temp_dir/cron" "$temp_dir/log"
  
  # Test shortcut mapping 'hourly'
  "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --cron-schedule "hourly" >/dev/null
    
  local cron_file="$temp_dir/cron/server-health-check"
  if [ ! -f "$cron_file" ]; then
    echo "Cron file not generated" >&2
    return 1
  fi
  
  if ! grep -q "0 \* \* \* \*" "$cron_file"; then
    echo "hourly shortcut did not map correctly" >&2
    return 1
  fi
  
  # Test custom 5-field expression
  "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --cron-schedule "1 2 3 4 5" >/dev/null
    
  if ! grep -q "1 2 3 4 5" "$cron_file"; then
    echo "Custom 5-field cron schedule was not written" >&2
    return 1
  fi
  
  return 0
}

# Test 19: Invalid cron schedules fail validation
test_cron_schedule_invalid_fails() {
  local temp_dir="$SANDBOX/cron_invalid_test"
  mkdir -p "$temp_dir/config" "$temp_dir/cron" "$temp_dir/log"
  
  # Attempt invalid schedule with only 4 fields
  if "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --cron-schedule "* * * *" >/dev/null 2>&1; then
    echo "Expected setup script to fail on 4-field cron schedule" >&2
    return 1
  fi
  
  # Attempt invalid shortcut
  if "$SETUP_SCRIPT" --skip-root-check \
    --config-dir "$temp_dir/config" \
    --cron-dir "$temp_dir/cron" \
    --log-dir "$temp_dir/log" \
    --cron-schedule "every-minute" >/dev/null 2>&1; then
    echo "Expected setup script to fail on invalid shortcut" >&2
    return 1
  fi
  
  return 0
}

# Clean up before running
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"

# Run tests
run_test "Help option" test_help_option
run_test "Invalid options fail" test_invalid_option
run_test "Dry run doesn't write" test_dry_run
run_test "Successful setup" test_successful_setup
run_test "Health check script execution" test_health_check_execution
run_test "Custom dependencies file" test_custom_dependencies_file
run_test "Missing dependencies file fails" test_missing_dependencies_file
run_test "Automatic rollback on failure" test_rollback_on_failure
run_test "Template configuration rendering" test_template_rendering
run_test "Missing template file fails" test_missing_template_file
run_test "Webhook dry-run notification" test_webhook_dry_run
run_test "Log level console output filtering" test_logging_filtering
run_test "Diagnostics archive creation on failure" test_diagnostics_archive_on_failure
run_test "Custom thresholds written to config" test_custom_thresholds_written
run_test "Health check threshold alert triggers" test_health_check_threshold_alert
run_test "Systemd service unit creation" test_systemd_service_creation
run_test "Systemd service empty command fails" test_systemd_empty_cmd_fails
run_test "Custom cron schedule parameter" test_cron_schedule_custom
run_test "Invalid cron schedules fail validation" test_cron_schedule_invalid_fails

# Clean up sandbox after tests pass
rm -rf "$SANDBOX"
echo "All tests passed successfully!"
