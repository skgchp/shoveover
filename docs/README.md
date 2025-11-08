# ShoveOver

A robust, production-ready bash script for automated disk space management through intelligent cache directory cleanup.

## Overview

ShoveOver monitors disk space usage and automatically identifies and moves the oldest leaf directories (deepest folders with no subdirectories) to external storage when disk space falls below configurable thresholds. The full directory structure is preserved at the destination. The script is designed for production environments with comprehensive error handling, monitoring capabilities, and safety features.

## Features

### 🚀 Core Functionality
- **Automatic disk space monitoring** with configurable thresholds
- **Leaf directory detection** identifies folders with no subdirectories at any depth
- **Intelligent oldest-first directory selection** based on modification time
- **Path structure preservation** maintains full directory hierarchy at destination
- **Paired source-destination mapping** for organized file movement
- **Safe file movement** using rsync with verification and rollback capability
- **Process locking** to prevent multiple simultaneous executions
- **Comprehensive logging** with configurable verbosity levels
- **Performance optimized** with configurable search depth limits

### 🛡️ Safety & Reliability
- **Dry run mode** for testing without actual file operations
- **Minimum age requirements** to protect recently created directories
- **Transfer verification** before source deletion
- **Atomic operations** with proper cleanup on interruption
- **Maximum move limits** to prevent runaway cleanup operations

### 📊 Monitoring & Notifications
- **tmux session integration** for real-time monitoring
- **Email notifications** for both success and failure scenarios
- **Detailed logging** with timestamps and severity levels
- **Progress tracking** with moved directory counts and freed space

### 🧪 Production Ready
- **Comprehensive test suite** using Bats testing framework
- **Input validation** and configuration verification  
- **Error handling** with graceful degradation
- **Signal handling** for clean shutdown
- **Configurable behavior** through external configuration file

## Quick Start

### 1. Installation

```bash
# Clone or download the project
git clone <repository-url> shoveover
cd shoveover

# Install dependencies (Bats testing framework)
./scripts/install-deps.sh

# Make the script executable
chmod +x shoveover.sh
```

### 2. Configuration

Copy and edit the configuration file:

```bash
cp config/shoveover.conf.example config/shoveover-production.conf
```

Edit `config/shoveover-production.conf` with your specific paths and settings:

```bash
# Source-destination directory pairs
# Format: "source_path:destination_path"
SOURCE_DEST_PAIRS=(
    "/var/cache/application:/mnt/external-storage/application-cache"
    "/opt/data/temp-files:/mnt/external-storage/temp-files"
    "/srv/disk1/tv:/srv/disk2/tv"
    "/srv/disk1/films:/srv/disk2/films"
)

# Disk space thresholds (percentages)
LOW_SPACE_THRESHOLD=10    # Start cleanup when < 10% free
TARGET_SPACE_THRESHOLD=20 # Stop cleanup when >= 20% free

# Email notifications
EMAIL_ENABLED=true
EMAIL_RECIPIENT="admin@example.com"

# Safety settings
MAX_MOVES_PER_RUN=10  # Maximum directories to move per execution
MIN_AGE_DAYS=7        # Minimum age before directories can be moved
```

### 3. Test Configuration

```bash
# Validate configuration without running cleanup
./shoveover.sh --test --config config/shoveover-production.conf

# Run in dry-run mode to see what would be moved
./shoveover.sh --dry-run --config config/shoveover-production.conf --debug
```

### 4. Run ShoveOver

```bash
# Run normally
./shoveover.sh --config config/shoveover-production.conf

# Run with debug logging
./shoveover.sh --debug --config config/shoveover-production.conf

# Monitor progress in real-time
tmux attach-session -t shoveover-$(date +%Y%m%d-%H%M%S)
```

## Configuration Reference

### Source-Destination Pairs

ShoveOver uses a paired mapping approach where each source directory has a specific destination directory. Leaf directories (folders with no subdirectories) found within the source are moved to the destination, preserving their full relative path structure. This provides better organization and control over where moved files end up.

**Format**: `"source_path:destination_path"`

**Examples**:
```bash
SOURCE_DEST_PAIRS=(
    "/srv/disk1/tv:/srv/disk2/tv"              # TV shows: disk1 → disk2
    "/srv/disk1/films:/srv/disk2/films"        # Films: disk1 → disk2  
    "/var/cache/app1:/mnt/backup/app1-cache"   # App cache → backup drive
    "/tmp/processing:/archive/completed"       # Processing → archive
)
```

**Benefits**:
- **Organized storage**: Files maintain logical grouping in destinations
- **Multiple destinations**: Different source types can go to different locations
- **Flexible mapping**: One-to-one mapping allows fine-grained control
- **Clear intent**: Configuration clearly shows data flow

### Required Settings

| Setting | Description | Example |
|---------|-------------|---------|
| `SOURCE_DEST_PAIRS` | Array of source:destination pairs | `("/srv/tv:/backup/tv" "/srv/films:/backup/films")` |

### Threshold Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `LOW_SPACE_THRESHOLD` | Trigger cleanup when free space < this % | `10` |
| `TARGET_SPACE_THRESHOLD` | Stop cleanup when free space >= this % | `20` |

### Safety Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `MAX_MOVES_PER_RUN` | Maximum directories to move per execution | `10` |
| `MIN_AGE_DAYS` | Minimum age (days) before directories can be moved | `7` |
| `MAX_SEARCH_DEPTH` | Maximum depth to search for leaf directories (optional, empty = unlimited) | `""` |

### Notification Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `EMAIL_ENABLED` | Enable email notifications | `true` |
| `EMAIL_RECIPIENT` | Email address for notifications | `""` |

### System Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `TMUX_SESSION_NAME` | Name for monitoring session | `"shoveover"` |
| `LOG_LEVEL` | Logging verbosity (DEBUG/INFO/WARN/ERROR) | `"INFO"` |

## Leaf Directory Detection

ShoveOver uses intelligent leaf directory detection to identify the deepest folders with no subdirectories for migration. This ensures that complete, self-contained content units are moved rather than partially breaking up directory trees.

### How It Works

A **leaf directory** is defined as a directory that contains **no subdirectories** (it may contain files or be empty).

**Example Structure:**
```
/srv/ssd/Video/
├── tv/
│   ├── show1/
│   │   ├── season-1/         ← Leaf directory (files only)
│   │   └── season-2/         ← Leaf directory (files only)
│   └── show2/
│       └── season-1/         ← Leaf directory (files only)
└── films/
    ├── film-1/               ← Leaf directory (files only)
    └── film-2/               ← Leaf directory (files only)
```

**Leaf directories identified:** `season-1`, `season-2`, `season-1` (from show2), `film-1`, `film-2`
**Non-leaf directories (skipped):** `Video`, `tv`, `show1`, `show2`, `films`

### Path Preservation

When a leaf directory is moved, the full relative path from the source root is preserved:

```
Source:      /srv/ssd/Video/tv/show1/season-1
Destination: /srv/hdd/Video/tv/show1/season-1
             └─────────────┬────────────────┘
                  Preserved structure
```

### Performance Considerations

For very deep directory trees, you can limit the search depth using `MAX_SEARCH_DEPTH`:

```bash
# Limit search to 10 levels deep
MAX_SEARCH_DEPTH=10
```

This prevents excessive recursion on directory structures with hundreds of levels, improving performance while still finding most leaf directories.

### Age Calculation

Age is determined by the leaf directory's modification time (mtime), not the files within it. Only leaf directories older than `MIN_AGE_DAYS` are eligible for migration.

## Command Line Options

```bash
Usage: shoveover.sh [OPTIONS]

OPTIONS:
    -h, --help      Show help message
    -c, --config    Specify config file (default: config/shoveover.conf)
    -d, --debug     Enable debug logging
    -t, --test      Test mode (validate config and exit)
    --dry-run       Simulate moves without actually moving files

EXAMPLES:
    ./shoveover.sh                    # Run with default config
    ./shoveover.sh -d                 # Run with debug logging
    ./shoveover.sh -c custom.conf     # Run with custom config
    ./shoveover.sh -t                 # Test configuration only
    ./shoveover.sh --dry-run          # Simulate operations safely
```

## Monitoring

### Real-time Monitoring with tmux

ShoveOver creates a tmux session for real-time monitoring:

```bash
# Attach to the monitoring session (replace with actual session name)
tmux attach-session -t shoveover-20231107-143022

# List active sessions
tmux list-sessions | grep shoveover

# Detach from session (while keeping it running)
# Press Ctrl+B, then D
```

### Log Files

Logs are written to `shoveover.log` in the script directory:

```bash
# View recent log entries
tail -f shoveover.log

# Search for errors
grep ERROR shoveover.log

# View logs with timestamps
less shoveover.log
```

## Email Notifications

ShoveOver sends email notifications for:

- **Successful completion** with summary of moved directories
- **Error conditions** with detailed error context and recent log entries
- **No action required** when cleanup wasn't needed

### Email Setup

The script supports multiple email methods:

1. **msmtp** (recommended for production)
2. **mailx** (fallback option)
3. **sendmail** (system default)

Example msmtp configuration (`~/.msmtprc`):

```bash
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        default
host           smtp.gmail.com
port           587
from           your-email@gmail.com
user           your-email@gmail.com
password       your-app-password
```

## Testing

ShoveOver includes a comprehensive test suite using the Bats testing framework.

### Running Tests

```bash
# Run all tests
./tests/test-runner.sh

# Run specific test file
./tests/test-runner.sh tests/test-config.bats

# Run with verbose output
./tests/test-runner.sh --verbose

# Setup test environment only
./tests/test-runner.sh --setup-only

# Clean test environment
./tests/test-runner.sh --clean-only
```

### Test Categories

1. **Configuration Tests** (`test-config.bats`)
   - Configuration file parsing and validation
   - Command line argument handling
   - Directory permission checking

2. **Core Functionality Tests** (`test-cache-manager.bats`)
   - Process locking mechanisms
   - Disk space calculations
   - Directory age and size calculations
   - File movement operations
   - Error handling

3. **Integration Tests** (`test-integration.bats`)
   - End-to-end workflow testing
   - Multiple directory scenarios
   - Safety feature validation
   - Error condition handling

### Manual Testing

```bash
# Setup test environment
./scripts/setup-test-env.sh setup

# Test with mock data
./shoveover.sh --config tests/fixtures/test-config.conf --debug

# Cleanup test environment
./scripts/setup-test-env.sh clean
```

## Production Deployment

### 1. System Requirements

- Bash 4.0 or later
- `rsync` for file transfers
- `tmux` for monitoring (optional but recommended)
- Email command (`msmtp`, `mailx`, or `sendmail`)
- Standard Unix utilities: `find`, `du`, `stat`, `df`

### 2. Scheduled Execution

Add to crontab for automatic execution:

```bash
# Run every 4 hours
0 */4 * * * /opt/shoveover/shoveover.sh --config /opt/shoveover/config/production.conf

# Run daily at 2 AM with email on errors
0 2 * * * /opt/shoveover/shoveover.sh --config /opt/shoveover/config/production.conf 2>&1 | logger -t shoveover
```

### 3. Log Rotation

Configure log rotation to prevent log files from growing too large:

```bash
# Add to /etc/logrotate.d/shoveover
/opt/shoveover/shoveover.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    postrotate
        # Send HUP signal if needed
    endscript
}
```

### 4. Monitoring Integration

Integrate with system monitoring:

```bash
# Check script execution status
systemctl status shoveover.service

# Monitor log files
tail -f /var/log/syslog | grep shoveover

# Check disk space trends
df -h | grep "cache\|storage"
```

## Troubleshooting

### Common Issues

#### Permission Denied Errors
```bash
# Check directory permissions
ls -la /path/to/cache/dirs
ls -la /path/to/destination

# Fix permissions
chown -R cache-user:cache-group /path/to/cache
chmod -R 755 /path/to/cache
```

#### Lock File Issues
```bash
# Check for stale lock file
ls -la .running

# Remove stale lock (only if certain no other instance is running)
rm .running

# Check for running processes
pgrep -f cache-manager.sh
```

#### Email Delivery Issues
```bash
# Test email configuration
echo "Test message" | msmtp recipient@example.com

# Check email logs
tail -f ~/.msmtp.log
journalctl -u postfix
```

#### tmux Session Problems
```bash
# List all sessions
tmux list-sessions

# Force kill hanging session
tmux kill-session -t session-name

# Check tmux server status
tmux info
```

### Debug Mode

Enable debug logging for detailed troubleshooting:

```bash
# Run with debug output
./shoveover.sh --debug --config your-config.conf

# Check debug information in logs
grep DEBUG shoveover.log
```

### Dry Run Testing

Use dry run mode to test behavior without moving files:

```bash
# Use the --dry-run command line option
./shoveover.sh --dry-run --config config/production.conf --debug
```

## Security Considerations

- **File Permissions**: Ensure script runs with appropriate permissions
- **Path Validation**: All paths are validated before operations
- **Input Sanitization**: Configuration values are sanitized
- **Process Isolation**: Uses file locking to prevent conflicts
- **Safe Transfers**: Verifies transfers before removing source files
- **Error Containment**: Errors don't expose sensitive system information

## Performance

### Optimization Tips

1. **Use SSD for destination** when possible for faster transfers
2. **Adjust MAX_MOVES_PER_RUN** based on available bandwidth
3. **Schedule during off-peak hours** to minimize system impact
4. **Monitor rsync progress** through tmux session
5. **Use local destination** for temporary storage if external storage is slow

### Resource Usage

- **CPU**: Low impact, primarily during directory scanning
- **Memory**: Minimal, scales with number of directories
- **Disk I/O**: Moderate during transfer operations
- **Network**: None (designed for local filesystem operations)
