#!/bin/bash
# setup_server.sh - Server setup script
# Installs dependencies, configures environment, and sets up cron jobs.

set -euo pipefail

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
    *)
      echo "Error: Unknown option $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

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

cleanup_on_error() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ "$DRY_RUN" = "false" ]; then
    echo "Error occurred (exit code: $exit_code). Initiating rollback/cleanup..." >&2
    rollback_created_paths
  fi
}

trap cleanup_on_error EXIT

echo "=== Server Setup Started ==="
if [ "$DRY_RUN" = "true" ]; then
  echo "--- RUNNING IN DRY-RUN MODE ---"
fi

# Check for root privileges
if [ "$SKIP_ROOT_CHECK" = "false" ] && [ "$DRY_RUN" = "false" ]; then
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: This script must be run as root (or with sudo)." >&2
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
  echo "Installing dependencies: $DEPENDENCIES"
  
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would use package manager '$pm' to install: $DEPENDENCIES"
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
      echo "Warning: Unknown or unsupported package manager. Skipping dependency installation." >&2
      ;;
  esac
}

# Verify installed dependencies
verify_dependencies() {
  local pm
  pm=$(detect_package_manager)
  echo "Verifying installed dependencies..."

  local failed_deps=()

  for dep in $DEPENDENCIES; do
    if [ "$DRY_RUN" = "true" ]; then
      echo "[DRY RUN] Would verify package installation for: $dep"
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
      echo "  Verification PASSED: $dep is installed."
    else
      echo "  Verification FAILED: $dep is NOT installed/accessible." >&2
      failed_deps+=("$dep")
    fi
  done

  if [ ${#failed_deps[@]} -ne 0 ] && [ "$DRY_RUN" = "false" ]; then
    if [ "$pm" = "unknown" ]; then
      echo "Warning: Verification failed for [${failed_deps[*]}], but skipping enforcement because no package manager was detected." >&2
    else
      echo "Error: The following dependencies failed verification: ${failed_deps[*]}" >&2
      exit 1
    fi
  fi
}

# Configure environment
configure_environment() {
  echo "Configuring environment in $CONFIG_DIR..."
  
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would create directory: $CONFIG_DIR"
    if [ -n "$TEMPLATE_FILE" ]; then
      echo "[DRY RUN] Would render template file '$TEMPLATE_FILE' to: $CONFIG_DIR/env.conf"
    else
      echo "[DRY RUN] Would create environment file: $CONFIG_DIR/env.conf"
    fi
    echo "[DRY RUN] Would create log directory: $LOG_DIR"
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

      echo "$rendered_line" >> "$env_file"
    done < "$TEMPLATE_FILE"
  else
    cat <<EOF > "$env_file"
# Server Setup Environment Configuration
# Generated on $(date)
APP_ENV=production
LOG_PATH=$LOG_DIR/server.log
SYS_CHECK_INTERVAL=300
EOF
  fi

  # Set permissions
  chmod 755 "$CONFIG_DIR"
  chmod 644 "$env_file"
  chmod 755 "$LOG_DIR"
  
  echo "Environment configured successfully."
}

# Set up cron jobs
setup_cron_jobs() {
  echo "Setting up cron jobs in $CRON_DIR..."
  
  local health_script="$CONFIG_DIR/health-check.sh"
  
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would create health check script: $health_script"
    echo "[DRY RUN] Would create cron job entry in: $CRON_DIR/server-health-check"
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

echo "=== Server Setup Completed Successfully ==="
