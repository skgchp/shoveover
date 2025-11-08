# ShoveOver

A robust, production-ready bash script for automated disk space management through intelligent migration between drives.

## Summary

Inspired by [mergerfs.percent-full-mover](https://raw.githubusercontent.com/trapexit/mergerfs/refs/heads/latest-release/tools/mergerfs.percent-full-mover), ShoveOver is designed for mergerfs storage arrays with solid state storage acting as a [tiered cache](https://trapexit.github.io/mergerfs/preview/extended_usage_patterns/). When scheduled to run, ShoveOver monitors free space on your SSD cache and automatically rsyncs the oldest leaf directories (deepest folders with no subdirectories, like `/Video/tv/show/season-1`) to a hard drive array, maintaining your configured free space threshold and keeping your fast storage ready for new writes. The full directory structure is preserved at the destination.

## AI disclaimer

This project was created with the assistance of generative AI.

## Features

- **Source-destination pairs**: Map each source directory to a specific destination
- **Intelligent cleanup**: Identifies and moves oldest leaf directories (folders with no subdirectories) at any depth
- **Path preservation**: Full directory structure is maintained at the destination (e.g., `/ssd/Video/tv/show/season-1` → `/hdd/Video/tv/show/season-1`)
- **Performance optimized**: Configurable search depth limit to handle large directory trees efficiently
- **Safety features**: Dry-run mode, minimum age requirements, process locking
- **Monitoring**: tmux integration and email notifications
- **Production ready**: Comprehensive error handling and logging

## Quick Start

1. **Copy configuration template**:
   ```bash
   cp config/shoveover.conf.example config/shoveover.conf
   ```

2. **Edit configuration** with your paths:
   ```bash
   SOURCE_DEST_PAIRS=(
       "/srv/disk1/tv:/srv/disk2/tv"
       "/srv/disk1/films:/srv/disk2/films"
   )
   ```

3. **Test configuration**:
   ```bash
   ./shoveover.sh --test --config config/shoveover.conf
   ```

4. **Run with dry-run first**:
   ```bash
   ./shoveover.sh --dry-run --config config/shoveover.conf
   ```

## Documentation

See [docs/README.md](docs/README.md) for comprehensive documentation including:
- Detailed configuration options
- Installation and setup instructions
- Production deployment guide
- Troubleshooting and monitoring

## Testing

```bash
# Install test dependencies
./scripts/install-deps.sh

# Setup test environment
./scripts/setup-test-env.sh

# Run tests
./tests/test-runner.sh
```
