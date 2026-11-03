#!/bin/bash
#
# Release helper updates versions, commits/pushes, and tags. Pushing tags triggers GitHub Actions
# build/sign/notarize/Sparkle appcast/Release publication; this script does not build locally.
#
# Usage:
# scripts/release.sh: interactive release with per-step confirmation.
# scripts/release.sh --dry-run: preview actions without changing anything.
#
# Version source: ServerDock/Info.plist only.
# CFBundleShortVersionString is the display version, e.g. 0.9.2.
# CFBundleVersion is an increasing integer, e.g. 28, used by Sparkle update comparison.
#
# Tags use v<display-version>; annotated notes appear in the software-update UI.
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/ServerDock/Info.plist"
DEFAULT_BRANCH="main"
DRY_RUN=0
case "${1:-}" in
    --dry-run|-n) DRY_RUN=1 ;;
    "")           ;;
    *)            echo "Unknown argument: $1(usage: release.sh [--dry-run])" >&2; exit 2 ;;
esac

# Logging helpers.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi
section() { printf '\n%s━━ %s %s━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD$BLU" "$1" "$DIM" "$RST"; }
info()    { printf '    %s%s%s\n' "$DIM" "$1" "$RST"; }
ok()      { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
warn()    { printf '    %s⚠%s  %s\n' "$YLW" "$RST" "$1"; }
die()     { printf '\n%s✗ %s%s\n' "$BOLD$RED" "$1" "$RST" >&2; exit 1; }

trap 'die "Error on line $LINENO; stopped. Review completed steps manually (see output above)."' ERR

# Print then execute commands, or print only during dry-run.
run() {
    printf '    %s$ %s%s\n' "$DIM" "$*" "$RST"
    [ "$DRY_RUN" = 1 ] && return 0
    "$@"
}

# Require yes to proceed; dry-run prints/skips confirmation automatically.
confirm() {
    if [ "$DRY_RUN" = 1 ]; then info "[dry-run] Would ask for confirmation: $1"; return 0; fi
    local reply
    printf '%s%s%s [y/N] ' "$BOLD" "$1" "$RST"
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) die "Canceled." ;; esac
}

# Preflight.
section "Preflight"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN mode: print only; no file changes, commits, or pushes."
command -v git >/dev/null || die "git not found."
[ -f "$PLIST" ] || die "$PLIST not found."
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "The current directory is not a Git repository."

CUR_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
CUR_MARKETING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CUR_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
info "Branch: $CUR_BRANCH"
info "Current version: $CUR_MARKETING(build $CUR_BUILD)"

if [ "$CUR_BRANCH" != "$DEFAULT_BRANCH" ]; then
    warn "Not currently on $DEFAULT_BRANCH."
    confirm "Release from $CUR_BRANCH anyway?"
fi

# Enter the new version.
section "New version"
info "Versioning: PATCH=bug fixes, MINOR=new features, MAJOR=breaking changes."
printf '%sMarketing version%s(current %s): ' "$BOLD" "$RST" "$CUR_MARKETING"
read -r NEW_MARKETING
[ -n "$NEW_MARKETING" ] || die "No version entered."
echo "$NEW_MARKETING" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' \
    || die "Expected X.Y / X.Y.Z / X.Y.Z.W (Mac App Store accepts at most three components); received: $NEW_MARKETING"

SUGGEST_BUILD=$((CUR_BUILD + 1))
printf '%sBuild number%s(must be > %s; press Enter to use the suggested value %s): ' "$BOLD" "$RST" "$CUR_BUILD" "$SUGGEST_BUILD"
read -r NEW_BUILD
[ -n "$NEW_BUILD" ] || NEW_BUILD="$SUGGEST_BUILD"
echo "$NEW_BUILD" | grep -Eq '^[0-9]+$' || die "Build number must be an integer; received: $NEW_BUILD"
[ "$NEW_BUILD" -gt "$CUR_BUILD" ] || die "Build number $NEW_BUILD must exceed $CUR_BUILD; otherwise users will not receive the update."

TAG="v$NEW_MARKETING"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "Tag $TAG already exists locally."
git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q "$TAG" && die "Tag $TAG already exists remotely."
ok "Target version: $NEW_MARKETING(build $NEW_BUILD), tag $TAG"

# Release notes come from CHANGELOG.md Unreleased, opening an editor if empty.
section "Release notes"
CHANGELOG="$ROOT/CHANGELOG.md"
[ -f "$CHANGELOG" ] || die "$CHANGELOG not found."

# Nonempty lines between Unreleased and the next ## [ heading.
UNREL="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$CHANGELOG" | sed '/^[[:space:]]*$/d')"

if [ -n "$UNREL" ]; then
    info "Loaded from [Unreleased] in CHANGELOG.md."
    RAW="$UNREL"
else
    warn "[Unreleased] in CHANGELOG.md is empty; opening ${EDITOR:-vi} to write release notes."
    NOTES_FILE="$(mktemp -t serverdock-release-notes)"
    {
        echo ""
        echo "# One change per line; written to CHANGELOG.md and shown in the software update dialog."
        echo "# Lines starting with # are ignored; empty notes abort the release. Version $NEW_MARKETING(build $NEW_BUILD)"
    } > "$NOTES_FILE"
    if [ "$DRY_RUN" = 1 ]; then
        RAW="(dry-run placeholder release notes)"
    else
        "${EDITOR:-vi}" "$NOTES_FILE"
        RAW="$(grep -v '^#' "$NOTES_FILE" | sed '/^[[:space:]]*$/d')"
    fi
    rm -f "$NOTES_FILE"
    [ -n "$RAW" ] || die "Release notes are empty; stopped."
fi

# NOTES is one-entry-per-line plain text for tags/releases/appcast; BULLETS is the changelog list.
NOTES="$(printf '%s\n' "$RAW" | sed 's/^[[:space:]]*-[[:space:]]*//')"
BULLETS="$(printf '%s\n' "$NOTES" | sed 's/^/- /')"
TAG_NOTES_FILE="$(mktemp -t serverdock-tag-notes)"
trap 'rm -f "$TAG_NOTES_FILE"' EXIT
printf '%s\n' "$NOTES" > "$TAG_NOTES_FILE"

echo "$DIM------ Release notes preview ------$RST"
printf '%s\n' "$BULLETS"
echo "$DIM-------------------------$RST"

# Confirm the complete operation.
section "Upcoming actions"
info "Update Info.plist: $CUR_MARKETING/$CUR_BUILD  →  $NEW_MARKETING/$NEW_BUILD"
info "Commit all changes (git add -A) and push to $CUR_BRANCH"
info "Create and push annotated tag $TAG -> trigger the GitHub Actions release workflow"
echo
git status --short || true
echo
confirm "Start now?"

# Write version numbers.
section "Update version numbers"
run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_MARKETING" "$PLIST"
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
ok "Info.plist updated."

# Archive Unreleased under ## [version] - date, leaving a new empty Unreleased above.
DATE="$(date +%F)"
if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] Would archive [Unreleased] in CHANGELOG.md as ## [$NEW_MARKETING] - $DATE"
else
    NEW_BLOCK="$(printf '## [Unreleased]\n\n## [%s] - %s\n%s\n' "$NEW_MARKETING" "$DATE" "$BULLETS")" \
    awk 'BEGIN{blk=ENVIRON["NEW_BLOCK"]}
         /^## \[Unreleased\]/{print blk; print ""; skip=1; next}
         skip && /^## \[/{skip=0}
         skip{next}
         {print}' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"
    ok "Archived $NEW_MARKETING ($DATE) in CHANGELOG.md."
fi

# Commit.
section "Commit changes"
run git add -A
[ "$DRY_RUN" = 1 ] || git --no-pager diff --cached --stat
confirm "Commit the changes above as release: $NEW_MARKETING; continue?"
COMMIT_MSG="$(printf 'release: %s(build %s)\n\n%s\n' "$NEW_MARKETING" "$NEW_BUILD" "$NOTES")"
run git commit -m "$COMMIT_MSG"
ok "Committed."

# Push commit.
section "Push commit"
confirm "Push to origin/$CUR_BRANCH?"
run git push origin "$CUR_BRANCH"
ok "Commit pushed."

# Create/push the tag to start release publication.
section "Create and push tag"
run git tag -a "$TAG" -F "$TAG_NOTES_FILE"
ok "Created tag $TAG."
confirm "Push tag $TAG? (This triggers the CI release workflow.)"
run git push origin "$TAG"
ok "Tag pushed; CI will start shortly."

# Completion notice.
REPO_SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
section "Done"
ok "Release triggered. Monitor and verify:"
info "Actions： https://github.com/$REPO_SLUG/actions"
info "Releases：https://github.com/$REPO_SLUG/releases"
FEED_URL=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")
info "appcast: $FEED_URL (should show $NEW_MARKETING / build $NEW_BUILD)"
echo
info "If CI fails, no Release/appcast is published. Fix the issue and release a higher version,"
info "or delete the tag and retry: git tag -d $TAG && git push origin :refs/tags/$TAG"
