# Server Setup Script

A robust, portable, and testable Bash script designed to automate initial server configurations, install essential dependencies, set up environment configuration files, and schedule periodic health checks using system cron jobs.

## Features

- **Dependency Installation**: Auto-detects the system's package manager (`apt`, `yum`, `dnf`, `pacman`) and installs a list of default or custom packages.
- **Dependency Verification**: Performs post-installation checks to verify that every requested dependency is correctly installed on the system using package manager checks (e.g. `dpkg`, `rpm`, `pacman`) or executable availability.
- **Environment Configuration**: Generates an environment configuration file (`env.conf`) with configuration parameters like log paths and environment modes.
- **Configuration Templating**: Compiles custom configuration template files containing `{{KEY}}` placeholders, supporting direct variable overrides and automatic environment path fallbacks.
- **Cron Jobs**: Configures a system-wide cron job (`server-health-check`) that triggers a system health check helper script periodically.
- **Test Mode & Safety**: Supports a `--dry-run` mode to inspect actions before applying them, and `--skip-root-check` to support running/testing in non-privileged environments.
- **Custom Directories**: Supports custom paths for config, cron, and log directories.
- **Automatic Fail-Safe Rollback**: Tracks all files and directories created during the script's run. If setup encounters any error and exits with a non-zero code, it automatically deletes created files and removes created directories (if empty) to leave the server in a clean state.
- **Webhook Status Notifications**: Dispatches real-time setup outcomes (`SUCCESS` or `FAILURE`) along with run duration and server hostname to a target Slack, Discord, or generic webhook endpoint.

## Usage

Run the script as root/sudo on target servers:

```bash
sudo ./setup_server.sh
```

### Options

```
Usage: setup_server.sh [OPTIONS]

Options:
  -h, --help                  Show this help message and exit
  -d, --dry-run               Show what actions would be taken without making changes
  -s, --skip-root-check       Skip checking if script is run as root/sudo
  -c, --config-dir DIR        Override configuration directory (default: /etc/server-setup)
      --cron-dir DIR          Override cron configuration directory (default: /etc/cron.d)
      --log-dir DIR           Override log directory (default: /var/log/server-setup)
      --dependencies LIST     Space-separated list of dependencies to install
  -f, --dependencies-file FILE File containing list of packages to install (one per line)
  -t, --template FILE         Path to configuration template file
      --template-vars STR     Space-separated KEY=VAL overrides for template
  -w, --webhook-url URL       Webhook URL for status notifications
```

## Local Development & Testing

You can run the automated tests locally using MSYS, Git Bash, or any Linux shell:

```bash
bash ./tests/test_setup.sh
```

## License

This project is licensed under the [MIT License](LICENSE).
