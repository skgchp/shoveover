#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

install_bats_macos() {
    if command -v brew >/dev/null 2>&1; then
        log "Installing Bats via Homebrew..."
        brew install bats-core
        return 0
    fi
    return 1
}

install_bats_linux() {
    # Try package managers first
    if command -v apt-get >/dev/null 2>&1; then
        log "Installing Bats via apt..."
        sudo apt-get update
        sudo apt-get install -y bats
        return 0
    elif command -v yum >/dev/null 2>&1; then
        log "Installing Bats via yum..."
        sudo yum install -y bats
        return 0
    elif command -v dnf >/dev/null 2>&1; then
        log "Installing Bats via dnf..."
        sudo dnf install -y bats
        return 0
    fi
    return 1
}

install_bats_git() {
    log "Installing Bats from GitHub..."
    local bats_dir="$PROJECT_ROOT/.bats"
    
    if [[ -d "$bats_dir" ]]; then
        log "Bats already installed in $bats_dir"
        return 0
    fi
    
    git clone https://github.com/bats-core/bats-core.git "$bats_dir"
    cd "$bats_dir"
    ./install.sh /usr/local
}

check_bats_installation() {
    if command -v bats >/dev/null 2>&1; then
        local version
        version="$(bats --version)"
        log "Bats is installed: $version"
        return 0
    fi
    return 1
}

install_test_dependencies() {
    log "Checking for required test dependencies..."
    
    # Check for rsync
    if ! command -v rsync >/dev/null 2>&1; then
        log "ERROR: rsync is required but not installed"
        exit 1
    fi
    
    # Check for basic utilities
    for cmd in find du stat date; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR: Required command '$cmd' not found"
            exit 1
        fi
    done
    
    log "All required dependencies are available"
}

main() {
    log "Installing test dependencies for ShoveOver..."

    install_test_dependencies
    
    if check_bats_installation; then
        log "Bats is already installed, skipping installation"
        return 0
    fi
    
    log "Bats not found, attempting installation..."
    
    case "$(uname -s)" in
        Darwin)
            if install_bats_macos; then
                log "Bats installed successfully via Homebrew"
            else
                log "Homebrew not available, trying Git installation..."
                install_bats_git
            fi
            ;;
        Linux)
            if install_bats_linux; then
                log "Bats installed successfully via package manager"
            else
                log "Package manager installation failed, trying Git installation..."
                install_bats_git
            fi
            ;;
        *)
            log "Unknown system, trying Git installation..."
            install_bats_git
            ;;
    esac
    
    if check_bats_installation; then
        log "Bats installation completed successfully!"
    else
        log "ERROR: Bats installation failed"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi