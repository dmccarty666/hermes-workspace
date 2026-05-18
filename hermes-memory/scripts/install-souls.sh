#!/usr/bin/env bash
# install-souls.sh — sync project SOULs into each profile's Hermes home.
#
# The source of truth for hermes-memory's specialist SOULs lives in:
#   ~/.hermes/PROJECTS/hermes-memory/souls/hm-<role>.md
#
# Hermes auto-loads SOUL.md from each profile home as the agent identity
# (see website/docs/developer-guide/prompt-assembly.md). This script copies
# the project-controlled SOULs into the per-profile directories so the
# workers spawned by the Kanban dispatcher pick them up.
#
# Re-run any time a SOUL is updated in PROJECTS/hermes-memory/souls/. It
# overwrites the installed copies (they are runtime artifacts; source lives
# in PROJECTS/).
#
# Usage:
#   ./install-souls.sh           # install all 5 hm-* SOULs
#   ./install-souls.sh hm-developer hm-qa   # install specific ones
#   ./install-souls.sh --dry-run            # show what would happen
#   ./install-souls.sh --check              # verify installed copies match source

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOULS_DIR="${PROJECT_DIR}/souls"
PROFILES_ROOT="${HOME}/.hermes/profiles"

ALL_PROFILES=(hm-orchestrator hm-planner hm-architect hm-developer hm-qa hm-docs hm-auditor)

dry_run=0
check_only=0
declare -a selected_profiles=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --check)   check_only=1 ;;
        --help|-h)
            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        hm-*)
            selected_profiles+=("$arg") ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2 ;;
    esac
done

if [[ ${#selected_profiles[@]} -eq 0 ]]; then
    selected_profiles=("${ALL_PROFILES[@]}")
fi

errors=0

for profile in "${selected_profiles[@]}"; do
    source="${SOULS_DIR}/${profile}.md"
    dest_dir="${PROFILES_ROOT}/${profile}"
    dest="${dest_dir}/SOUL.md"

    if [[ ! -f "$source" ]]; then
        echo "❌ Missing source SOUL: $source" >&2
        ((errors++))
        continue
    fi

    if [[ ! -d "$dest_dir" ]]; then
        echo "⚠️  Profile dir not found: $dest_dir"
        echo "    Run:  hermes profile create $profile --clone"
        echo "    (or skip with: ./install-souls.sh $(echo "${selected_profiles[@]}" | sed "s/$profile//"))"
        ((errors++))
        continue
    fi

    if [[ $check_only -eq 1 ]]; then
        if [[ -f "$dest" ]] && cmp -s "$source" "$dest"; then
            echo "✅ $profile  in sync"
        else
            echo "⚠️  $profile  OUT OF SYNC"
            ((errors++))
        fi
        continue
    fi

    if [[ $dry_run -eq 1 ]]; then
        echo "would install: $source  →  $dest"
        continue
    fi

    cp "$source" "$dest"
    echo "✅ $profile  ←  souls/${profile}.md"
done

if [[ $errors -gt 0 ]]; then
    exit 1
fi

if [[ $check_only -eq 1 ]]; then
    echo
    echo "All checked SOULs in sync with PROJECTS/hermes-memory/souls/"
elif [[ $dry_run -eq 0 ]]; then
    echo
    echo "Done. ${#selected_profiles[@]} SOUL(s) installed."
    echo
    echo "Verify a worker picks up the SOUL:"
    echo "  hermes -p ${selected_profiles[0]} chat -q 'Who are you in 1 line?'"
fi
