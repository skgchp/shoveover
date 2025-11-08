#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

check_dependencies() {
    log "Checking test dependencies..."
    
    if ! command -v bats >/dev/null 2>&1; then
        log "ERROR: Bats testing framework not found"
        log "Please run: $PROJECT_ROOT/scripts/install-deps.sh"
        exit 1
    fi
    
    local bats_version
    bats_version="$(bats --version)"
    log "Found Bats: $bats_version"
}

setup_test_environment() {
    log "Setting up test environment..."
    "$PROJECT_ROOT/scripts/setup-test-env.sh" reset
}

run_tests() {
    local test_files=("$@")
    local exit_code=0
    
    if [[ ${#test_files[@]} -eq 0 ]]; then
        # Run all test files
        test_files=("$SCRIPT_DIR"/*.bats)
        if [[ ${#test_files[@]} -eq 1 ]] && [[ ! -f "${test_files[0]}" ]]; then
            log "No .bats test files found in $SCRIPT_DIR"
            return 1
        fi
    fi
    
    log "Running test suite..."
    log "Test files: ${test_files[*]}"
    
    for test_file in "${test_files[@]}"; do
        if [[ ! -f "$test_file" ]]; then
            log "WARN: Test file not found: $test_file"
            continue
        fi
        
        log "Running: $(basename "$test_file")"
        
        if bats --tap "$test_file"; then
            log "PASS: $(basename "$test_file")"
        else
            log "FAIL: $(basename "$test_file")"
            exit_code=1
        fi
        
        echo "----------------------------------------"
    done
    
    return $exit_code
}

cleanup_test_environment() {
    log "Cleaning up test environment..."
    "$PROJECT_ROOT/scripts/setup-test-env.sh" clean
}

show_help() {
    cat << EOF
ShoveOver Test Runner

Usage: $0 [OPTIONS] [TEST_FILES...]

Options:
    -h, --help          Show this help
    -s, --setup-only    Setup test environment and exit
    -c, --clean-only    Clean test environment and exit
    --no-setup          Skip test environment setup
    --no-cleanup        Skip test environment cleanup
    -v, --verbose       Verbose output

Examples:
    $0                              Run all tests
    $0 test-config.bats             Run specific test file
    $0 --setup-only                 Setup test environment only
    $0 --no-cleanup test-*.bats     Run tests without cleanup

EOF
}

main() {
    local setup_only=false
    local clean_only=false
    local skip_setup=false
    local skip_cleanup=false
    local verbose=false
    local test_files=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--setup-only)
                setup_only=true
                shift
                ;;
            -c|--clean-only)
                clean_only=true
                shift
                ;;
            --no-setup)
                skip_setup=true
                shift
                ;;
            --no-cleanup)
                skip_cleanup=true
                shift
                ;;
            -v|--verbose)
                verbose=true
                set -x
                shift
                ;;
            *.bats)
                test_files+=("$1")
                shift
                ;;
            *)
                log "ERROR: Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Handle special modes
    if [[ "$clean_only" == "true" ]]; then
        cleanup_test_environment
        exit 0
    fi
    
    if [[ "$setup_only" == "true" ]]; then
        setup_test_environment
        exit 0
    fi
    
    # Normal test run
    check_dependencies
    
    local exit_code=0
    
    if [[ "$skip_setup" == "false" ]]; then
        setup_test_environment
    fi

    if [[ ${#test_files[@]} -eq 0 ]]; then
        if run_tests; then
            log "All tests passed!"
        else
            log "Some tests failed"
            exit_code=1
        fi
    else
        if run_tests "${test_files[@]}"; then
            log "All tests passed!"
        else
            log "Some tests failed"
            exit_code=1
        fi
    fi
    
    if [[ "$skip_cleanup" == "false" ]]; then
        cleanup_test_environment
    fi
    
    exit $exit_code
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi