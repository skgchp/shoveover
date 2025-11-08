#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly TEST_DIR="$PROJECT_ROOT/tests"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

create_test_directories() {
    log "Creating test directory structure..."
    
    local test_dirs=(
        "$TEST_DIR/mock-data/source1"
        "$TEST_DIR/mock-data/source2"
        "$TEST_DIR/mock-data/destination"
        "$TEST_DIR/mock-data/temp"
        "$TEST_DIR/fixtures"
    )
    
    for dir in "${test_dirs[@]}"; do
        mkdir -p "$dir"
        log "Created: $dir"
    done
}

create_mock_data() {
    log "Creating mock test data..."
    
    local source1="$TEST_DIR/mock-data/source1"
    local source2="$TEST_DIR/mock-data/source2"
    
    # Create mock directories with different ages
    for i in {1..5}; do
        local dir1="$source1/old_cache_$i"
        local dir2="$source2/old_cache_$i"
        
        mkdir -p "$dir1" "$dir2"
        
        # Create some dummy files
        echo "Test data for cache $i" > "$dir1/data.txt"
        echo "More test data for cache $i" > "$dir2/data.txt"
        
        # Set different modification times (older = higher number)
        local days_ago=$((i * 2))
        # Use different touch syntax for macOS vs Linux
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS format
            touch -t "$(date -v-${days_ago}d '+%Y%m%d%H%M.%S')" "$dir1" "$dir2"
        else
            # Linux format
            touch -d "$days_ago days ago" "$dir1" "$dir2"
        fi
        
        log "Created mock cache directories: old_cache_$i (${days_ago} days old)"
    done
}

create_test_configs() {
    log "Creating test configuration files..."

    # Test config with mock data paths
    cat > "$TEST_DIR/fixtures/test-config.conf" << 'EOF'
# Test configuration for ShoveOver
SOURCE_DEST_PAIRS=(
    "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/mock-data/source1:$(dirname "$(realpath "${BASH_SOURCE[0]}")")/mock-data/destination/source1"
    "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/mock-data/source2:$(dirname "$(realpath "${BASH_SOURCE[0]}")")/mock-data/destination/source2"
)

LOW_SPACE_THRESHOLD=90
TARGET_SPACE_THRESHOLD=95
EMAIL_ENABLED=false
EMAIL_RECIPIENT=""
TMUX_SESSION_NAME="cache-manager-test"
LOG_LEVEL="DEBUG"
MAX_MOVES_PER_RUN=3
MIN_AGE_DAYS=1
EOF

    # Minimal config for testing validation
    cat > "$TEST_DIR/fixtures/minimal-config.conf" << 'EOF'
SOURCE_DEST_PAIRS=(
    "/nonexistent/path1:/nonexistent/destination1"
    "/nonexistent/path2:/nonexistent/destination2"
)
EOF

    log "Created test configuration files"
}

setup_test_environment() {
    log "Setting up test environment..."
    
    create_test_directories
    create_mock_data
    create_test_configs
    
    log "Test environment setup completed"
    log "Mock data location: $TEST_DIR/mock-data/"
    log "Test fixtures location: $TEST_DIR/fixtures/"
}

clean_test_environment() {
    log "Cleaning test environment..."
    
    if [[ -d "$TEST_DIR/mock-data" ]]; then
        rm -rf "$TEST_DIR/mock-data"
        log "Removed mock data directory"
    fi
    
    if [[ -d "$TEST_DIR/fixtures" ]]; then
        rm -rf "$TEST_DIR/fixtures"
        log "Removed fixtures directory"
    fi
    
    log "Test environment cleaned"
}

main() {
    case "${1:-setup}" in
        setup)
            setup_test_environment
            ;;
        clean)
            clean_test_environment
            ;;
        reset)
            clean_test_environment
            setup_test_environment
            ;;
        *)
            echo "Usage: $0 [setup|clean|reset]"
            echo "  setup - Create test environment (default)"
            echo "  clean - Remove test environment" 
            echo "  reset - Clean and recreate test environment"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi