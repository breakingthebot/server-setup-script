#!/bin/bash
# setup_server.sh - Server setup script
# Installs dependencies, configures environment, and sets up cron jobs.

set -euo pipefail

# Start time tracking
START_TIME=$(date +%s)

# Default configuration values
DRY_RUN=false
SKIP_ROOT_CHECK=false
CONFIG_DIR="/etc/server-setup"
CRON_DIR="/etc/cron.d"
LOG_DIR="/var/log/server-setup"
DEPENDENCIES="curl git htop cron"
DEPENDENCIES_FILE=""
TEMPLATE_FILE=""
TEMPLATE_VARS=""
WEBHOOK_URL=""
LOG_LEVEL="INFO"
ALERT_DISK_THRESHOLD=90
ALERT_MEM_THRESHOLD=90

# Display usage information
show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help                  Show this help message and exit
  -d, --dry-run               Show what actions would be taken without making changes
  -s, --skip-root-check       Skip checking if script is run as root/sudo
  -c, --config-dir DIR        Override configuration directory (default: $CONFIG_DIR)
      --cron-dir DIR          Override cron configuration directory (default: $CRON_DIR)
      --log-dir DIR           Override log directory (default: $LOG_DIR)
      --dependencies LIST     Space-separated list of dependencies to install
  -f, --dependencies-file FILE File containing list of packages to install (one per line)
  -t, --template FILE         Path to configuration template file
      --template-vars STR     Space-separated KEY=VAL overrides for template
  -w, --webhook-url URL       Webhook URL for status notifications
  -l, --log-level LEVEL       Log level: DEBUG, INFO, WARN, ERROR (default: INFO)
      --disk-threshold PCT    Disk usage alert threshold percentage (default: 90)
      --mem-threshold PCT     Memory usage alert threshold percentage (default: 90)
EOF
}

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -s|--skip-root-check)
      SKIP_ROOT_CHECK=true
      shift
      ;;
    -c|--config-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --config-dir requires an argument." >&2
        exit 1
      fi
      CONFIG_DIR="$2"
      shift 2
      ;;
    --cron-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --cron-dir requires an argument." >&2
        exit 1
      fi
      CRON_DIR="$2"
      shift 2
      ;;
    --log-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --log-dir requires an argument." >&2
        exit 1
      fi
      LOG_DIR="$2"
      shift 2
      ;;
    --dependencies)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --dependencies requires an argument." >&2
        exit 1
      fi
      DEPENDENCIES="$2"
      shift 2
      ;;
    -f|--dependencies-file)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --dependencies-file requires an argument." >&2
        exit 1
      fi
      DEPENDENCIES_FILE="$2"
      shift 2
      ;;
    -t|--template)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --template requires an argument." >&2
        exit 1
      fi
      TEMPLATE_FILE="$2"
      shift 2
      ;;
    --template-vars)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --template-vars requires an argument." >&2
        exit 1
      fi
      TEMPLATE_VARS="$2"
      shift 2
      ;;
    -w|--webhook-url)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --webhook-url requires an argument." >&2
        exit 1
      fi
      WEBHOOK_URL="$2"
      shift 2
      ;;
    -l|--log-level)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --log-level requires an argument." >&2
        exit 1
      fi
      LOG_LEVEL="$2"
      shift 2
      ;;
    --disk-threshold)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --disk-threshold requires an argument." >&2
        exit 1
      fi
      ALERT_DISK_THRESHOLD="$2"
      shift 2
      ;;
    --mem-threshold)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --mem-threshold requires an argument." >&2
        exit 1
      fi
      ALERT_MEM_THRESHOLD="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

# Initialize log level number
LOG_LEVEL_NUM=1
set_log_level() {
  local lvl
  lvl=$(echo "${LOG_LEVEL:-INFO}" | tr '[:lower:]' '[:upper:]')
  case "$lvl" in
    DEBUG) LOG_LEVEL_NUM=0 ;;
    INFO)  LOG_LEVEL_NUM=1 ;;
    WARN|WARNING)  LOG_LEVEL_NUM=2 ;;
    ERROR) LOG_LEVEL_NUM=3 ;;
    *)
      echo "Warning: Unknown log level '$LOG_LEVEL'. Defaulting to INFO." >&2
      LOG_LEVEL_NUM=1
      ;;
  esac
}
set_log_level

# Logging utility functions
log_debug() { [ "$LOG_LEVEL_NUM" -le 0 ] && echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_info() {  [ "$LOG_LEVEL_NUM" -le 1 ] && echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() {  [ "$LOG_LEVEL_NUM" -le 2 ] && echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_error() { [ "$LOG_LEVEL_NUM" -le 3 ] && echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

export_diagnostics() {
  local exit_code="$1"
  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)
  local archive_name="setup-diagnostics-${timestamp}.tar.gz"
  
  # Put archive in target folder parent or current directory
  local archive_path="./$archive_name"
  local parent_dir
  parent_dir=$(dirname "$CONFIG_DIR" 2>/dev/null || echo ".")
  if [ -d "$parent_dir" ] && [ -w "$parent_dir" ] && [ "$parent_dir" != "/" ]; then
    archive_path="$parent_dir/$archive_name"
  fi
  
  log_info "Exporting failure diagnostics to: $archive_path"
  
  local diag_dir
  diag_dir=$(mktemp -d -t setup-diag-XXXXXX 2>/dev/null || mktemp -d ./setup-diag-XXXXXX)
  
  {
    echo "=== Setup Fail-Safe Diagnostic Report ==="
    echo "Timestamp: $(date)"
    echo "Exit Code: $exit_code"
    echo "Hostname: $(hostname 2>/dev/null || echo "unknown")"
    echo "OS details: $(uname -a 2>/dev/null || echo "unknown")"
    echo "EUID: ${EUID:-$(id -u)}"
    echo "Disk usage:"
    df -h 2>/dev/null || df -h .
    echo "Memory details:"
    free -m 2>/dev/null || echo "free not available"
  } > "$diag_dir/system-info.txt"
  
  if [ -d "$CONFIG_DIR" ]; then
    cp -rp "$CONFIG_DIR" "$diag_dir/config" 2>/dev/null || true
  fi
  if [ -d "$LOG_DIR" ]; then
    cp -rp "$LOG_DIR" "$diag_dir/log" 2>/dev/null || true
  fi
  
  # Compress it
  if tar -czf "$archive_path" -C "$(dirname "$diag_dir")" "$(basename "$diag_dir")" &>/dev/null; then
    log_info "Diagnostics packaged successfully (compressed)."
  elif tar -cf "${archive_path%.gz}" -C "$(dirname "$diag_dir")" "$(basename "$diag_dir")" &>/dev/null; then
    log_info "Diagnostics packaged successfully (uncompressed tar)."
    archive_path="${archive_path%.gz}"
  else
    log_warn "Failed to package diagnostics."
  fi
  
  rm -rf "$diag_dir"
}

# Read dependencies file if provided
if [ -n "$DEPENDENCIES_FILE" ]; then
  if [ ! -f "$DEPENDENCIES_FILE" ]; then
    echo "Error: Dependencies file '$DEPENDENCIES_FILE' not found." >&2
    exit 1
  fi
  # Read non-empty lines, ignoring comments
  DEPENDENCIES=$(grep -v '^[[:space:]]*#' "$DEPENDENCIES_FILE" | grep -v '^[[:space:]]*$' | tr '\n' ' ')
  DEPENDENCIES=$(echo "$DEPENDENCIES" | xargs)
fi

# Verify template file if provided
if [ -n "$TEMPLATE_FILE" ]; then
  if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file '$TEMPLATE_FILE' not found." >&2
    exit 1
  fi
fi

# Keep track of directories and files created by this run for rollback
CREATED_PATHS=()

record_created_path() {
  local path="$1"
  CREATED_PATHS=("$path" "${CREATED_PATHS[@]}")
}

rollback_created_paths() {
  echo "Rolling back configuration changes..." >&2
  for path in "${CREATED_PATHS[@]}"; do
    if [ -f "$path" ]; then
      echo "  Removing created file: $path" >&2
      rm -f "$path"
    elif [ -d "$path" ]; then
      # Only remove directory if it is empty to avoid deleting user files
      if [ -z "$(ls -A "$path" 2>/dev/null)" ]; then
        echo "  Removing empty directory: $path" >&2
        rmdir "$path"
      else
        echo "  Skipping non-empty directory: $path" >&2
      fi
    fi
  done
}

send_webhook_notification() {
  local status="$1"
  local message="$2"
  
  if [ -z "${WEBHOOK_URL:-}" ]; then
    return 0
  fi
  
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - START_TIME))
  
  local host
  host=$(hostname 2>/dev/null || echo "unknown-host")
  
  local payload
  payload=$(cat <<EOF
{
  "text": "=== Server Setup Notification ===\\n**Status**: $status\\n**Host**: $host\\n**Duration**: ${duration}s\\n**Details**: $message"
}
EOF
)

  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would send POST request to $WEBHOOK_URL with payload:"
    echo "$payload"
    return 0
  fi
  
  echo "Sending status notification to Webhook..."
  if command -v curl &>/dev/null; then
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" --max-time 10 "$WEBHOOK_URL" &>/dev/null || echo "Warning: Failed to send webhook notification." >&2
  else
    echo "Warning: curl not found. Cannot send webhook notification." >&2
  fi
}

cleanup_on_error() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ "$DRY_RUN" = "false" ]; then
    log_error "Error occurred (exit code: $exit_code). Initiating diagnostics and cleanup..."
    export_diagnostics "$exit_code"
    rollback_created_paths
    send_webhook_notification "FAILURE" "Server setup failed with exit code $exit_code. Diagnostics exported. Configuration changes rolled back."
  fi
}

trap cleanup_on_error EXIT

log_info "=== Server Setup Started ==="
if [ "$DRY_RUN" = "true" ]; then
  log_info "--- RUNNING IN DRY-RUN MODE ---"
fi

# Check for root privileges
if [ "$SKIP_ROOT_CHECK" = "false" ] && [ "$DRY_RUN" = "false" ]; then
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "This script must be run as root (or with sudo)."
    exit 1
  fi
fi

# Detect package manager
detect_package_manager() {
  if command -v apt-get &>/dev/null; then
    echo "apt"
  elif command -v yum &>/dev/null; then
    echo "yum"
  elif command -v dnf &>/dev/null; then
    echo "dnf"
  elif command -v pacman &>/dev/null; then
    echo "pacman"
  else
    echo "unknown"
  fi
}

# Install dependencies
install_dependencies() {
  local pm
  pm=$(detect_package_manager)
  log_info "Installing dependencies: $DEPENDENCIES"
  
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY RUN] Would use package manager '$pm' to install: $DEPENDENCIES"
    return 0
  fi

  case "$pm" in
    apt)
      apt-get update -y
      for dep in $DEPENDENCIES; do
        apt-get install -y "$dep"
      done
      ;;
    yum)
      for dep in $DEPENDENCIES; do
        yum install -y "$dep"
      done
      ;;
    dnf)
      for dep in $DEPENDENCIES; do
        dnf install -y "$dep"
      done
      ;;
    pacman)
      for dep in $DEPENDENCIES; do
        pacman -S --noconfirm "$dep"
      done
      ;;
    *)
      log_warn "Unknown or unsupported package manager. Skipping dependency installation."
      ;;
  esac
}

# Verify installed dependencies
verify_dependencies() {
  local pm
  pm=$(detect_package_manager)
  log_info "Verifying installed dependencies..."

  local failed_deps=()

  for dep in $DEPENDENCIES; do
    if [ "$DRY_RUN" = "true" ]; then
      log_info "[DRY RUN] Would verify package installation for: $dep"
      continue
    fi

    # Perform package manager specific check or command fallback
    local is_installed=false
    case "$pm" in
      apt)
        if dpkg -s "$dep" &>/dev/null; then
          is_installed=true
        fi
        ;;
      yum|dnf)
        if rpm -q "$dep" &>/dev/null; then
          is_installed=true
        fi
        ;;
      pacman)
        if pacman -Q "$dep" &>/dev/null; then
          is_installed=true
        fi
        ;;
    esac

    # Fallback to checking if the command is executable if package manager check failed or is unknown
    if [ "$is_installed" = "false" ]; then
      if command -v "$dep" &>/dev/null; then
        is_installed=true
      fi
    fi

    if [ "$is_installed" = "true" ]; then
      log_info "  Verification PASSED: $dep is installed."
    else
      log_warn "  Verification FAILED: $dep is NOT installed/accessible."
      failed_deps+=("$dep")
    fi
  done

  if [ ${#failed_deps[@]} -ne 0 ] && [ "$DRY_RUN" = "false" ]; then
    if [ "$pm" = "unknown" ]; then
      log_warn "Verification failed for [${failed_deps[*]}], but skipping enforcement because no package manager was detected."
    else
      log_error "The following dependencies failed verification: ${failed_deps[*]}"
      exit 1
    fi
  fi
}

# Configure environment
configure_environment() {
  log_info "Configuring environment in $CONFIG_DIR..."
  
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY RUN] Would create directory: $CONFIG_DIR"
    if [ -n "$TEMPLATE_FILE" ]; then
      log_info "[DRY RUN] Would render template file '$TEMPLATE_FILE' to: $CONFIG_DIR/env.conf"
    else
      log_info "[DRY RUN] Would create environment file: $CONFIG_DIR/env.conf"
    fi
    log_info "[DRY RUN] Would create log directory: $LOG_DIR"
    return 0
  fi

  # Create directories
  if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    record_created_path "$CONFIG_DIR"
  fi
  if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    record_created_path "$LOG_DIR"
  fi

  # Generate environment file
  local env_file="$CONFIG_DIR/env.conf"
  if [ ! -f "$env_file" ]; then
    record_created_path "$env_file"
  fi

  if [ -n "$TEMPLATE_FILE" ]; then
    echo "Rendering template '$TEMPLATE_FILE'..."
    
    # Process overrides from TEMPLATE_VARS
    local vars_list=()
    for pair in $TEMPLATE_VARS; do
      vars_list+=("$pair")
    done

    # Truncate/create env_file
    > "$env_file"

    while IFS= read -r line || [[ -n "$line" ]]; do
      local rendered_line="$line"
      
      # Replace key=value overrides
      for pair in "${vars_list[@]:-}"; do
        if [ -n "$pair" ]; then
          local key="${pair%%=*}"
          local val="${pair#*=}"
          rendered_line="${rendered_line//\{\{$key\}\}/$val}"
        fi
      done
      
      # Fallback defaults for standard setup variables
      rendered_line="${rendered_line//\{\{APP_ENV\}\}/${APP_ENV:-production}}"
      rendered_line="${rendered_line//\{\{LOG_PATH\}\}/${LOG_PATH:-$LOG_DIR/server.log}}"
      rendered_line="${rendered_line//\{\{SYS_CHECK_INTERVAL\}\}/${SYS_CHECK_INTERVAL:-300}}"
      rendered_line="${rendered_line//\{\{CONFIG_DIR\}\}/$CONFIG_DIR}"
      rendered_line="${rendered_line//\{\{LOG_DIR\}\}/$LOG_DIR}"
      rendered_line="${rendered_line//\{\{WEBHOOK_URL\}\}/${WEBHOOK_URL:-}}"
      rendered_line="${rendered_line//\{\{ALERT_DISK_THRESHOLD\}\}/${ALERT_DISK_THRESHOLD:-90}}"
      rendered_line="${rendered_line//\{\{ALERT_MEM_THRESHOLD\}\}/${ALERT_MEM_THRESHOLD:-90}}"

      echo "$rendered_line" >> "$env_file"
    done < "$TEMPLATE_FILE"
  else
    cat <<EOF > "$env_file"
# Server Setup Environment Configuration
# Generated on $(date)
APP_ENV=production
LOG_PATH=$LOG_DIR/server.log
SYS_CHECK_INTERVAL=300
WEBHOOK_URL=$WEBHOOK_URL
ALERT_DISK_THRESHOLD=$ALERT_DISK_THRESHOLD
ALERT_MEM_THRESHOLD=$ALERT_MEM_THRESHOLD
EOF
  fi

  # Set permissions
  chmod 755 "$CONFIG_DIR"
  chmod 644 "$env_file"
  chmod 755 "$LOG_DIR"
  
  log_info "Environment configured successfully."
}

# Set up cron jobs
setup_cron_jobs() {
  log_info "Setting up cron jobs in $CRON_DIR..."
  
  local health_script="$CONFIG_DIR/health-check.sh"
  
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY RUN] Would create health check script: $health_script"
    log_info "[DRY RUN] Would create cron job entry in: $CRON_DIR/server-health-check"
    return 0
  fi

  # Create the health check helper script
  if [ ! -f "$health_script" ]; then
    record_created_path "$health_script"
  fi

  cat <<'EOF' > "$health_script"
#!/bin/bash
# Server Health Check Script
# Automatically generated by setup_server.sh

# Load environment configuration if available
CONFIG_FILE="$(dirname "$0")/env.conf"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Set default log path if not defined in env.conf
LOG_PATH="${LOG_PATH:-/var/log/server-setup/server.log}"
LOG_DIR="$(dirname "$LOG_PATH")"

mkdir -p "$LOG_DIR"

# Helper for triggering threshold alerts
trigger_alert() {
  local type="$1"
  local details="$2"
  
  echo "[ALERT] [$type] $details" >&2
  
  if [ -n "${WEBHOOK_URL:-}" ]; then
    local host
    host=$(hostname 2>/dev/null || echo "unknown-host")
    local payload
    payload=$(cat <<INNER_EOF
{
  "text": "=== Server Alert: $type ===\\n**Host**: $host\\n**Details**: $details"
}
INNER_EOF
)
    if command -v curl &>/dev/null; then
      # Run in background to avoid blocking cron
      curl -s -X POST -H "Content-Type: application/json" -d "$payload" --max-time 10 "$WEBHOOK_URL" &>/dev/null &
    fi
  fi
}

{
  echo "=== Health Check: $(date) ==="
  echo "Uptime:"
  if command -v uptime &>/dev/null; then
    uptime
  else
    echo "  (uptime command not available)"
  fi
  echo "Memory usage:"
  if command -v free &>/dev/null; then
    free -m
  else
    echo "  (free command not available)"
  fi
  echo "Disk usage:"
  df -h / 2>/dev/null || df -h .
  echo "================================="
  echo ""
} >> "$LOG_PATH"

# Perform active resource monitoring checks
# 1. Disk usage threshold alert
disk_pct=""
if command -v df &>/dev/null; then
  disk_pct=$(df -h / 2>/dev/null || df -h .)
  disk_pct=$(echo "$disk_pct" | tail -n 1 | grep -o -E '[0-9]+%' | tr -d '%')
fi

ALERT_DISK_THRESHOLD="${ALERT_DISK_THRESHOLD:-90}"
if [ -n "$disk_pct" ] && [ "$disk_pct" -gt "$ALERT_DISK_THRESHOLD" ]; then
  msg="Disk usage is at ${disk_pct}% (threshold: ${ALERT_DISK_THRESHOLD}%)"
  echo "[ALERT] $(date '+%Y-%m-%d %H:%M:%S') - $msg" >> "$LOG_PATH"
  trigger_alert "DISK" "$msg"
fi

# 2. Memory usage threshold alert
mem_total=""
mem_used=""
if command -v free &>/dev/null; then
  mem_total=$(free -m | grep Mem: | awk '{print $2}')
  mem_used=$(free -m | grep Mem: | awk '{print $3}')
fi

ALERT_MEM_THRESHOLD="${ALERT_MEM_THRESHOLD:-90}"
if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
  mem_pct=$((mem_used * 100 / mem_total))
  if [ "$mem_pct" -gt "$ALERT_MEM_THRESHOLD" ]; then
    msg="Memory usage is at ${mem_pct}% (threshold: ${ALERT_MEM_THRESHOLD}%)"
    echo "[ALERT] $(date '+%Y-%m-%d %H:%M:%S') - $msg" >> "$LOG_PATH"
    trigger_alert "MEM" "$msg"
  fi
fi
EOF

  chmod +x "$health_script"

  # Write the cron job file (system-wide cron format expects a user)
  if [ ! -d "$CRON_DIR" ]; then
    mkdir -p "$CRON_DIR"
    record_created_path "$CRON_DIR"
  fi

  local cron_file="$CRON_DIR/server-health-check"
  if [ ! -f "$cron_file" ]; then
    record_created_path "$cron_file"
  fi

  cat <<EOF > "$cron_file"
# Server health check cron job
# Runs every 5 minutes to log system statistics
*/5 * * * * root /bin/bash "$health_script"
EOF

  chmod 644 "$cron_file"
  
  echo "Cron jobs set up successfully."
}

# Run tasks
install_dependencies
verify_dependencies
configure_environment
setup_cron_jobs

send_webhook_notification "SUCCESS" "Server setup completed successfully. Configured environment in $CONFIG_DIR and cron jobs in $CRON_DIR."

log_info "=== Server Setup Completed Successfully ==="
