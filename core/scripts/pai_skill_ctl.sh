#!/bin/bash
# PAI Skill Controller v1.1.0
# Bridges local workflows to global/local skills.

SKILL_NAME=$2
COMMAND=$1

GLOBAL_SKILLS_DIR="${PAI_GLOBAL_SKILLS_DIR:-$HOME/.gemini/antigravity/skills}"
LOCAL_SKILLS_DIR=".agent/skills"
ALT_GLOBAL_SKILLS_DIRS=(
    "$HOME/.codex/skills"
    "$HOME/.config/pai/skills"
)

if [ -z "$SKILL_NAME" ]; then
    echo "Usage: $0 run <skill-name>"
    exit 1
fi

# 1. Resolve Skill Path (Local Override First)
if [ -d "$LOCAL_SKILLS_DIR/$SKILL_NAME" ]; then
    SKILL_PATH="$LOCAL_SKILLS_DIR/$SKILL_NAME"
    echo "Using local skill: $SKILL_NAME"
elif [ -d "$GLOBAL_SKILLS_DIR/$SKILL_NAME" ]; then
    SKILL_PATH="$GLOBAL_SKILLS_DIR/$SKILL_NAME"
    echo "Using global skill: $SKILL_NAME"
else
    for d in "${ALT_GLOBAL_SKILLS_DIRS[@]}"; do
        if [ -d "$d/$SKILL_NAME" ]; then
            SKILL_PATH="$d/$SKILL_NAME"
            echo "Using alternate global skill: $SKILL_NAME"
            break
        fi
    done
    if [ -z "${SKILL_PATH:-}" ]; then
        echo "Error: Skill '$SKILL_NAME' not found."
        echo "Checked local: $LOCAL_SKILLS_DIR"
        echo "Checked global: $GLOBAL_SKILLS_DIR"
        echo "Checked alternates: ${ALT_GLOBAL_SKILLS_DIRS[*]}"
        exit 1
    fi
fi

# 2. Resolve Entry Point
if [ -f "$SKILL_PATH/scripts/run.sh" ]; then
    ENTRY_POINT="$SKILL_PATH/scripts/run.sh"
elif [ -f "$SKILL_PATH/scripts/audit_codebase.sh" ]; then
    ENTRY_POINT="$SKILL_PATH/scripts/audit_codebase.sh"
elif [ -f "$SKILL_PATH/scripts/capture.js" ]; then
    ENTRY_POINT="$SKILL_PATH/scripts/capture.js"
else
    echo "Error: Standard entry point (run.sh, audit_codebase.sh, or capture.js) not found in $SKILL_PATH/scripts/"
    exit 1
fi

# 3. Execute Skill with Arguments
shift 2 # Remove 'run' and skill name from positional parameters
if [[ "$ENTRY_POINT" == *.js ]]; then
    node "$ENTRY_POINT" "$@"
else
    bash "$ENTRY_POINT" "$@"
fi
