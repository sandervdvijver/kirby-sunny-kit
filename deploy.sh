#!/bin/bash

set -euo pipefail  # Exit on error, unset vars, pipe failures
IFS=$'\n\t'       # Secure IFS

# Load environment variables from .env file
if [[ -f .env ]]; then
  while IFS='=' read -r key value || [[ -n $key ]]; do
    [[ $key =~ ^[[:space:]]*# ]] && continue
    [[ -z $key ]] && continue
    # Remove quotes from value if present
    value="${value%\"}"
    value="${value#\"}"
    export "$key"="$value"
  done < .env
else
  echo "Error: .env file not found. Create one with REMOTE_SERVER and REMOTE_PATH."
  exit 1
fi

# Validate required variables
[[ -z "${REMOTE_SERVER:-}" ]] && { echo "Error: REMOTE_SERVER not set in .env"; exit 1; }
[[ -z "${REMOTE_PATH:-}" ]] && { echo "Error: REMOTE_PATH not set in .env"; exit 1; }

# Create backup before destructive operations
create_backup() {
  local what="$1"
  local backup_dir="./backups/$(date '+%Y%m%d_%H%M%S')_$what"
  
  if [[ "$what" == "content" && -d "content" ]]; then
    if mkdir -p "$backup_dir" && find content -mindepth 1 -exec cp -r {} "$backup_dir/" \; 2>/dev/null; then
      echo "Local content backed up to $backup_dir"
    else
      echo "Warning: Failed to create backup. Continuing anyway..."
    fi
  fi
}

# Enhanced rsync with safety checks
safe_rsync() {
  local source="$1"
  local dest="$2"
  local delete_flag="$3"
  local operation_type="$4"  # "content" or "codebase"
  
  local rsync_args=(-avz)
  local rsync_filters=()
  
  # Helper to build filter arrays
  add_excludes() { for pattern in "$@"; do rsync_filters+=(--exclude="$pattern"); done; }
  add_includes() { for pattern in "$@"; do rsync_filters+=(--include="$pattern"); done; }
  
  # Choose filtering strategy based on operation type
  if [[ "$operation_type" == "content" ]]; then
    # Content operations: simple exclusions for OS junk files only
    add_excludes '.DS_Store' 'Icon*' 'Thumbs.db' '._*'
  else
    # Codebase deployment: whitelist approach
    add_includes 'index.php' 'kirby/***' '.htaccess'
    add_excludes 'site/cache' 'site/sessions'
    add_includes 'site/***' 'assets/***' 'vendor/***'
    add_excludes '*'
  fi
  
  # Add delete flag if specified
  [[ -n "$delete_flag" ]] && rsync_args+=("$delete_flag")
  
  echo
  echo "=== DRY RUN - Showing what would change ==="
  echo "Source: $source"
  echo "Destination: $dest"
  [[ -n "$delete_flag" ]] && echo "WARNING: --delete flag will remove files that don't exist in source!"
  echo
  
  # Always do dry run first
  if ! rsync "${rsync_args[@]}" --dry-run --itemize-changes "${rsync_filters[@]}" "$source" "$dest"; then
    echo "Error: Dry run failed. Check your connection and paths."
    return 1
  fi
  
  echo
  read -p "Proceed with these changes? (y/N): " -n 1 -r
  echo
  
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Executing rsync..."
    if rsync "${rsync_args[@]}" --progress "${rsync_filters[@]}" "$source" "$dest"; then
      echo "Sync completed successfully"
    else
      echo "Error: Rsync failed"
      return 1
    fi
  else
    echo "Operation cancelled"
    return 1
  fi
}

# Test connection and path
echo "Testing connection to $REMOTE_SERVER..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_SERVER" exit 2>/dev/null; then
  echo "Error: Cannot connect to $REMOTE_SERVER. Check SSH keys and server."
  exit 1
fi

# Test remote path exists
if ! ssh -o BatchMode=yes "$REMOTE_SERVER" "test -d '$REMOTE_PATH'" 2>/dev/null; then
  echo "Warning: Remote path '$REMOTE_PATH' does not exist."
  read -p "Continue anyway? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting..."
    exit 1
  fi
fi
echo "Connection successful"

# Main menu
echo
echo "Kirby Deploy Tool"
echo "1. Pull content from remote"
echo "2. Push codebase to remote" 
echo "3. Push content to remote"
echo "4. Show what's different (dry-run everything)"
echo "5. Exit"
echo
read -p "Choose (1-5): " choice

case $choice in
  1)
    echo
    echo "Pulling content from remote..."
    create_backup "content"
    safe_rsync "$REMOTE_SERVER:$REMOTE_PATH/content/" "content/" "" "content"
    ;;
  2)
    echo
    echo "Pushing codebase to remote..."
    echo "WARNING: This will overwrite code on the remote server"
    safe_rsync "./" "$REMOTE_SERVER:$REMOTE_PATH/" "" "codebase"
    ;;
  3)
    echo
    echo "Pushing content to remote..."
    
    # Ask about pulling first to check for conflicts
    read -p "Pull remote content first to check for conflicts? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "Checking remote content..."
      safe_rsync "$REMOTE_SERVER:$REMOTE_PATH/content/" "content/" "" "content"
    fi
    
    # Ask about --delete flag
    echo
    echo "IMPORTANT: Should files that exist on remote but not locally be deleted?"
    echo "   Choose 'y' for exact mirror (removes remote-only files)"
    echo "   Choose 'n' to only add/update files (safer)"
    read -p "Use --delete flag? (y/N): " -n 1 -r
    echo
    
    local delete_opt=""
    [[ $REPLY =~ ^[Yy]$ ]] && delete_opt="--delete"
    
    safe_rsync "content/" "$REMOTE_SERVER:$REMOTE_PATH/content/" "$delete_opt" "content"
    ;;
  4)
    echo
    echo "=== STATUS CHECK - What's different between local and remote ==="
    echo
    echo "Codebase differences:"
    rsync -avz --dry-run --itemize-changes \
      --include='index.php' --include='kirby/***' --include='.htaccess' \
      --exclude='site/cache' --exclude='site/sessions' \
      --include='site/***' --include='assets/***' --include='vendor/***' \
      --exclude='*' \
      "./" "$REMOTE_SERVER:$REMOTE_PATH/" || echo "  (No codebase differences or connection failed)"
    
    echo
    echo "Content differences:"
    rsync -avz --dry-run --itemize-changes \
      --exclude='.DS_Store' --exclude='Icon*' --exclude='Thumbs.db' --exclude='._*' \
      "content/" "$REMOTE_SERVER:$REMOTE_PATH/content/" || echo "  (No content differences or connection failed)"
    
    echo
    echo "Legend: '>' = file would be transferred, 'c' = checksum differs, 's' = size differs"
    echo "This was just a preview - nothing was actually changed."
    ;;
  5)
    echo "Goodbye!"
    exit 0
    ;;
  *)
    echo "Invalid choice"
    exit 1
    ;;
esac

echo "Done!"