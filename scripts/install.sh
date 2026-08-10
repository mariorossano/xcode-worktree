#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
INSTALL_BASE="${XCODE_WORKTREE_INSTALL_HOME:-$HOME}"
APP_SOURCE="$PROJECT_ROOT/dist/Xcode Worktree.app"
APP_DESTINATION="$INSTALL_BASE/Applications/Xcode Worktree.app"
EXPECTED_BUNDLE_ID="dev.xcodeworktree.app"
SKILL_NAME="xcode-worktree"

link_target_belongs_to_product() {
    local target="$1"
    [[ "$target" == "$PROJECT_ROOT" ]]
}

install_skill_link() {
    local profile_root="$1"
    local skills_root="$profile_root/skills"
    local destination="$skills_root/$SKILL_NAME"

    mkdir -p "$skills_root"

    if [[ -L "$destination" ]]; then
        if link_target_belongs_to_product "$(readlink "$destination")"; then
            if [[ "$(readlink "$destination")" != "$PROJECT_ROOT" ]]; then
                rm "$destination"
                ln -s "$PROJECT_ROOT" "$destination"
                echo "Updated skill link: $destination"
            else
                echo "Skill already linked: $destination"
            fi
        else
            echo "Refusing to replace unrelated symlink: $destination" >&2
            exit 1
        fi
    elif [[ -e "$destination" ]]; then
        echo "Refusing to replace existing path: $destination" >&2
        exit 1
    else
        ln -s "$PROJECT_ROOT" "$destination"
        echo "Installed skill: $destination"
    fi
}

looks_like_claude_profile() {
    local profile="$1"
    [[ -f "$profile/settings.json" || -f "$profile/.claude.json" || -d "$profile/skills" ]]
}

install_explicit_profile() {
    local profile="$1"
    if [[ ! -d "$profile" ]]; then
        echo "Agent profile does not exist: $profile" >&2
        exit 1
    fi
    install_skill_link "$(cd "$profile" && pwd -P)"
}

install_app() {
    if [[ ! -d "$APP_SOURCE" ]]; then
        echo "Missing app bundle: run 'make app' first." >&2
        exit 1
    fi

    local source_bundle_id
    source_bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_SOURCE/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$source_bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
        echo "Unexpected bundle identifier in built app: $APP_SOURCE" >&2
        exit 1
    fi

    mkdir -p "$INSTALL_BASE/Applications"

    if [[ -e "$APP_DESTINATION" ]]; then
        if [[ ! -d "$APP_DESTINATION" ]]; then
            echo "Refusing to replace non-directory path: $APP_DESTINATION" >&2
            exit 1
        fi

        local installed_bundle_id
        installed_bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$installed_bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
            echo "Refusing to replace an app with a different bundle identifier: $APP_DESTINATION" >&2
            exit 1
        fi
        rm -r "$APP_DESTINATION"
    fi

    ditto "$APP_SOURCE" "$APP_DESTINATION"
    codesign --verify --deep --strict "$APP_DESTINATION"
    echo "Installed app: $APP_DESTINATION"
}

install_app
install_skill_link "$INSTALL_BASE/.agents"

default_claude_profile="$INSTALL_BASE/.claude"
if [[ -d "$default_claude_profile" ]] && looks_like_claude_profile "$default_claude_profile"; then
    install_skill_link "$default_claude_profile"
fi

for profile in "$@"; do
    install_explicit_profile "$profile"
done

if [[ -n "${AGENT_PROFILE_DIRS:-}" ]]; then
    install_explicit_profile "$AGENT_PROFILE_DIRS"
fi

shopt -s nullglob
for profile in "$INSTALL_BASE"/.claude*; do
    destination="$profile/skills/$SKILL_NAME"
    if [[ "$profile" != "$default_claude_profile" ]] \
        && looks_like_claude_profile "$profile" \
        && [[ ! -L "$destination" ]]; then
        echo "Additional Claude profile found: $profile"
        echo "Install Xcode Worktree explicitly with: make install AGENT_PROFILE_DIRS=\"$profile\""
    fi
done

echo "Xcode Worktree installation complete. Re-run 'make install' after adding another agent profile."
