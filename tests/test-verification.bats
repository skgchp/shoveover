#!/usr/bin/env bats

# Transfer verification tests for verify_transfer() function

setup() {
    TEST_DIR="$(dirname "$BATS_TEST_FILENAME")"
    PROJECT_ROOT="$(dirname "$TEST_DIR")"
    SHOVEOVER="$PROJECT_ROOT/shoveover.sh"

    # Setup test environment
    TEST_WORK_DIR="$TEST_DIR/tmp-verification"
    mkdir -p "$TEST_WORK_DIR"

    # Set globals before sourcing
    export LOCK_FILE="$TEST_WORK_DIR/.running"
    export LOG_FILE="$TEST_WORK_DIR/test.log"
    export LOG_LEVEL="DEBUG"

    # Source the script for testing individual functions
    source "$SHOVEOVER"
}

teardown() {
    # Cleanup
    if [[ -d "$TEST_WORK_DIR" ]]; then
        rm -rf "$TEST_WORK_DIR"
    fi
}

create_test_file() {
    local filepath="$1"
    local size_kb="${2:-10}"  # Default 10KB

    mkdir -p "$(dirname "$filepath")"
    head -c $((size_kb * 1024)) /dev/zero > "$filepath" 2>/dev/null

    # Ensure different files have different timestamps to avoid rsync timestamp optimizations
    # Touch the file with a unique timestamp based on size (helps Linux CI)
    sleep 0.01 || true
}

@test "verification: should pass when all files match (name and size)" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create matching source and destination
    create_test_file "$source/file1.dat" 5
    create_test_file "$source/file2.dat" 10
    create_test_file "$source/subdir/file3.dat" 15

    create_test_file "$dest/file1.dat" 5
    create_test_file "$dest/file2.dat" 10
    create_test_file "$dest/subdir/file3.dat" 15

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}

@test "verification: should fail when files are missing in destination" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create source with files
    create_test_file "$source/file1.dat" 5
    create_test_file "$source/file2.dat" 10
    create_test_file "$source/missing.dat" 15

    # Create destination with only some files
    create_test_file "$dest/file1.dat" 5
    create_test_file "$dest/file2.dat" 10
    # missing.dat is not in destination

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Verification failed" ]]
    [[ "$output" =~ "files missing or size mismatch" ]]
}

@test "verification: should fail when file sizes don't match" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create source files
    create_test_file "$source/file1.dat" 5
    create_test_file "$source/file2.dat" 10

    # Create destination files with different sizes
    create_test_file "$dest/file1.dat" 5
    create_test_file "$dest/file2.dat" 20  # Different size

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Verification failed" ]]
}

@test "verification: should pass when destination has extra files (merge scenario)" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create source files
    create_test_file "$source/file1.dat" 5
    create_test_file "$source/file2.dat" 10

    # Create destination with source files plus extras
    create_test_file "$dest/file1.dat" 5
    create_test_file "$dest/file2.dat" 10
    create_test_file "$dest/extra1.dat" 100
    create_test_file "$dest/extra2.dat" 200
    create_test_file "$dest/old/archived.dat" 50

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}

@test "verification: should ignore hidden files in source" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create source with regular and hidden files
    create_test_file "$source/file1.dat" 5
    create_test_file "$source/.hidden-file" 10
    create_test_file "$source/.config/settings.conf" 5

    # Create destination with only regular files (hidden files not transferred)
    create_test_file "$dest/file1.dat" 5
    # No .hidden-file or .config directory in destination

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}

@test "verification: should handle empty directories" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create empty source and destination directories
    mkdir -p "$source"
    mkdir -p "$dest"

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}

@test "verification: should fail if destination doesn't exist" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/nonexistent"

    # Create source
    create_test_file "$source/file1.dat" 5
    # Don't create destination

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Destination directory does not exist" ]]
}

@test "verification: should handle subdirectory structures" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create complex directory structure in source
    create_test_file "$source/level1/file1.dat" 5
    create_test_file "$source/level1/level2/file2.dat" 10
    create_test_file "$source/level1/level2/level3/file3.dat" 15
    create_test_file "$source/other/data.dat" 20

    # Mirror in destination
    create_test_file "$dest/level1/file1.dat" 5
    create_test_file "$dest/level1/level2/file2.dat" 10
    create_test_file "$dest/level1/level2/level3/file3.dat" 15
    create_test_file "$dest/other/data.dat" 20

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}

@test "verification: should detect partial file transfers" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create source files
    create_test_file "$source/complete.dat" 100
    create_test_file "$source/partial.dat" 100

    # Create destination with complete and partial file
    create_test_file "$dest/complete.dat" 100
    create_test_file "$dest/partial.dat" 50  # Only half transferred

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Verification failed" ]]
    [[ "$output" =~ "size mismatch" ]]
}

@test "verification: should handle files with spaces in names" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create files with spaces
    create_test_file "$source/file with spaces.dat" 5
    create_test_file "$source/dir with spaces/another file.dat" 10

    # Mirror in destination
    create_test_file "$dest/file with spaces.dat" 5
    create_test_file "$dest/dir with spaces/another file.dat" 10

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}

@test "verification: should handle special characters in filenames" {
    local source="$TEST_WORK_DIR/source"
    local dest="$TEST_WORK_DIR/dest"

    # Create files with special characters (avoiding problematic ones)
    create_test_file "$source/file-with-dashes.dat" 5
    create_test_file "$source/file_with_underscores.dat" 10
    create_test_file "$source/file.multiple.dots.dat" 15

    # Mirror in destination
    create_test_file "$dest/file-with-dashes.dat" 5
    create_test_file "$dest/file_with_underscores.dat" 10
    create_test_file "$dest/file.multiple.dots.dat" 15

    run verify_transfer "$source" "$dest"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Transfer verification passed" ]]
}
