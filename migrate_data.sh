#!/bin/bash

OLD_DIR="$HOME/Library/Application Support/WeChatVoiceRecorder"
NEW_DIR="$HOME/Library/Application Support/VoiceMemo"

echo "Checking for data migration..."

if [ -d "$OLD_DIR" ]; then
    if [ ! -d "$NEW_DIR" ]; then
        # Normal case: New dir doesn't exist, just move
        echo "Found old data at $OLD_DIR. Migrating to $NEW_DIR..."
        mv "$OLD_DIR" "$NEW_DIR"
        echo "✅ Migration complete."
    else
        # Conflict case: New dir exists
        echo "⚠️  Both old and new directories exist."
        
        # Create a backup timestamp
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        BACKUP_DIR="${NEW_DIR}_backup_${TIMESTAMP}"
        
        echo "📦 Backing up existing VoiceMemo directory to: $BACKUP_DIR"
        mv "$NEW_DIR" "$BACKUP_DIR"
        
        echo "🚀 Migrating old data..."
        mv "$OLD_DIR" "$NEW_DIR"
        
        echo "✅ Migration complete."
        echo "   - Old data moved to: $NEW_DIR"
        echo "   - Previous new data backed up at: $BACKUP_DIR"
    fi
else
    echo "No old data found at $OLD_DIR. Nothing to migrate."
fi
