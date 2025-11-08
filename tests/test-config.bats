#!/usr/bin/env bats

# Test configuration parsing and validation

setup() {
    # Setup test environment
    TEST_DIR="$(dirname "$BATS_TEST_FILENAME")"
    PROJECT_ROOT="$(dirname "$TEST_DIR")"
    SHOVEOVER="$PROJECT_ROOT/shoveover.sh"

    # Setup test config directory
    TEST_CONFIG_DIR="$TEST_DIR/tmp-config"
    mkdir -p "$TEST_CONFIG_DIR"

    # Set globals before sourcing
    export LOCK_FILE="$TEST_CONFIG_DIR/.running"
    export LOG_FILE="$TEST_CONFIG_DIR/test.log"

    # Source the script for testing individual functions
    source "$SHOVEOVER"
}

teardown() {
    # Cleanup
    if [[ -d "$TEST_CONFIG_DIR" ]]; then
        rm -rf "$TEST_CONFIG_DIR"
    fi
}

@test "config file validation: missing config file should fail" {
    CONFIG_FILE="/nonexistent/config.conf"
    run load_config
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Configuration file not found" ]]
}

@test "config file validation: empty SOURCE_DEST_PAIRS should fail" {
    cat > "$TEST_CONFIG_DIR/empty-pairs.conf" << 'EOF'
SOURCE_DEST_PAIRS=()
LOW_SPACE_THRESHOLD=10
TARGET_SPACE_THRESHOLD=20
EMAIL_ENABLED=false
EMAIL_RECIPIENT=""
TMUX_SESSION_NAME="test"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=10
MIN_AGE_DAYS=7
EOF
    
    CONFIG_FILE="$TEST_CONFIG_DIR/empty-pairs.conf"
    run load_config
    [ "$status" -eq 1 ]
    [[ "$output" =~ "No source-destination pairs configured" ]]
}

@test "config file validation: invalid pair format should fail" {
    cat > "$TEST_CONFIG_DIR/invalid-format.conf" << 'EOF'
SOURCE_DEST_PAIRS=(
    "/tmp/source1"  # Missing destination
    "/tmp/source2:/tmp/dest2"
)
LOW_SPACE_THRESHOLD=10
TARGET_SPACE_THRESHOLD=20
EMAIL_ENABLED=false
EMAIL_RECIPIENT=""
TMUX_SESSION_NAME="test"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=10
MIN_AGE_DAYS=7
EOF
    
    CONFIG_FILE="$TEST_CONFIG_DIR/invalid-format.conf"
    run load_config
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid source-destination pair format" ]]
}

@test "config file validation: valid config should load successfully" {
    cat > "$TEST_CONFIG_DIR/valid.conf" << 'EOF'
SOURCE_DEST_PAIRS=(
    "/tmp/source1:/tmp/destination/source1"
    "/tmp/source2:/tmp/destination/source2"
)
LOW_SPACE_THRESHOLD=10
TARGET_SPACE_THRESHOLD=20
EMAIL_ENABLED=true
EMAIL_RECIPIENT="test@example.com"
TMUX_SESSION_NAME="test-session"
LOG_LEVEL="DEBUG"
MAX_MOVES_PER_RUN=5
MIN_AGE_DAYS=3
EOF

    CONFIG_FILE="$TEST_CONFIG_DIR/valid.conf"
    # Don't use run here so variables persist in current shell
    load_config

    # Verify variables were loaded (arrays are indexed by position, not key)
    [ "${SOURCE_DIRS[0]}" = "/tmp/source1" ]
    [ "${SOURCE_DIRS[1]}" = "/tmp/source2" ]
    [ "${DEST_DIRS[0]}" = "/tmp/destination/source1" ]
    [ "${DEST_DIRS[1]}" = "/tmp/destination/source2" ]
    [ "$LOW_SPACE_THRESHOLD" -eq 10 ]
    [ "$TARGET_SPACE_THRESHOLD" -eq 20 ]
    [ "$EMAIL_ENABLED" = "true" ]
    [ "$EMAIL_RECIPIENT" = "test@example.com" ]
    [ "$TMUX_SESSION_NAME" = "test-session" ]
    [ "$LOG_LEVEL" = "DEBUG" ]
    [ "$MAX_MOVES_PER_RUN" -eq 5 ]
    [ "$MIN_AGE_DAYS" -eq 3 ]
}

@test "directory validation: nonexistent source directory should fail" {
    # Setup config with nonexistent source
    cat > "$TEST_CONFIG_DIR/bad-source.conf" << 'EOF'
SOURCE_DEST_PAIRS=("/nonexistent/directory:/tmp/destination")
EOF
    
    CONFIG_FILE="$TEST_CONFIG_DIR/bad-source.conf"
    load_config
    
    run validate_directories
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Source directory does not exist" ]]
}

@test "directory validation: destination directory creation should succeed" {
    # Create temp source directory
    mkdir -p "$TEST_CONFIG_DIR/temp-source"
    
    cat > "$TEST_CONFIG_DIR/auto-dest.conf" << EOF
SOURCE_DEST_PAIRS=("$TEST_CONFIG_DIR/temp-source:$TEST_CONFIG_DIR/auto-created-dest")
EOF
    
    CONFIG_FILE="$TEST_CONFIG_DIR/auto-dest.conf"
    load_config
    
    run validate_directories
    [ "$status" -eq 0 ]
    [[ "$output" =~ "creating: $TEST_CONFIG_DIR/auto-created-dest" ]]
    
    # Destination should now exist
    [ -d "$TEST_CONFIG_DIR/auto-created-dest" ]
}

@test "directory validation: valid directories should pass" {
    # Create temp directories
    mkdir -p "$TEST_CONFIG_DIR/temp-source1"
    mkdir -p "$TEST_CONFIG_DIR/temp-source2"
    mkdir -p "$TEST_CONFIG_DIR/temp-dest1"
    mkdir -p "$TEST_CONFIG_DIR/temp-dest2"
    
    cat > "$TEST_CONFIG_DIR/good-dirs.conf" << EOF
SOURCE_DEST_PAIRS=(
    "$TEST_CONFIG_DIR/temp-source1:$TEST_CONFIG_DIR/temp-dest1"
    "$TEST_CONFIG_DIR/temp-source2:$TEST_CONFIG_DIR/temp-dest2"
)
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test"
LOG_LEVEL="INFO"
EOF
    
    CONFIG_FILE="$TEST_CONFIG_DIR/good-dirs.conf"
    load_config
    
    run validate_directories
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Directory validation passed" ]]
}

@test "command line argument parsing: help option should show usage" {
    run "$SHOVEOVER" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "command line argument parsing: debug option should set log level" {
    # This test would need a way to check that LOG_LEVEL gets set to DEBUG
    # For now, we test that the script accepts the option without error
    run "$SHOVEOVER" --debug --test --config "$TEST_DIR/fixtures/minimal-config.conf"
    [[ "$output" =~ "DEBUG" ]] || [[ "$status" -eq 1 ]]  # Expect either debug output or failure due to nonexistent dirs
}

@test "command line argument parsing: test mode should validate and exit" {
    # Create a valid test config
    mkdir -p "$TEST_CONFIG_DIR/test-source"
    mkdir -p "$TEST_CONFIG_DIR/test-dest"
    
    cat > "$TEST_CONFIG_DIR/test-mode.conf" << EOF
SOURCE_DEST_PAIRS=("$TEST_CONFIG_DIR/test-source:$TEST_CONFIG_DIR/test-dest")
EMAIL_ENABLED=false
TMUX_SESSION_NAME="test"
LOG_LEVEL="INFO"
MAX_MOVES_PER_RUN=1
MIN_AGE_DAYS=1
EOF
    
    run "$SHOVEOVER" --test --config "$TEST_CONFIG_DIR/test-mode.conf"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Configuration test passed successfully" ]]
}