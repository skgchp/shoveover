#!/usr/bin/env bats

# Integration tests for end-to-end functionality

setup() {
    TEST_DIR="$(dirname "$BATS_TEST_FILENAME")"
    PROJECT_ROOT="$(dirname "$TEST_DIR")"
    SHOVEOVER="$PROJECT_ROOT/shoveover.sh"
    
    # Setup isolated test environment
    TEST_WORK_DIR="$TEST_DIR/tmp-integration"
    mkdir -p "$TEST_WORK_DIR"
    
    # Create test directory structure
    SOURCE1="$TEST_WORK_DIR/source1"
    SOURCE2="$TEST_WORK_DIR/source2"
    DESTINATION="$TEST_WORK_DIR/destination"
    
    mkdir -p "$SOURCE1" "$SOURCE2" "$DESTINATION"
    
    # Create test configuration
    TEST_CONFIG="$TEST_WORK_DIR/test-config.conf"
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=(
    "$SOURCE1:$DESTINATION/source1"
    "$SOURCE2:$DESTINATION/source2"
)
LOW_SPACE_THRESHOLD=95
TARGET_SPACE_THRESHOLD=98
EMAIL_ENABLED=false
EMAIL_RECIPIENT=""
TMUX_SESSION_NAME="shoveover-integration-test"
LOG_LEVEL="DEBUG"
MAX_MOVES_PER_RUN=3
MIN_AGE_DAYS=0
EOF
}

teardown() {
    # Cleanup test environment
    if [[ -d "$TEST_WORK_DIR" ]]; then
        rm -rf "$TEST_WORK_DIR"
    fi
    
    # Kill any test tmux sessions
    tmux kill-session -t "shoveover-integration-test" 2>/dev/null || true
}

create_mock_cache_dirs() {
    local base_dir="$1"
    local count="$2"
    local days_offset="$3"

    for ((i=1; i<=count; i++)); do
        local dir="$base_dir/cache_dir_$i"
        mkdir -p "$dir"

        # Create some test files
        echo "Cache data $i" > "$dir/data.txt"
        echo "More data $i" > "$dir/metadata.json"

        # Set modification time (macOS vs Linux compatible)
        local days_ago=$((days_offset + i))
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS format
            touch -t "$(date -v-${days_ago}d '+%Y%m%d%H%M.%S')" "$dir"
        else
            # Linux format
            touch -d "$days_ago days ago" "$dir"
        fi
    done
}

@test "integration: test mode should validate configuration without running" {
    run "$SHOVEOVER" --test --config "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Configuration test passed successfully" ]]

    # Should not create lock file in test mode
    [ ! -f "$TEST_WORK_DIR/.running" ]
}

@test "integration: script should exit early when disk space is sufficient" {
    # Create some cache directories
    create_mock_cache_dirs "$SOURCE1" 3 5
    
    # Set thresholds that won't trigger cleanup (most systems have > 5% free space)
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=("$SOURCE1:$DESTINATION/source1")
LOW_SPACE_THRESHOLD=5
TARGET_SPACE_THRESHOLD=10
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-sufficient-space"
LOG_LEVEL="INFO"
MIN_AGE_DAYS=0
EOF
    
    run "$SHOVEOVER" --config "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Sufficient free space" ]]
    
    # Cache directories should still exist
    [ -d "$SOURCE1/cache_dir_1" ]
    [ -d "$SOURCE1/cache_dir_2" ]
    [ -d "$SOURCE1/cache_dir_3" ]
}

@test "integration: dry run mode should simulate moves without actual file operations" {
    # Create test cache directories
    create_mock_cache_dirs "$SOURCE1" 2 5
    
    # Set low thresholds for testing dry run
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=("$SOURCE1:$DESTINATION/source1")
LOW_SPACE_THRESHOLD=95
TARGET_SPACE_THRESHOLD=98
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-dry-run"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=5
MIN_AGE_DAYS=0
EOF
    
    run "$SHOVEOVER" --dry-run --config "$TEST_CONFIG"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "DRY RUN: Would move" ]]

    # Original directories should still exist
    [ -d "$SOURCE1/cache_dir_1" ]
    [ -d "$SOURCE1/cache_dir_2" ]

    # No cache directories should be moved to destination in dry-run mode
    # (destination directory structure may be created during validation, but no cache_dir_* moved)
    if [ -d "$DESTINATION/source1" ]; then
        [ -z "$(ls -A "$DESTINATION/source1" 2>/dev/null)" ]
    fi
}

@test "integration: should move oldest directories first" {
    # Create cache directories with different ages
    create_mock_cache_dirs "$SOURCE1" 3 10  # 11, 12, 13 days old
    create_mock_cache_dirs "$SOURCE2" 2 5   # 6, 7 days old
    
    # Force cleanup by setting very high thresholds
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=(
    "$SOURCE1:$DESTINATION/source1"
    "$SOURCE2:$DESTINATION/source2"
)
LOW_SPACE_THRESHOLD=99
TARGET_SPACE_THRESHOLD=99
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-oldest-first"
LOG_LEVEL="DEBUG"
MAX_MOVES_PER_RUN=1
MIN_AGE_DAYS=0
EOF
    
    run "$SHOVEOVER" --config "$TEST_CONFIG"
    [ "$status" -eq 0 ]

    # The oldest directory should be moved first
    # In this case, cache_dir_3 from SOURCE1 (13 days old) should be moved to source1 subdirectory
    [ -d "$DESTINATION/source1/cache_dir_3" ]
    [ ! -d "$SOURCE1/cache_dir_3" ]
    
    # Verify content was transferred correctly
    [ -f "$DESTINATION/source1/cache_dir_3/data.txt" ]
    [ -f "$DESTINATION/source1/cache_dir_3/metadata.json" ]
    
    # Other directories should remain
    [ -d "$SOURCE1/cache_dir_1" ]
    [ -d "$SOURCE1/cache_dir_2" ]
    [ -d "$SOURCE2/cache_dir_1" ]
    [ -d "$SOURCE2/cache_dir_2" ]
}

@test "integration: should respect MAX_MOVES_PER_RUN limit" {
    # Create more cache directories than the limit
    create_mock_cache_dirs "$SOURCE1" 5 10
    
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=("$SOURCE1:$DESTINATION/source1")
LOW_SPACE_THRESHOLD=99
TARGET_SPACE_THRESHOLD=99
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-max-moves"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=2
MIN_AGE_DAYS=0
EOF
    
    run "$SHOVEOVER" --config "$TEST_CONFIG"
    [ "$status" -eq 0 ]

    # Should only move 2 directories despite having 5 available
    local moved_count
    moved_count=$(ls -1 "$DESTINATION/source1" | wc -l | tr -d ' ')
    [ "$moved_count" -eq 2 ]
    
    # Should move the oldest 2 directories
    [ -d "$DESTINATION/source1/cache_dir_4" ]  # 14 days old
    [ -d "$DESTINATION/source1/cache_dir_5" ]  # 15 days old
    
    # Newer directories should remain
    [ -d "$SOURCE1/cache_dir_1" ]
    [ -d "$SOURCE1/cache_dir_2" ]
    [ -d "$SOURCE1/cache_dir_3" ]
}

@test "integration: should respect MIN_AGE_DAYS requirement" {
    # Create some very recent cache directories
    create_mock_cache_dirs "$SOURCE1" 3 0  # 1, 2, 3 days old
    
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=("$SOURCE1:$DESTINATION/source1")
LOW_SPACE_THRESHOLD=99
TARGET_SPACE_THRESHOLD=99
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-min-age"
LOG_LEVEL="DEBUG"
MAX_MOVES_PER_RUN=5
MIN_AGE_DAYS=7
EOF

    run "$SHOVEOVER" --config "$TEST_CONFIG"
    [ "$status" -eq 0 ]

    # No cache directories should be moved (all too young)
    # (destination directory structure may be created during validation)
    if [ -d "$DESTINATION/source1" ]; then
        [ -z "$(ls -A "$DESTINATION/source1" 2>/dev/null)" ]
    fi

    # All original directories should remain
    [ -d "$SOURCE1/cache_dir_1" ]
    [ -d "$SOURCE1/cache_dir_2" ]
    [ -d "$SOURCE1/cache_dir_3" ]

    [[ "$output" =~ "No more directories found to move" ]]
}

@test "integration: should handle destination name conflicts" {
    # Create cache directory
    create_mock_cache_dirs "$SOURCE1" 1 10

    # Pre-create a directory in destination with same name (in source1 subdirectory)
    mkdir -p "$DESTINATION/source1/cache_dir_1"
    echo "existing data" > "$DESTINATION/source1/cache_dir_1/existing.txt"

    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=("$SOURCE1:$DESTINATION/source1")
LOW_SPACE_THRESHOLD=99
TARGET_SPACE_THRESHOLD=99
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-conflicts"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=5
MIN_AGE_DAYS=0
EOF

    run "$SHOVEOVER" --config "$TEST_CONFIG"
    [ "$status" -eq 0 ]

    # Should create timestamped directory name
    local moved_dirs
    moved_dirs=$(ls -1 "$DESTINATION/source1" | grep -E "cache_dir_1-[0-9]{8}-[0-9]{6}")
    [ -n "$moved_dirs" ]

    # Original conflicting directory should remain unchanged
    [ -f "$DESTINATION/source1/cache_dir_1/existing.txt" ]

    # Source should be removed
    [ ! -d "$SOURCE1/cache_dir_1" ]
}

@test "integration: should create and monitor tmux session" {
    skip_if_no_tmux
    
    create_mock_cache_dirs "$SOURCE1" 1 10
    
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=("$SOURCE1:$DESTINATION/source1")
LOW_SPACE_THRESHOLD=99
TARGET_SPACE_THRESHOLD=99
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-tmux-session"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=1
MIN_AGE_DAYS=0
EOF
    
    # Run script in background to test tmux session creation
    "$SHOVEOVER" --config "$TEST_CONFIG" &
    local script_pid=$!
    
    # Give script time to start and create session
    sleep 2
    
    # Check if tmux session was created
    tmux has-session -t "test-tmux-session"
    local session_exists=$?
    
    # Wait for script to complete
    wait $script_pid
    
    # tmux session should have been created during execution
    [ $session_exists -eq 0 ]
}

skip_if_no_tmux() {
    if ! command -v tmux >/dev/null 2>&1; then
        skip "tmux not available"
    fi
}

@test "integration: error conditions should be handled gracefully" {
    # Create scenario where rsync will fail (no write permission on destination)
    create_mock_cache_dirs "$SOURCE1" 1 10
    chmod 444 "$DESTINATION"  # Remove write permission
    
    cat > "$TEST_CONFIG" << EOF
SOURCE_DEST_PAIRS=("$SOURCE1:$DESTINATION/source1")
LOW_SPACE_THRESHOLD=99
TARGET_SPACE_THRESHOLD=99
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test-error-handling"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=1
MIN_AGE_DAYS=0
EOF
    
    run "$SHOVEOVER" --config "$TEST_CONFIG"
    [ "$status" -eq 1 ]  # Should exit with error
    [[ "$output" =~ "Failed to move directory" ]]
    
    # Source directory should still exist (failed move)
    [ -d "$SOURCE1/cache_dir_1" ]
    
    # Restore permissions for cleanup
    chmod 755 "$DESTINATION"
}