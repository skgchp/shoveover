#!/usr/bin/env bats

# Main ShoveOver functionality tests

setup() {
    TEST_DIR="$(dirname "$BATS_TEST_FILENAME")"
    PROJECT_ROOT="$(dirname "$TEST_DIR")"
    SHOVEOVER="$PROJECT_ROOT/shoveover.sh"

    # Setup test environment
    TEST_WORK_DIR="$TEST_DIR/tmp-work"
    mkdir -p "$TEST_WORK_DIR"/{source1,source2,destination}

    # Set globals before sourcing (so script can use defaults)
    export LOCK_FILE="$TEST_WORK_DIR/.running"
    export LOG_FILE="$TEST_WORK_DIR/test.log"

    # Source the script for testing individual functions
    source "$SHOVEOVER"
}

teardown() {
    # Cleanup
    if [[ -d "$TEST_WORK_DIR" ]]; then
        rm -rf "$TEST_WORK_DIR"
    fi
    
    # Kill any test tmux sessions
    tmux kill-session -t "test-session" 2>/dev/null || true
}

@test "process locking: multiple instances should be prevented" {
    # Create a lock file manually with the current process PID (which is running)
    echo "$$" > "$LOCK_FILE"

    run check_lock
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Another instance is already running" ]]
}

@test "process locking: single instance should acquire lock successfully" {
    run check_lock
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Acquired process lock" ]]
    [ -f "$LOCK_FILE" ]
}

@test "process locking: stale lock should be detected and cleaned up" {
    # Start a background sleep process to use as the "hung" process
    sleep 300 &
    local bg_pid=$!

    # Create a lock file with the background process PID
    echo "$bg_pid" > "$LOCK_FILE"

    # Age the lock file to simulate stale process (8 hours old)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-8H '+%Y%m%d%H%M.%S')" "$LOCK_FILE"
    else
        touch -d "8 hours ago" "$LOCK_FILE"
    fi

    # Set a short timeout for testing (1 hour = 3600s)
    STALE_LOCK_TIMEOUT=3600

    # check_lock should detect stale lock, kill process, and acquire new lock
    run check_lock
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Detected stale process" ]]
    [[ "$output" =~ "Acquired process lock" ]]

    # Verify the background process was killed
    ! kill -0 "$bg_pid" 2>/dev/null
}

@test "process locking: fresh lock should not be killed" {
    # Create a lock file with current PID
    echo "$$" > "$LOCK_FILE"

    # Lock file is fresh (just created)
    # Set timeout to 1 hour
    STALE_LOCK_TIMEOUT=3600

    # check_lock should detect running process with fresh lock and fail
    run check_lock
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Another instance is already running" ]]
    [[ "$output" =~ "last heartbeat" ]]
}

@test "process locking: stale lock with dead process should be removed" {
    # Create a lock file with a PID that doesn't exist
    echo "999999" > "$LOCK_FILE"

    # Age doesn't matter since process is dead
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-8H '+%Y%m%d%H%M.%S')" "$LOCK_FILE"
    else
        touch -d "8 hours ago" "$LOCK_FILE"
    fi

    run check_lock
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Removing stale lock file" ]]
    [[ "$output" =~ "Acquired process lock" ]]
}

@test "process locking: timeout threshold should be respected" {
    # Create a lock file with current PID
    echo "$$" > "$LOCK_FILE"

    # Age the lock to just under threshold (1 hour 50 minutes)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-110M '+%Y%m%d%H%M.%S')" "$LOCK_FILE"
    else
        touch -d "110 minutes ago" "$LOCK_FILE"
    fi

    # Set timeout to 2 hours (7200s)
    STALE_LOCK_TIMEOUT=7200

    # Lock is old but not past threshold - should not be killed
    run check_lock
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Another instance is already running" ]]
}

@test "process locking: default timeout should be used if not set" {
    # Start a background sleep process
    sleep 300 &
    local bg_pid=$!

    # Create a lock file with background process PID
    echo "$bg_pid" > "$LOCK_FILE"

    # Age the lock file well beyond default (10 hours)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-10H '+%Y%m%d%H%M.%S')" "$LOCK_FILE"
    else
        touch -d "10 hours ago" "$LOCK_FILE"
    fi

    # Don't set STALE_LOCK_TIMEOUT - should use default (7200s = 2 hours)
    unset STALE_LOCK_TIMEOUT

    # Should detect as stale (10 hours > 2 hours default)
    run check_lock
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Detected stale process" ]]

    # Cleanup background process if it survived
    kill "$bg_pid" 2>/dev/null || true
}

@test "disk space calculation: get_disk_usage_percent should return valid percentage" {
    run get_disk_usage_percent "/tmp"
    [ "$status" -eq 0 ]
    # Output should be a number between 0 and 100
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 0 ]
    [ "$output" -le 100 ]
}

@test "disk space calculation: get_free_space_percent should return valid percentage" {
    run get_free_space_percent "/tmp"
    [ "$status" -eq 0 ]
    # Output should be a number between 0 and 100
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 0 ]
    [ "$output" -le 100 ]
}

@test "directory age calculation: get_dir_age_days should return valid age" {
    # Create a test directory
    local test_dir="$TEST_WORK_DIR/age-test"
    mkdir -p "$test_dir"

    # Touch it to set a known modification time (1 day ago)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-1d '+%Y%m%d%H%M.%S')" "$test_dir"
    else
        touch -d "1 day ago" "$test_dir"
    fi

    run get_dir_age_days "$test_dir"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    # Should be approximately 1 day (allowing for minor timing differences)
    [ "$output" -ge 0 ]
    [ "$output" -le 2 ]
}

@test "directory size calculation: get_dir_size should return size in MB" {
    # Create a test directory with some content
    local test_dir="$TEST_WORK_DIR/size-test"
    mkdir -p "$test_dir"
    
    # Create a file with known size (approximately 1KB)
    head -c 1024 /dev/zero > "$test_dir/test-file.dat"
    
    run get_dir_size "$test_dir"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    # Should be at least 0 MB (rounds down for small files)
    [ "$output" -ge 0 ]
}

@test "find oldest subdirectory: should find the oldest directory" {
    # Create test directories with different ages
    local source_dir="$TEST_WORK_DIR/source1"
    SOURCE_DIRS=("$source_dir")
    DEST_DIRS=("$TEST_WORK_DIR/destination")
    MIN_AGE_DAYS=0  # Allow any age for testing
    
    mkdir -p "$source_dir/new_dir"
    mkdir -p "$source_dir/old_dir"
    
    # Set different modification times
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-1d '+%Y%m%d%H%M.%S')" "$source_dir/old_dir"
        touch -t "$(date -v-1H '+%Y%m%d%H%M.%S')" "$source_dir/new_dir"
    else
        touch -d "1 day ago" "$source_dir/old_dir"
        touch -d "1 hour ago" "$source_dir/new_dir"
    fi
    
    run find_oldest_subdir
    [ "$status" -eq 0 ]
    [[ "$output" = "$source_dir/old_dir" ]]
}

@test "find oldest subdirectory: should skip directories younger than MIN_AGE_DAYS" {
    local source_dir="$TEST_WORK_DIR/source1"
    SOURCE_DIRS=("$source_dir")
    DEST_DIRS=("$TEST_WORK_DIR/destination")
    MIN_AGE_DAYS=30  # Require 30 days minimum age
    
    mkdir -p "$source_dir/recent_dir"
    # Use different touch syntax for macOS vs Linux
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-1d '+%Y%m%d%H%M.%S')" "$source_dir/recent_dir"
    else
        touch -d "1 day ago" "$source_dir/recent_dir"
    fi
    
    run find_oldest_subdir
    [ "$status" -eq 0 ]
    [ -z "$output" ]  # Should return empty string (no directories old enough)
}

@test "find oldest subdirectory: should skip hidden directories" {
    local source_dir="$TEST_WORK_DIR/source1"
    SOURCE_DIRS=("$source_dir")
    DEST_DIRS=("$TEST_WORK_DIR/destination")
    MIN_AGE_DAYS=0

    mkdir -p "$source_dir/.hidden_dir"
    mkdir -p "$source_dir/visible_dir"

    # Make hidden directory older
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-2d '+%Y%m%d%H%M.%S')" "$source_dir/.hidden_dir"
        touch -t "$(date -v-1d '+%Y%m%d%H%M.%S')" "$source_dir/visible_dir"
    else
        touch -d "2 days ago" "$source_dir/.hidden_dir"
        touch -d "1 day ago" "$source_dir/visible_dir"
    fi

    run find_oldest_subdir
    [ "$status" -eq 0 ]
    [[ "$output" = "$source_dir/visible_dir" ]]
}

@test "find oldest subdirectory: should not follow symlinks" {
    local source_dir="$TEST_WORK_DIR/source1"
    SOURCE_DIRS=("$source_dir")
    DEST_DIRS=("$TEST_WORK_DIR/destination")
    MIN_AGE_DAYS=0

    # Create a real directory and a symlink to another location
    mkdir -p "$source_dir/real_dir"
    mkdir -p "$TEST_WORK_DIR/external_target/data"
    ln -s "$TEST_WORK_DIR/external_target" "$source_dir/symlink_dir"

    # Make the symlinked directory older
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-10d '+%Y%m%d%H%M.%S')" "$TEST_WORK_DIR/external_target"
        touch -t "$(date -v-1d '+%Y%m%d%H%M.%S')" "$source_dir/real_dir"
    else
        touch -d "10 days ago" "$TEST_WORK_DIR/external_target"
        touch -d "1 day ago" "$source_dir/real_dir"
    fi

    # Should only find real_dir, not follow symlink
    run find_oldest_subdir
    [ "$status" -eq 0 ]
    [[ "$output" = "$source_dir/real_dir" ]]
    # Verify symlink target was not considered
    [[ ! "$output" =~ "external_target" ]]
}

@test "transfer verification: verify_transfer should pass for identical directories" {
    # Create source and destination with identical content
    local source="$TEST_WORK_DIR/verify-source"
    local destination="$TEST_WORK_DIR/verify-dest"

    mkdir -p "$source" "$destination"
    echo "test content" > "$source/test.txt"
    echo "test content" > "$destination/test.txt"

    # Set debug level to see verification messages
    LOG_LEVEL="DEBUG"
    run verify_transfer "$source" "$destination"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}

@test "transfer verification: verify_transfer should fail for missing destination" {
    local source="$TEST_WORK_DIR/verify-source"
    local destination="$TEST_WORK_DIR/nonexistent"
    
    mkdir -p "$source"
    echo "test content" > "$source/test.txt"
    
    run verify_transfer "$source" "$destination"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Destination directory does not exist" ]]
}

@test "dry run mode: move_directory should not actually move files" {
    DRY_RUN=true

    local source_dir="$TEST_WORK_DIR/source"
    local source="$source_dir/dry-cache"
    local dest_base="$TEST_WORK_DIR/destination"

    mkdir -p "$source"
    echo "test content" > "$source/test.txt"

    # Set up SOURCE_DIRS and DEST_DIRS for move_directory function
    SOURCE_DIRS=("$source_dir")
    DEST_DIRS=("$dest_base")

    run move_directory "$source"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "DRY RUN: Would move" ]]

    # Source should still exist
    [ -d "$source" ]
    [ -f "$source/test.txt" ]
}

@test "email functionality: send_email should handle missing email tools gracefully" {
    EMAIL_ENABLED=true
    EMAIL_RECIPIENT="test@example.com"
    LOG_LEVEL="WARN"  # Set to see warning messages

    # Create a function that will override command to say msmtp/mailx don't exist
    command() {
        if [[ "$1" == "-v" ]] && [[ "$2" == "msmtp" || "$2" == "mailx" ]]; then
            return 1  # Command not found
        fi
        builtin command "$@"
    }
    export -f command

    run send_email "Test Subject" "Test Body"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "No email command available" ]]

    unset -f command
}

@test "email functionality: disabled email should return success" {
    EMAIL_ENABLED=false
    LOG_LEVEL="DEBUG"  # Set to DEBUG to see the debug message

    run send_email "Test Subject" "Test Body"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Email notifications disabled" ]]
}

@test "logging: different log levels should be filtered correctly" {
    LOG_LEVEL="WARN"

    # Debug and Info should not appear
    run cache_log DEBUG "Debug message"
    [[ ! "$output" =~ "Debug message" ]]

    run cache_log INFO "Info message"
    [[ ! "$output" =~ "Info message" ]]

    # Warn and Error should appear
    run cache_log WARN "Warning message"
    [[ "$output" =~ "Warning message" ]]

    run cache_log ERROR "Error message"
    [[ "$output" =~ "Error message" ]]
}

@test "cleanup function: should remove lock file and tmux session" {
    # Create lock file and tmux session
    echo "$$" > "$LOCK_FILE"
    TMUX_SESSION_NAME="test-session"
    tmux new-session -d -s "$TMUX_SESSION_NAME" "sleep 10" || skip "tmux not available"
    
    run cleanup
    [ "$status" -eq 0 ]
    
    # Lock file should be removed
    [ ! -f "$LOCK_FILE" ]
    
    # tmux session should be gone
    ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null
}

@test "error handling: error_exit should call cleanup and exit with code 1" {
    # This test verifies the error_exit function behavior
    # Test that cleanup is called by checking if lock file is removed

    # Create lock file
    echo "$$" > "$LOCK_FILE"
    [ -f "$LOCK_FILE" ]

    # Call error_exit in a subshell and capture output
    run bash -c "source '$SHOVEOVER'; export LOCK_FILE='$LOCK_FILE'; error_exit 'Test error message' 2>&1"

    # Should exit with code 1
    [ "$status" -eq 1 ]

    # Verify error was logged
    [[ "$output" =~ "ERROR: Test error message" ]]

    # Verify cleanup was called
    [[ "$output" =~ "Cleaning up" ]]
}