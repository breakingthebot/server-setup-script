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

# Clean up sandbox after tests pass
rm -rf "$SANDBOX"
echo "All tests passed successfully!"
