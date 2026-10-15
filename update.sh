#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

write_status() {
  local status="$1"
  local message="$2"
  local conflicts="${3:-}"
  mkdir -p "$repo_root/.t3"
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const [root, status, message, conflictText, pid] = process.argv.slice(1);
    const file = path.join(root, ".t3", "local-update-status.json");
    const payload = {
      status,
      message,
      conflicts: conflictText ? conflictText.split(/\r?\n/).filter(Boolean) : [],
      pid: Number(pid) || null,
      updatedAt: new Date().toISOString(),
    };
    const temporary = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(payload));
    fs.renameSync(temporary, file);
  ' "$repo_root" "$status" "$message" "$conflicts" "$$"
}

record_unexpected_failure() {
  local exit_code="$?"
  [[ "$exit_code" -eq 0 ]] && return
  local current_status
  current_status="$(node -e 'try { process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).status) } catch {}' "$repo_root/.t3/local-update-status.json" 2>/dev/null || true)"
  case "$current_status" in
    blocked|conflict|error) return ;;
  esac
  write_status error "The updater exited unexpectedly (code $exit_code). Retry to run it again." || true
}
trap record_unexpected_failure EXIT

fail() {
  local message="$1"
  local status="${2:-error}"
  local conflicts="${3:-}"
  write_status "$status" "$message" "$conflicts" || true
  printf 'update.sh: %s\n' "$message" >&2
  exit 1
}

write_status starting "Preparing the local fork update."

[[ "$(uname -s)" == "Darwin" ]] || fail "This installer currently supports macOS only."

case "$(uname -m)" in
  arm64) build_arch="arm64" ;;
  x86_64) build_arch="x64" ;;
  *) fail "Unsupported Mac architecture: $(uname -m)" ;;
esac

[[ "$(git branch --show-current)" == "main" ]] || fail "Switch to the local main branch before updating." blocked
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  unmerged_paths="$(git diff --name-only --diff-filter=U)"
  if [[ -n "$unmerged_paths" ]]; then
    fail "Resolve and commit the upstream merge before retrying." conflict "$unmerged_paths"
  fi
  dirty_paths="$( { git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } | sort -u )"
  fail "Commit or stash local changes before updating." blocked "$dirty_paths"
fi

upstream_remote="${T3CODE_UPSTREAM_REMOTE:-origin}"
upstream_branch="${T3CODE_UPSTREAM_BRANCH:-main}"
git remote get-url "$upstream_remote" >/dev/null 2>&1 ||
  fail "Git remote '$upstream_remote' was not found."

write_status fetching "Fetching $upstream_remote/$upstream_branch."
printf 'Fetching %s/%s...\n' "$upstream_remote" "$upstream_branch"
git fetch "$upstream_remote" "+refs/heads/$upstream_branch:refs/remotes/$upstream_remote/$upstream_branch"

write_status merging "Merging upstream changes into local main."
if ! git merge --no-edit "$upstream_remote/$upstream_branch"; then
  conflict_paths="$(git diff --name-only --diff-filter=U)"
  if [[ -n "$conflict_paths" ]]; then
    fail "Resolve and commit the upstream merge before retrying." conflict "$conflict_paths"
  fi
  fail "Could not merge upstream changes into local main." error
fi

rust_toolchain="${T3CODE_RUST_TOOLCHAIN:-1.95.0}"
rustup toolchain list | grep -Fq "$rust_toolchain-" ||
  fail "Rust $rust_toolchain is missing. Install it with: rustup toolchain install $rust_toolchain"

base_version="$(node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync("apps/desktop/package.json", "utf8")).version)')"
build_version="${base_version}-pr.local.$(date -u +%Y%m%d%H%M%S)"
build_dir="$repo_root/.t3/local-updates/$build_version"
mkdir -p "$build_dir"

printf 'Building %s for macOS %s...\n' "$build_version" "$build_arch"
write_status building "Building T3 Code Personal and T3 Code Work $build_version for macOS $build_arch."
RUSTUP_TOOLCHAIN="$rust_toolchain" \
  T3CODE_DESKTOP_UPDATE_REPOSITORY="pasangimhana/t3code" \
  node scripts/build-desktop-artifact.ts \
    --platform mac \
    --target dmg \
    --arch "$build_arch" \
    --build-version "$build_version" \
    --profile personal,work \
    --output-dir "$build_dir"

personal_dmg="$build_dir/T3-Code-Personal-$build_version-$build_arch.dmg"
work_dmg="$build_dir/T3-Code-Work-$build_version-$build_arch.dmg"
[[ -f "$personal_dmg" ]] || fail "Build completed without producing $personal_dmg."
[[ -f "$work_dmg" ]] || fail "Build completed without producing $work_dmg."
write_status installing "Preparing the app installations."

personal_app="/Applications/T3 Code Personal.app"
work_app="/Applications/T3 Code Work.app"
legacy_app="/Applications/T3 Code (Alpha).app"
backup_dir="$repo_root/.t3/fork-backups"
mkdir -p "$backup_dir"

# Cleanup state is newline-delimited rather than arrays: the desktop updater
# spawns this script through /bin/bash, which is still 3.2 on macOS.
cleanup_mounts=""
cleanup_staged=""
cleanup_backups=""

cleanup() {
  local mount_point staged_path restore_entry restore_target restore_backup
  while IFS= read -r mount_point; do
    [[ -n "$mount_point" ]] || continue
    hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
  done <<< "$cleanup_mounts"
  while IFS= read -r staged_path; do
    [[ -n "$staged_path" ]] || continue
    if [[ -e "$staged_path" ]]; then
      rm -rf "$staged_path"
    fi
  done <<< "$cleanup_staged"
  while IFS= read -r restore_entry; do
    [[ -n "$restore_entry" ]] || continue
    restore_target="${restore_entry%%|*}"
    restore_backup="${restore_entry#*|}"
    if [[ ! -e "$restore_target" && -e "$restore_backup" ]]; then
      mv "$restore_backup" "$restore_target" || true
    fi
  done <<< "$cleanup_backups"
}
trap cleanup EXIT

app_is_running() {
  # pgrep treats its pattern as an extended regex, so the legacy app's
  # parentheses must be escaped before an exact-name match.
  local pattern
  pattern="$(printf '%s' "$1" | sed 's/[][\\^$.*+?(){}|]/\\&/g')"
  pgrep -x "$pattern" >/dev/null 2>&1
}

quit_app() {
  local app_name="$1"
  local bundle_id="$2"
  app_is_running "$app_name" || return 0
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  local attempt
  for attempt in {1..30}; do
    app_is_running "$app_name" || return 0
    sleep 1
  done
  fail "$app_name is still open. Quit it and run update.sh again."
}

# Local preview builds are unsigned, and macOS ties TCC permissions (Screen
# Recording, Accessibility, ...) to the app's code signature. An unsigned app
# gets a new effective identity on every rebuild, so macOS drops the grants and
# re-prompts after each update. Signing the staged app with a stable local
# certificate keeps the designated requirement (bundle id + certificate) the
# same across updates, so permissions survive.
resolve_sign_identity() {
  if [[ -n "${T3CODE_LOCAL_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$T3CODE_LOCAL_SIGN_IDENTITY"
    return 0
  fi
  security find-identity -p codesigning 2>/dev/null |
    sed -n 's/.*"\(T3 Code Local Signing\)".*/\1/p' | head -n 1 || true
}

sign_app() {
  local app_path="$1"
  local identity
  identity="$(resolve_sign_identity)"
  if [[ -z "$identity" ]]; then
    printf 'warning: no "T3 Code Local Signing" codesigning identity; %s stays unsigned and macOS permissions will reset on the next update.\n' "$(basename "$app_path")" >&2
    return 0
  fi
  xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true
  codesign --force --deep --sign "$identity" "$app_path"
  codesign --verify --strict "$app_path"
}

last_backup_path=""

# Mount the DMG, ditto the app into a staging path in /Applications, verify the
# extracted bundle while the DMG is still attached, then swap it into place.
# The previous app is kept as a backup until the next update.
install_app() {
  local app_name="$1"
  local dmg_path="$2"
  local app_path="$3"
  local expected_bundle_id="$4"
  local mount_path="$build_dir/mounted-$app_name"
  local staged_app="/Applications/.$app_name.app-update-$$"
  local source_app
  local backup_path

  last_backup_path=""

  mkdir -p "$mount_path"
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_path" "$dmg_path" >/dev/null
  cleanup_mounts="${cleanup_mounts}${mount_path}"$'\n'

  source_app="$(find "$mount_path" -maxdepth 1 -type d -name '*.app' -print -quit)"
  [[ -n "$source_app" ]] || fail "The $app_name build contains no app bundle."

  rm -rf "$staged_app"
  ditto "$source_app" "$staged_app"
  cleanup_staged="${cleanup_staged}${staged_app}"$'\n'

  [[ "$(defaults read "$staged_app/Contents/Info" CFBundleIdentifier)" == "$expected_bundle_id" ]] ||
    fail "The $app_name build has an unexpected bundle identifier."
  [[ ! -e "$staged_app/Contents/Resources/app-update.yml" ]] ||
    fail "The local preview build for $app_name unexpectedly contains an auto-update feed."

  sign_app "$staged_app"

  hdiutil detach "$mount_path" -quiet

  if [[ -e "$app_path" ]]; then
    backup_path="$backup_dir/$app_name-before-$build_version.app"
    mv "$app_path" "$backup_path"
    last_backup_path="$backup_path"
    cleanup_backups="${cleanup_backups}${app_path}|${backup_path}"$'\n'
  fi

  if ! mv "$staged_app" "$app_path"; then
    if [[ -n "$last_backup_path" ]]; then
      mv "$last_backup_path" "$app_path"
      last_backup_path=""
    fi
    fail "Could not install the new $app_name app; the previous app was restored."
  fi
}

personal_was_running=0
work_was_running=0
legacy_was_running=0
if app_is_running "T3 Code Personal"; then personal_was_running=1; fi
if app_is_running "T3 Code Work"; then work_was_running=1; fi
if app_is_running "T3 Code (Alpha)"; then legacy_was_running=1; fi

# The legacy app shares the personal bundle identifier, so it must be quit
# before the personal app is replaced; a running legacy app counts as a running
# personal app for the relaunch.
if [[ "$legacy_was_running" == "1" ]]; then
  quit_app "T3 Code (Alpha)" "com.t3tools.t3code"
fi
if [[ "$personal_was_running" == "1" ]]; then
  quit_app "T3 Code Personal" "com.t3tools.t3code"
fi
if [[ "$work_was_running" == "1" ]]; then
  quit_app "T3 Code Work" "com.t3tools.t3code.work"
fi

if [[ "$legacy_was_running" == "1" || "$personal_was_running" == "1" || "$work_was_running" == "1" ]]; then
  write_status installing "Installing the builds and restarting T3 Code."
else
  write_status installing "Installing the builds."
fi

install_app "T3 Code Personal" "$personal_dmg" "$personal_app" "com.t3tools.t3code"
personal_backup="$last_backup_path"
install_app "T3 Code Work" "$work_dmg" "$work_app" "com.t3tools.t3code.work"
work_backup="$last_backup_path"

# Migration only after both installs succeed: the legacy app is never deleted,
# it moves into the same backup directory as the replaced profile apps.
legacy_backup=""
if [[ -e "$legacy_app" ]]; then
  legacy_backup="$backup_dir/T3Code-Alpha-before-$build_version.app"
  mv "$legacy_app" "$legacy_backup"
fi

if [[ "$legacy_was_running" == "1" || "$personal_was_running" == "1" ]]; then
  open -a "$personal_app"
fi
if [[ "$work_was_running" == "1" ]]; then
  open -a "$work_app"
fi

personal_version="$(defaults read "$personal_app/Contents/Info" CFBundleShortVersionString)"
work_version="$(defaults read "$work_app/Contents/Info" CFBundleShortVersionString)"
write_status complete "Installed T3 Code Personal $personal_version and T3 Code Work $work_version from local main."
printf 'Installed T3 Code Personal %s and T3 Code Work %s from local main.\n' "$personal_version" "$work_version"
printf 'The Personal app keeps using the existing T3 Code data directory; the Work app uses its own. Run ./update.sh to sync and rebuild again.\n'
[[ -z "$personal_backup" ]] || printf 'Previous Personal app backup: %s\n' "$personal_backup"
[[ -z "$work_backup" ]] || printf 'Previous Work app backup: %s\n' "$work_backup"
[[ -z "$legacy_backup" ]] || printf 'Legacy T3 Code (Alpha) app moved to: %s\n' "$legacy_backup"
