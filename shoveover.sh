#!/bin/bash

set -eo pipefail  # Remove -u flag to avoid issues with unset variables in older bash
# inherit_errexit is bash 4.4+ only, skip on older versions
if [[ "${BASH_VERSINFO:-}" ]] && (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    shopt -s inherit_errexit 2>/dev/null || true
fi
shopt -s nullglob 2>/dev/null || true

# Set defaults if not already set (allows test override)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
fi
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config/shoveover.conf}"
LOCK_FILE="${LOCK_FILE:-${SCRIPT_DIR}/.running}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/shoveover.log}"

LOG_LEVEL="INFO"
SOURCE_DEST_PAIRS=()
SOURCE_DIRS=()
DEST_DIRS=()
LOW_SPACE_THRESHOLD=10
TARGET_SPACE_THRESHOLD=20
EMAIL_ENABLED=false
EMAIL_RECIPIENT=""
TMUX_SESSION_NAME="shoveover"
MAX_MOVES_PER_RUN=10
MIN_AGE_DAYS=7
MAX_SEARCH_DEPTH=""  # Optional: limit depth when searching for leaf directories (empty = unlimited)
DRY_RUN=false

cache_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    local output=""
    case "$level" in
        DEBUG) [[ "$LOG_LEVEL" == "DEBUG" ]] && output="[$timestamp] DEBUG: $message" ;;
        INFO) [[ "$LOG_LEVEL" =~ ^(DEBUG|INFO)$ ]] && output="[$timestamp] INFO: $message" ;;
        WARN) [[ "$LOG_LEVEL" =~ ^(DEBUG|INFO|WARN)$ ]] && output="[$timestamp] WARN: $message" ;;
        ERROR) output="[$timestamp] ERROR: $message" ;;
    esac

    if [[ -n "$output" ]]; then
        echo "$output"
        # Only write to log file if it's writable (not in test mode)
        if [[ -w "$LOG_FILE" ]] || [[ -w "$(dirname "$LOG_FILE")" ]]; then
            echo "$output" >> "$LOG_FILE"
        fi
    fi
}

error_exit() {
    local error_message="$1"
    cache_log ERROR "$error_message"
    
    # Send error email if possible
    send_error_email "$error_message"
    
    cleanup
    exit 1
}

send_error_email() {
    local error_message="$1"
    local error_context
    
    error_context="ShoveOver encountered an error and had to exit:

ERROR: $error_message

System Information:
- Hostname: $(hostname)
- Time: $(date)
- Script: $SCRIPT_NAME
- PID: $$
- Working Directory: $(pwd)

Recent Log Entries:
$(tail -n 20 "$LOG_FILE" 2>/dev/null || echo "Log file not available")

Configuration:
- Source-Destination Pairs: $(printf '%s ' "${SOURCE_DEST_PAIRS[@]}")
- Low Space Threshold: ${LOW_SPACE_THRESHOLD}%
- Target Space Threshold: ${TARGET_SPACE_THRESHOLD}%"

    send_email "ERROR - Script Failed" "$error_context" || true
}

cleanup() {
    cache_log INFO "Cleaning up..."
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        cache_log INFO "Removed lock file"
    fi
    
    if [[ -n "${TMUX_SESSION_NAME:-}" ]] && tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
        tmux kill-session -t "$TMUX_SESSION_NAME" 2>/dev/null || true
        cache_log INFO "Cleaned up tmux session: $TMUX_SESSION_NAME"
    fi
}

# Traps will be set up in main function to avoid issues when sourcing

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error_exit "Configuration file not found: $CONFIG_FILE"
    fi
    
    cache_log INFO "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
    
    if [[ ${#SOURCE_DEST_PAIRS[@]} -eq 0 ]]; then
        error_exit "No source-destination pairs configured"
    fi
    
    # Parse source-destination pairs into parallel arrays
    local pair_count=0
    for pair in "${SOURCE_DEST_PAIRS[@]}"; do
        if [[ ! "$pair" =~ ^(.+):(.+)$ ]]; then
            error_exit "Invalid source-destination pair format: '$pair' (expected 'source:destination')"
        fi
        
        local source="${BASH_REMATCH[1]}"
        local destination="${BASH_REMATCH[2]}"
        
        # Validate that source and destination are not empty
        if [[ -z "$source" ]] || [[ -z "$destination" ]]; then
            error_exit "Empty source or destination in pair: '$pair'"
        fi
        
        # Check for duplicate sources
        local i
        for i in "${!SOURCE_DIRS[@]}"; do
            if [[ "${SOURCE_DIRS[i]}" == "$source" ]]; then
                error_exit "Duplicate source directory: '$source'"
            fi
        done
        
        SOURCE_DIRS+=("$source")
        DEST_DIRS+=("$destination")
        ((pair_count++))
        
        cache_log DEBUG "Parsed pair $pair_count: '$source' -> '$destination'"
    done
    
    cache_log INFO "Configuration loaded successfully: $pair_count source-destination pairs"
}

validate_directories() {
    local validation_errors=0
    
    local i
    for i in "${!SOURCE_DIRS[@]}"; do
        local source="${SOURCE_DIRS[i]}"
        local destination="${DEST_DIRS[i]}"
        
        # Validate source directory
        if [[ ! -d "$source" ]]; then
            cache_log ERROR "Source directory does not exist: $source"
            ((validation_errors++))
        elif [[ ! -r "$source" ]]; then
            cache_log ERROR "No read permission for source directory: $source"
            ((validation_errors++))
        fi
        
        # Validate destination directory (create if it doesn't exist)
        if [[ ! -d "$destination" ]]; then
            cache_log WARN "Destination directory does not exist, creating: $destination"
            if ! mkdir -p "$destination" 2>/dev/null; then
                cache_log ERROR "Failed to create destination directory: $destination"
                ((validation_errors++))
            fi
        fi
        
        if [[ -d "$destination" ]] && [[ ! -w "$destination" ]]; then
            cache_log ERROR "No write permission for destination directory: $destination"
            ((validation_errors++))
        fi
        
        cache_log DEBUG "Validated pair: $source -> $destination"
    done
    
    if (( validation_errors > 0 )); then
        error_exit "Directory validation failed with $validation_errors errors"
    fi
    
    cache_log INFO "Directory validation passed for ${#SOURCE_DIRS[@]} pairs"
}

check_lock() {
    # Try to create lock file atomically
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")

        # Check if the process is still running
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            error_exit "Another instance is already running (PID: $lock_pid, lock file: $LOCK_FILE)"
        else
            cache_log WARN "Removing stale lock file (PID: $lock_pid)"
            rm -f "$LOCK_FILE"
        fi
    fi

    # Create lock file with current PID
    echo $$ > "$LOCK_FILE"
    cache_log INFO "Acquired process lock"
}

get_disk_usage_percent() {
    local path="$1"
    df "$path" | awk 'NR==2 {gsub(/%/, "", $5); print $5}'
}

get_free_space_percent() {
    local path="$1"
    local usage
    usage="$(get_disk_usage_percent "$path")"
    echo $((100 - usage))
}

check_disk_space() {
    # Check disk space for the first source directory's filesystem
    local first_source=""
    if [[ ${#SOURCE_DIRS[@]} -gt 0 ]]; then
        first_source="${SOURCE_DIRS[0]}"
    fi
    
    if [[ -z "$first_source" ]]; then
        error_exit "No source directories found for disk space check"
    fi
    
    local current_free
    current_free="$(get_free_space_percent "$first_source")"
    
    cache_log INFO "Current free space on $first_source filesystem: ${current_free}%"
    
    if (( current_free >= LOW_SPACE_THRESHOLD )); then
        cache_log INFO "Sufficient free space (${current_free}% >= ${LOW_SPACE_THRESHOLD}%), exiting"
        exit 0
    fi
    
    cache_log WARN "Free space is low (${current_free}% < ${LOW_SPACE_THRESHOLD}%), starting cleanup"
}

create_tmux_session() {
    # Check if tmux is available
    if ! command -v tmux >/dev/null 2>&1; then
        cache_log DEBUG "tmux not available, skipping session creation"
        return 0
    fi

    if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
        cache_log WARN "tmux session '$TMUX_SESSION_NAME' already exists, killing it"
        tmux kill-session -t "$TMUX_SESSION_NAME"
    fi

    tmux new-session -d -s "$TMUX_SESSION_NAME" "tail -f '$LOG_FILE'"
    cache_log INFO "Created tmux session: $TMUX_SESSION_NAME"
    cache_log INFO "Monitor progress with: tmux attach-session -t $TMUX_SESSION_NAME"
}

is_leaf_directory() {
    local dir="$1"

    # A leaf directory is one that has no subdirectories
    # Use find to check if there are any subdirectories
    # -mindepth 1 -maxdepth 1: only immediate children
    # -type d: only directories
    # -quit: exit on first match (performance optimization)
    if find "$dir" -mindepth 1 -maxdepth 1 -type d -quit 2>/dev/null | grep -q .; then
        return 1  # Has subdirectories, not a leaf
    else
        return 0  # No subdirectories, is a leaf
    fi
}

get_relative_path() {
    local base="$1"
    local full_path="$2"

    # Remove the base path from the full path to get relative path
    # Handle trailing slashes properly
    local normalized_base="${base%/}"
    echo "${full_path#$normalized_base/}"
}

find_oldest_subdir() {
    local oldest_path=""
    local oldest_time=""
    local oldest_source=""

    local i
    for i in "${!SOURCE_DIRS[@]}"; do
        local source_dir="${SOURCE_DIRS[i]}"

        # Build find command with optional depth limit
        local find_cmd="find \"$source_dir\" -mindepth 1 -type d"
        if [[ -n "${MAX_SEARCH_DEPTH:-}" ]] && [[ "$MAX_SEARCH_DEPTH" -gt 0 ]]; then
            find_cmd="$find_cmd -maxdepth $MAX_SEARCH_DEPTH"
        fi
        find_cmd="$find_cmd -print0"

        while IFS= read -r -d '' dir; do
            local dir_name
            dir_name="$(basename "$dir")"

            # Skip hidden directories and current/parent dir references
            if [[ "$dir_name" =~ ^\..*$ ]]; then
                continue
            fi

            # Check if this is a leaf directory (no subdirectories)
            if ! is_leaf_directory "$dir"; then
                cache_log DEBUG "Skipping $dir (not a leaf directory - has subdirectories)" >&2
                continue
            fi

            # Check minimum age requirement
            local dir_age_days
            dir_age_days="$(get_dir_age_days "$dir")"

            if (( dir_age_days < MIN_AGE_DAYS )); then
                # Redirect to stderr to avoid contaminating return value
                cache_log DEBUG "Skipping $dir (age: ${dir_age_days} days < ${MIN_AGE_DAYS} days)" >&2
                continue
            fi

            local mtime
            mtime="$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null)"

            if [[ -z "$oldest_time" ]] || (( mtime < oldest_time )); then
                oldest_time="$mtime"
                oldest_path="$dir"
                oldest_source="$source_dir"
            fi
        done < <(eval "$find_cmd")
    done

    # Return the oldest directory path
    if [[ -n "$oldest_path" ]]; then
        echo "$oldest_path"
    fi
}

get_source_root() {
    local target_path="$1"
    
    # Find which source directory this path belongs to
    local i
    for i in "${!SOURCE_DIRS[@]}"; do
        local source_dir="${SOURCE_DIRS[i]}"
        if [[ "$target_path" == "$source_dir"/* ]]; then
            echo "$source_dir"
            return 0
        fi
    done
    
    error_exit "Could not find source root for path: $target_path"
}

get_dir_age_days() {
    local dir="$1"
    local mtime
    local now
    local age_seconds
    
    mtime="$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null)"
    now="$(date +%s)"
    age_seconds="$((now - mtime))"
    echo "$((age_seconds / 86400))"
}

get_dir_size() {
    local dir="$1"
    local size_kb
    
    # Use du to get size in KB, then convert to MB
    size_kb="$(du -sk "$dir" | cut -f1)"
    echo "$((size_kb / 1024))"
}

move_directory() {
    local source_path="$1"
    local source_root
    source_root="$(get_source_root "$source_path")"
    
    # Find the destination directory by finding the source index
    local dest_base=""
    local i
    for i in "${!SOURCE_DIRS[@]}"; do
        if [[ "${SOURCE_DIRS[i]}" == "$source_root" ]]; then
            dest_base="${DEST_DIRS[i]}"
            break
        fi
    done
    
    if [[ -z "$dest_base" ]]; then
        error_exit "Could not find destination for source: $source_root"
    fi

    # Get the relative path from source root to preserve directory structure
    local relative_path
    relative_path="$(get_relative_path "$source_root" "$source_path")"
    local destination="$dest_base/$relative_path"

    cache_log INFO "Preparing to move: $source_path -> $destination"
    cache_log DEBUG "Relative path: $relative_path"

    # Check if destination already exists
    if [[ -e "$destination" ]]; then
        local timestamp
        timestamp="$(date '+%Y%m%d-%H%M%S')"
        local dir_name
        dir_name="$(basename "$destination")"
        local parent_dir
        parent_dir="$(dirname "$destination")"
        destination="${parent_dir}/${dir_name}-${timestamp}"
        cache_log WARN "Destination exists, using: $destination"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        cache_log INFO "DRY RUN: Would move $source_path to $destination"
        return 0
    fi

    # Create parent directories at destination
    local dest_parent
    dest_parent="$(dirname "$destination")"
    if [[ ! -d "$dest_parent" ]]; then
        cache_log INFO "Creating parent directories: $dest_parent"
        if ! mkdir -p "$dest_parent"; then
            cache_log ERROR "Failed to create parent directories: $dest_parent"
            return 1
        fi
    fi

    # Use rsync for safe, resumable transfers with progress
    cache_log INFO "Starting rsync transfer..."
    
    if rsync -avh --progress --partial --append "$source_path/" "$destination/"; then
        cache_log INFO "rsync completed successfully"
        
        # Verify the transfer completed successfully
        if verify_transfer "$source_path" "$destination"; then
            cache_log INFO "Transfer verification passed, removing source"
            if rm -rf "$source_path"; then
                cache_log INFO "Source directory removed successfully"
                return 0
            else
                cache_log ERROR "Failed to remove source directory: $source_path"
                return 1
            fi
        else
            cache_log ERROR "Transfer verification failed, keeping source directory"
            return 1
        fi
    else
        cache_log ERROR "rsync failed for: $source_path"
        return 1
    fi
}

verify_transfer() {
    local source="$1"
    local destination="$2"
    
    cache_log DEBUG "Verifying transfer: $source -> $destination"
    
    # Check if destination exists and is not empty
    if [[ ! -d "$destination" ]]; then
        cache_log ERROR "Destination directory does not exist: $destination"
        return 1
    fi
    
    # Compare directory sizes (rough verification)
    local source_size dest_size
    source_size="$(du -sk "$source" | cut -f1)"
    dest_size="$(du -sk "$destination" | cut -f1)"
    
    # Allow for small differences due to filesystem overhead
    local size_diff=$((source_size - dest_size))
    local size_diff_abs=${size_diff#-}  # absolute value
    local tolerance=$((source_size / 100))  # 1% tolerance
    
    if (( size_diff_abs > tolerance && size_diff_abs > 1024 )); then  # More than 1MB and 1% difference
        cache_log ERROR "Size verification failed: source=${source_size}KB, dest=${dest_size}KB"
        return 1
    fi
    
    cache_log DEBUG "Size verification passed: source=${source_size}KB, dest=${dest_size}KB"
    return 0
}

send_email() {
    local subject="$1"
    local body="$2"
    
    if [[ "$EMAIL_ENABLED" != "true" ]] || [[ -z "$EMAIL_RECIPIENT" ]]; then
        cache_log DEBUG "Email notifications disabled or no recipient configured"
        return 0
    fi
    
    local hostname
    hostname="$(hostname)"
    local full_subject="[$hostname] ShoveOver: $subject"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    local full_body="ShoveOver Report
Generated: $timestamp
Host: $hostname

$body

---
Script: $SCRIPT_NAME
PID: $$
Log: $LOG_FILE"
    
    if command -v msmtp >/dev/null 2>&1; then
        echo -e "Subject: $full_subject\n\n$full_body" | msmtp "$EMAIL_RECIPIENT"
    elif command -v mailx >/dev/null 2>&1; then
        echo "$full_body" | mailx -s "$full_subject" "$EMAIL_RECIPIENT"
    else
        cache_log WARN "No email command available (msmtp, mailx)"
        return 1
    fi
    
    cache_log INFO "Email sent to: $EMAIL_RECIPIENT"
}

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

A robust disk space management script that monitors disk space and moves oldest
subdirectories to another location when space is low.

OPTIONS:
    -h, --help      Show this help message
    -c, --config    Specify config file (default: $CONFIG_FILE)
    -d, --debug     Enable debug logging
    -t, --test      Test mode (validate config and exit)
    --dry-run       Simulate moves without actually moving files

EXAMPLES:
    $SCRIPT_NAME                    Run with default config
    $SCRIPT_NAME -d                Run with debug logging
    $SCRIPT_NAME -c custom.conf     Run with custom config
    $SCRIPT_NAME -t                 Test configuration
    $SCRIPT_NAME --dry-run          Simulate operations safely

EOF
}

main() {
    local test_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -d|--debug)
                LOG_LEVEL="DEBUG"
                shift
                ;;
            -t|--test)
                test_mode=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
    
    # Set up traps for cleanup
    trap cleanup EXIT
    trap 'error_exit "Script interrupted"' INT TERM
    
    cache_log INFO "Starting $SCRIPT_NAME (PID: $$)"
    
    check_lock
    load_config
    validate_directories
    
    if [[ "$test_mode" == "true" ]]; then
        cache_log INFO "Configuration test passed successfully"
        exit 0
    fi
    
    check_disk_space
    create_tmux_session
    
    cache_log INFO "ShoveOver initialization complete"
    
    local moved_count=0
    local total_freed=0
    local moved_dirs=()
    
    while (( moved_count < MAX_MOVES_PER_RUN )); do
        # Get the first source directory for disk space checking
        local first_source=""
        if [[ ${#SOURCE_DIRS[@]} -gt 0 ]]; then
            first_source="${SOURCE_DIRS[0]}"
        fi
        
        local current_free
        current_free="$(get_free_space_percent "$first_source")"
        
        if (( current_free >= TARGET_SPACE_THRESHOLD )); then
            cache_log INFO "Target free space reached (${current_free}% >= ${TARGET_SPACE_THRESHOLD}%)"
            break
        fi
        
        cache_log INFO "Current free space: ${current_free}%, target: ${TARGET_SPACE_THRESHOLD}%"
        
        local oldest_dir
        oldest_dir="$(find_oldest_subdir)"
        
        if [[ -z "$oldest_dir" ]]; then
            cache_log WARN "No more directories found to move"
            break
        fi
        
        cache_log INFO "Moving oldest directory: $oldest_dir"
        
        local dir_size
        dir_size="$(get_dir_size "$oldest_dir")"
        
        if move_directory "$oldest_dir"; then
            moved_dirs+=("$oldest_dir")
            ((moved_count++))
            ((total_freed += dir_size))
            cache_log INFO "Successfully moved $oldest_dir (${dir_size}MB freed)"
        else
            error_exit "Failed to move directory: $oldest_dir"
        fi
    done
    
    # Get final free space percentage
    local final_free=0
    if [[ ${#SOURCE_DIRS[@]} -gt 0 ]]; then
        final_free="$(get_free_space_percent "${SOURCE_DIRS[0]}")"
    fi

    if (( moved_count > 0 )); then
        local summary="Cache cleanup completed successfully:
- Moved $moved_count directories
- Freed approximately ${total_freed}MB
- Free space: ${final_free}%
- Moved directories: $(printf '%s\n' "${moved_dirs[@]}")"

        cache_log INFO "$summary"
        send_email "Cleanup Completed Successfully" "$summary"
    else
        cache_log INFO "No directories were moved"
        send_email "No Action Required" "ShoveOver ran but no cleanup was needed. Current free space: ${final_free}%"
    fi

    # cleanup is called automatically via EXIT trap, no need to call explicitly
    exit 0
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi