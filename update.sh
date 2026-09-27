#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

fail() {
  printf 'update.sh: %s\n' "$1" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This installer currently supports macOS only."

case "$(uname -m)" in
  arm64) build_arch="arm64" ;;
  x86_64) build_arch="x64" ;;
  *) fail "Unsupported Mac architecture: $(uname -m)" ;;
esac

[[ "$(git branch --show-current)" == "main" ]] || fail "Switch to the local main branch before updating."
[[ -z "$(git status --porcelain --untracked-files=all)" ]] ||
  fail "Commit or stash local changes before updating."

upstream_remote="${T3CODE_UPSTREAM_REMOTE:-origin}"
upstream_branch="${T3CODE_UPSTREAM_BRANCH:-main}"
git remote get-url "$upstream_remote" >/dev/null 2>&1 ||
  fail "Git remote '$upstream_remote' was not found."

printf 'Fetching %s/%s...\n' "$upstream_remote" "$upstream_branch"
git fetch "$upstream_remote" "+refs/heads/$upstream_branch:refs/remotes/$upstream_remote/$upstream_branch"

if ! git merge --no-edit "$upstream_remote/$upstream_branch"; then
  fail "Upstream changes conflicted. Resolve them on main, commit the merge, then rerun."
fi

rust_toolchain="${T3CODE_RUST_TOOLCHAIN:-1.95.0}"
rustup toolchain list | grep -Fq "$rust_toolchain-" ||
  fail "Rust $rust_toolchain is missing. Install it with: rustup toolchain install $rust_toolchain"

base_version="$(node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync("apps/desktop/package.json", "utf8")).version)')"
build_version="${base_version}-pr.local.$(date -u +%Y%m%d%H%M%S)"
build_dir="$repo_root/.t3/local-updates/$build_version"
mkdir -p "$build_dir"

printf 'Building %s for macOS %s...\n' "$build_version" "$build_arch"
RUSTUP_TOOLCHAIN="$rust_toolchain" \
  T3CODE_DESKTOP_UPDATE_REPOSITORY="pasangimhana/t3code" \
  node scripts/build-desktop-artifact.ts \
    --platform mac \
    --target dmg \
    --arch "$build_arch" \
    --build-version "$build_version" \
    --output-dir "$build_dir"

dmg_path="$build_dir/T3-Code-$build_version-$build_arch.dmg"
[[ -f "$dmg_path" ]] || fail "Build completed without producing $dmg_path."

app_path="/Applications/T3 Code (Alpha).app"
mount_path="$build_dir/mounted"
staged_app="/Applications/.T3 Code (Alpha).app-update-$$"
backup_path=""
mounted=0

cleanup() {
  if [[ "$mounted" == "1" ]]; then
    hdiutil detach "$mount_path" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "$backup_path" && ! -e "$app_path" && -e "$backup_path" ]]; then
    mv "$backup_path" "$app_path" || true
  fi
  if [[ -e "$staged_app" ]]; then
    rm -rf "$staged_app"
  fi
}
trap cleanup EXIT

mkdir -p "$mount_path"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_path" "$dmg_path" >/dev/null
mounted=1

source_app="$(find "$mount_path" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$source_app" ]] || fail "The built DMG contains no app bundle."
[[ "$(defaults read "$source_app/Contents/Info" CFBundleIdentifier)" == "com.t3tools.t3code" ]] ||
  fail "The built app has an unexpected bundle identifier."
[[ ! -e "$source_app/Contents/Resources/app-update.yml" ]] ||
  fail "The local preview build unexpectedly contains an auto-update feed."

ditto "$source_app" "$staged_app"
hdiutil detach "$mount_path" -quiet
mounted=0

if pgrep -x "T3 Code (Alpha)" >/dev/null 2>&1; then
  osascript -e 'tell application id "com.t3tools.t3code" to quit' >/dev/null 2>&1 || true
  for _ in {1..30}; do
    pgrep -x "T3 Code (Alpha)" >/dev/null 2>&1 || break
    sleep 1
  done
  pgrep -x "T3 Code (Alpha)" >/dev/null 2>&1 &&
    fail "T3 Code is still open. Quit it and run update.sh again."
fi

if [[ -e "$app_path" ]]; then
  backup_dir="$repo_root/.t3/fork-backups"
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/T3Code-Alpha-before-$build_version.app"
  mv "$app_path" "$backup_path"
fi

if ! mv "$staged_app" "$app_path"; then
  [[ -z "$backup_path" ]] || mv "$backup_path" "$app_path"
  fail "Could not install the new app; the previous app was restored."
fi

open -a "$app_path"
installed_version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
printf 'Installed T3 Code %s from local main.\n' "$installed_version"
printf 'The app uses the existing T3 Code data directory. Run ./update.sh to sync and rebuild again.\n'
[[ -z "$backup_path" ]] || printf 'Previous app backup: %s\n' "$backup_path"
