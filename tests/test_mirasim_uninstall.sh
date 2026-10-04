#!/usr/bin/env bash
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/mirasim-uninstall.sh"
TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd -P "$TEST_ROOT" && pwd -P)
TEST_PROCESS_PID=
trap '[ -z "$TEST_PROCESS_PID" ] || /bin/kill "$TEST_PROCESS_PID" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"
export HOME="$TEST_HOME"
export MIRASIM_UNINSTALL_OS_NAME=Darwin

LAST_OUTPUT=
LAST_EXIT=0

run_case() {
  local name=$1
  shift
  if LAST_OUTPUT=$("$@" 2>&1); then
    LAST_EXIT=0
  else
    LAST_EXIT=$?
  fi
  printf '%s: exit %s\n' "$name" "$LAST_EXIT"
}

assert_exit() {
  local expected=$1
  shift
  run_case "$*" "$@"
  if [ "$LAST_EXIT" -ne "$expected" ]; then
    printf 'FAIL: expected exit %s, got %s\n%s\n' "$expected" "$LAST_EXIT" "$LAST_OUTPUT" >&2
    exit 1
  fi
}

assert_contains() {
  case "$LAST_OUTPUT" in
    *"$1"*) ;;
    *) printf 'FAIL: missing output: %s\n%s\n' "$1" "$LAST_OUTPUT" >&2; exit 1 ;;
  esac
}

assert_excludes() {
  case "$LAST_OUTPUT" in
    *"$1"*) printf 'FAIL: unexpected output: %s\n%s\n' "$1" "$LAST_OUTPUT" >&2; exit 1 ;;
  esac
}

assert_path_exists() {
  [ -e "$1" ] || { printf 'FAIL: missing path: %s\n' "$1" >&2; exit 1; }
}

assert_path_missing() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || { printf 'FAIL: unexpected path: %s\n' "$1" >&2; exit 1; }
}

isolated_uninstall() {
  isolated_uninstall_mode normal "$@"
}

isolated_uninstall_mode() {
  local test_mode=$1
  shift
  /bin/bash -c '
    source "$1"
    fixture_root=$2
    test_mode=$3
    is_mirasim_app() {
      [ "$1" != /Applications/Mirasim.app ] || return 1
      [ -f "$1/Contents/Info.plist" ] && [ ! -L "$1" ] &&
        [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null)" = ai.mirofish.mirasim ]
    }
    launchd_roots() {
      printf "%s\n" "$HOME/Library/LaunchAgents" "$fixture_root/system/LaunchAgents" "$fixture_root/system/LaunchDaemons"
    }
    is_system_launchd_plist() {
      case "$1" in "$fixture_root/system/LaunchAgents/"*|"$fixture_root/system/LaunchDaemons/"*) return 0 ;; esac
      return 1
    }
    case "$test_mode" in
      survivor) stop_verified_processes() { :; } ;;
      swap_parent) stop_verified_processes() {
        /bin/mv "$HOME/Library/Application Support" "$HOME/Library/Application Support.original"
        /bin/ln -s "$fixture_root/foreign-support" "$HOME/Library/Application Support"
      } ;;
      system_unprivileged) is_privileged() { return 1; } ;;
      system_privileged) is_privileged() { return 0; } ;;
    esac
    main "${@:4}"
  ' _ "$SCRIPT" "$TEST_ROOT" "$test_mode" --uninstall "$@"
}

assert_exit 0 "$SCRIPT" --help
assert_exit 1 env MIRASIM_UNINSTALL_OS_NAME=Linux "$SCRIPT" --check
assert_exit 1 "$SCRIPT" --uninstall --yes --check
assert_exit 1 "$SCRIPT" --check --scan-root "$TEST_HOME/not-a-directory"
assert_exit 0 "$SCRIPT"
assert_contains 'Mode: check'
assert_contains "Scan root: $TEST_HOME"
assert_path_missing "$TEST_ROOT/report.txt"
assert_exit 0 "$SCRIPT" --check --report "$TEST_ROOT/report.txt"
assert_path_exists "$TEST_ROOT/report.txt"
printf 'keep regular\n' > "$TEST_ROOT/existing.txt"
assert_exit 1 "$SCRIPT" --check --report "$TEST_ROOT/existing.txt"
[ "$(< "$TEST_ROOT/existing.txt")" = 'keep regular' ] || { printf 'FAIL: existing report was overwritten\n' >&2; exit 1; }
printf 'keep target\n' > "$TEST_ROOT/target.txt"
ln -s "$TEST_ROOT/target.txt" "$TEST_ROOT/report-link.txt"
assert_exit 1 "$SCRIPT" --check --report "$TEST_ROOT/report-link.txt"
[ -L "$TEST_ROOT/report-link.txt" ] || { printf 'FAIL: report symlink was replaced\n' >&2; exit 1; }
[ "$(< "$TEST_ROOT/target.txt")" = 'keep target' ] || { printf 'FAIL: report symlink target was overwritten\n' >&2; exit 1; }
assert_exit 1 "$SCRIPT" --yes
assert_exit 1 "$SCRIPT" --check --check
assert_exit 1 "$SCRIPT" --scan-root
assert_exit 1 "$SCRIPT" --unknown
printf 'PASS: CLI contract\n'

TEST_HOME="$TEST_ROOT/read-only-home"
SCAN_ROOT="$TEST_HOME/projects"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim/skills/demo" "$TEST_HOME/.claude" "$TEST_HOME/.agents" "$SCAN_ROOT/project/.mirasim"
printf 'skill data\n' > "$TEST_HOME/.mirasim/skills/demo/SKILL.md"
printf 'project state\n' > "$SCAN_ROOT/project/.mirasim/state"
ln -s ../.mirasim/skills "$TEST_HOME/.claude/skills"
ln -s ../.mirasim/skills "$TEST_HOME/.agents/skills"
before=$(cd "$TEST_HOME" && /usr/bin/find -P . -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/stat -f '%N:%p:%u:%g:%f:%m:%z:%i:%Y')
before_acls=$(cd "$TEST_HOME" && /usr/bin/find -P . -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /bin/ls -ldeOn)
before_xattrs=$(cd "$TEST_HOME" && /usr/bin/find -P . -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/xattr -l -s -v -x)
before_hashes=$(cd "$TEST_HOME" && /usr/bin/find -P . -type f -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256)
assert_exit 0 "$SCRIPT" --check --scan-root "$SCAN_ROOT" --report "$TEST_ROOT/read-only-report.txt"
after=$(cd "$TEST_HOME" && /usr/bin/find -P . -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/stat -f '%N:%p:%u:%g:%f:%m:%z:%i:%Y')
after_acls=$(cd "$TEST_HOME" && /usr/bin/find -P . -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /bin/ls -ldeOn)
after_xattrs=$(cd "$TEST_HOME" && /usr/bin/find -P . -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/xattr -l -s -v -x)
after_hashes=$(cd "$TEST_HOME" && /usr/bin/find -P . -type f -print0 | LC_ALL=C /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256)
[ "$before" = "$after" ] || { printf 'FAIL: --check changed fixture objects\n' >&2; exit 1; }
[ "$before_acls" = "$after_acls" ] || { printf 'FAIL: --check changed fixture permissions or ACLs\n' >&2; exit 1; }
[ "$before_xattrs" = "$after_xattrs" ] || { printf 'FAIL: --check changed fixture extended attributes\n' >&2; exit 1; }
[ "$before_hashes" = "$after_hashes" ] || { printf 'FAIL: --check changed fixture file contents\n' >&2; exit 1; }
assert_path_exists "$TEST_ROOT/read-only-report.txt"
[ -L "$TEST_HOME/.claude/skills" ] && [ -L "$TEST_HOME/.agents/skills" ] || { printf 'FAIL: --check changed Skills links\n' >&2; exit 1; }
printf 'PASS: check mode preserves fixture objects\n'

TEST_HOME="$TEST_ROOT/home"
export HOME="$TEST_HOME"
SCAN_ROOT="$TEST_ROOT/projects"
mkdir -p "$TEST_HOME/.mirasim/app/0.0.182" \
  "$TEST_HOME/.mirasim/updates" \
  "$TEST_HOME/.mirasim/skills/demo" \
  "$TEST_HOME/Library/Application Support/@mirasim" \
  "$TEST_HOME/Library/Preferences" \
  "$TEST_HOME/Applications/Mirasim.app/Contents" \
  "$TEST_HOME/Applications/Unrelated.app/Contents" \
  "$SCAN_ROOT/project-a/.mirasim" \
  "$SCAN_ROOT/project-a/not-mirasim" \
  "$SCAN_ROOT/node_modules/pkg/.mirasim"
printf '%s\n' '{"mirachannelToken":"secret","mirachannelE2eKey":"secret","note":"e2eValueMustNotLeak","other":"mirachannelValueMustNotLeak"}' > "$TEST_HOME/.mirasim/setting.json"
printf '%s\n' '{"nodeId":"secret","other":"e2eAnotherValueMustNotLeak"}' > "$TEST_HOME/.mirasim/mirachannel-discovery.json"
printf 'x' > "$TEST_HOME/Library/Preferences/ai.mirofish.mirasim.plist"
printf 'x' > "$TEST_HOME/Library/Preferences/com.example.mirror.plist"
printf 'x' > "$TEST_HOME/.mirasim/updates/pending-update"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.mirofish.mirasim</string><key>CFBundleShortVersionString</key><string>0.0.182</string></dict></plist>' > "$TEST_HOME/Applications/Mirasim.app/Contents/Info.plist"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.unrelated</string></dict></plist>' > "$TEST_HOME/Applications/Unrelated.app/Contents/Info.plist"
ln -s "$SCAN_ROOT/project-a/.mirasim" "$SCAN_ROOT/linked-mirasim"

assert_exit 0 "$SCRIPT" --check --scan-root "$SCAN_ROOT"
assert_contains "$TEST_HOME/.mirasim"
assert_contains "$TEST_HOME/.mirasim/app/0.0.182"
assert_contains "$TEST_HOME/.mirasim/updates/pending-update"
assert_contains "$TEST_HOME/Library/Application Support/@mirasim"
assert_contains "$TEST_HOME/Library/Preferences/ai.mirofish.mirasim.plist"
assert_contains "$TEST_HOME/Applications/Mirasim.app"
assert_contains "$SCAN_ROOT/project-a/.mirasim"
assert_contains 'mirachannelToken'
assert_contains 'mirachannelE2eKey'
assert_contains 'nodeId'
assert_excludes 'secret'
assert_excludes 'e2eValueMustNotLeak'
assert_excludes 'mirachannelValueMustNotLeak'
assert_excludes 'e2eAnotherValueMustNotLeak'
assert_contains 'Bundle ID: ai.mirofish.mirasim Version: 0.0.182'
assert_contains 'pending-update (size: 1 bytes; modified:'
assert_contains 'setting.json (size:'
assert_excludes 'com.example.mirror.plist'
assert_excludes 'not-mirasim'
assert_excludes 'node_modules/pkg/.mirasim'
assert_excludes 'linked-mirasim'
assert_excludes "$TEST_HOME/Applications/Unrelated.app"
assert_path_exists "$TEST_HOME/.mirasim/setting.json"
assert_path_exists "$SCAN_ROOT/project-a/.mirasim"
printf 'PASS: discovery and secret-safe report\n'

mkdir -p "$TEST_ROOT/bin"
printf '%s\n' '#!/bin/sh' 'if [ "$5" = Apodex ]; then printf "keychain: matched\nSHA-1 hash: 0123456789ABCDEF0123456789ABCDEF01234567\n"; fi' > "$TEST_ROOT/bin/security"
chmod +x "$TEST_ROOT/bin/security"
PATH="$TEST_ROOT/bin:$PATH" assert_exit 0 "$SCRIPT" --check --scan-root "$SCAN_ROOT"
assert_contains "Keychain certificate: Apodex SHA-1: 0123456789ABCDEF0123456789ABCDEF01234567 Keychain: $TEST_HOME/Library/Keychains/login.keychain-db"
assert_contains 'Keychain: /Library/Keychains/System.keychain'
assert_contains 'security delete-certificate -Z 0123456789ABCDEF0123456789ABCDEF01234567'
assert_contains 'manual deletion: sudo security delete-certificate -Z 0123456789ABCDEF0123456789ABCDEF01234567 /Library/Keychains/System.keychain'
printf 'PASS: certificate review names\n'

mkdir -p "$TEST_ROOT/external/.mirasim" "$TEST_ROOT/external/mirofish.data"
ln -s "$TEST_ROOT/external" "$TEST_HOME/Library/Caches"
ln -s "$TEST_ROOT" "$TEST_ROOT/alias"
assert_exit 1 "$SCRIPT" --check --scan-root "$TEST_ROOT/alias/projects"
ln -s "$TEST_HOME" "$TEST_ROOT/home-alias"
assert_exit 1 env HOME="$TEST_ROOT/home-alias" "$SCRIPT" --check --scan-root "$SCAN_ROOT"
assert_exit 0 "$SCRIPT" --check --scan-root "$SCAN_ROOT"
assert_excludes "$TEST_HOME/Library/Caches/mirofish.data"
printf 'PASS: symlink ancestor boundaries\n'

mkdir -p "$TEST_ROOT/relative-bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TEST_HOME/.mirasim/app/0.0.182/mirasim"
chmod +x "$TEST_HOME/.mirasim/app/0.0.182/mirasim"
ln -s "$TEST_HOME/.mirasim/app/0.0.182/mirasim" "$TEST_ROOT/relative-bin/mirasim"
assert_exit 0 /bin/sh -c 'cd "$1" && PATH="relative-bin:$PATH" "$2" --check --scan-root "$3"' _ "$TEST_ROOT" "$SCRIPT" "$SCAN_ROOT"
assert_excludes 'Delete candidate: relative-bin/mirasim'
printf 'PASS: absolute deletion candidates\n'

printf '%s\n' '#!/bin/sh' '[ "$GIT_OPTIONAL_LOCKS" = 0 ] || printf "unsafe\n" > "$GIT_TEST_MARKER"' 'case "$*" in *rev-parse*) printf "true\n" ;; esac' 'exit 0' > "$TEST_ROOT/bin/git"
chmod +x "$TEST_ROOT/bin/git"
GIT_TEST_MARKER="$TEST_ROOT/git-lock-marker" PATH="$TEST_ROOT/bin:$PATH" assert_exit 0 "$SCRIPT" --check --scan-root "$SCAN_ROOT"
assert_path_missing "$TEST_ROOT/git-lock-marker"
printf 'PASS: Git read-only mode\n'

TEST_HOME="$TEST_ROOT/recovery-home"
SCAN_ROOT="$TEST_ROOT/recovery-projects"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim/skills/demo" "$TEST_HOME/.claude" "$TEST_HOME/.agents" "$SCAN_ROOT"
printf 'skill data\n' > "$TEST_HOME/.mirasim/skills/demo/SKILL.md"
ln -s ../.mirasim/skills "$TEST_HOME/.claude/skills"
ln -s ../.mirasim/skills "$TEST_HOME/.agents/skills"
assert_exit 0 isolated_uninstall --yes --backup-dir "$TEST_ROOT/backup" --scan-root "$SCAN_ROOT"
[ -d "$TEST_HOME/.claude/skills" ] && [ ! -L "$TEST_HOME/.claude/skills" ] || { printf 'FAIL: Claude Skills was not restored as a real directory\n' >&2; exit 1; }
[ -d "$TEST_HOME/.agents/skills" ] && [ ! -L "$TEST_HOME/.agents/skills" ] || { printf 'FAIL: Agent Skills was not restored as a real directory\n' >&2; exit 1; }
[ "$(< "$TEST_HOME/.claude/skills/demo/SKILL.md")" = 'skill data' ] || { printf 'FAIL: Claude Skills content changed\n' >&2; exit 1; }
[ "$(< "$TEST_HOME/.agents/skills/demo/SKILL.md")" = 'skill data' ] || { printf 'FAIL: Agent Skills content changed\n' >&2; exit 1; }
assert_path_exists "$TEST_ROOT/backup/mirasim-skills/demo/SKILL.md"
assert_path_exists "$TEST_ROOT/backup/skills.sha256"
printf 'PASS: taken-over Skills recovery\n'

TEST_HOME="$TEST_ROOT/equivalent-link-home"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim/skills/demo" "$TEST_HOME/.claude" "$TEST_HOME/.agents" "$SCAN_ROOT"
printf 'skill data\n' > "$TEST_HOME/.mirasim/skills/demo/SKILL.md"
ln -s ../.mirasim/skills/ "$TEST_HOME/.claude/skills"
ln -s ../.mirasim/skills/. "$TEST_HOME/.agents/skills"
assert_exit 0 isolated_uninstall --yes --backup-dir "$TEST_ROOT/equivalent-backup" --scan-root "$SCAN_ROOT"
[ -d "$TEST_HOME/.claude/skills" ] && [ ! -L "$TEST_HOME/.claude/skills" ] || { printf 'FAIL: trailing-slash Skills link was not restored\n' >&2; exit 1; }
[ -d "$TEST_HOME/.agents/skills" ] && [ ! -L "$TEST_HOME/.agents/skills" ] || { printf 'FAIL: dot-suffix Skills link was not restored\n' >&2; exit 1; }
assert_path_exists "$TEST_HOME/.claude/skills/demo/SKILL.md"
assert_path_exists "$TEST_HOME/.agents/skills/demo/SKILL.md"
printf 'PASS: equivalent Skills link spelling\n'

TEST_HOME="$TEST_ROOT/root-link-home"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim/skills" "$TEST_HOME/.claude" "$SCAN_ROOT"
ln -s /. "$TEST_HOME/.claude/skills"
assert_exit 3 isolated_uninstall --yes --backup-dir "$TEST_ROOT/root-link-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/.mirasim/skills"
[ -L "$TEST_HOME/.claude/skills" ] || { printf 'FAIL: root-target Skills link changed\n' >&2; exit 1; }
printf 'PASS: root-target Skills gate\n'

TEST_HOME="$TEST_ROOT/dangling-home"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim" "$TEST_HOME/.claude" "$SCAN_ROOT"
ln -s ../.mirasim/skills "$TEST_HOME/.claude/skills"
assert_exit 3 isolated_uninstall --yes --backup-dir "$TEST_ROOT/dangling-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/.mirasim"
[ -L "$TEST_HOME/.claude/skills" ] || { printf 'FAIL: dangling Skills link changed\n' >&2; exit 1; }
printf 'PASS: dangling Skills gate\n'

TEST_HOME="$TEST_ROOT/mismatch-home"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim/skills" "$TEST_HOME/.agents" "$TEST_HOME/other-skills" "$SCAN_ROOT"
ln -s ../other-skills "$TEST_HOME/.agents/skills"
assert_exit 3 isolated_uninstall --yes --backup-dir "$TEST_ROOT/mismatch-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/.mirasim"
[ -L "$TEST_HOME/.agents/skills" ] || { printf 'FAIL: mismatched Skills link changed\n' >&2; exit 1; }
printf 'PASS: mismatched Skills gate\n'

TEST_HOME="$TEST_ROOT/inside-backup-home"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim/skills/demo" "$TEST_HOME/.claude" "$SCAN_ROOT/project/.mirasim"
printf 'skill data\n' > "$TEST_HOME/.mirasim/skills/demo/SKILL.md"
ln -s ../.mirasim/skills "$TEST_HOME/.claude/skills"
assert_exit 3 isolated_uninstall --yes --backup-dir "$SCAN_ROOT/project/.mirasim/backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/.mirasim/skills/demo/SKILL.md"
[ -L "$TEST_HOME/.claude/skills" ] || { printf 'FAIL: Skills link changed with unsafe backup path\n' >&2; exit 1; }
printf 'PASS: backup deletion boundary\n'

TEST_HOME="$TEST_ROOT/unverifiable-home"
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.mirasim/skills" "$TEST_HOME/.claude" "$SCAN_ROOT"
/usr/bin/mkfifo "$TEST_HOME/.mirasim/skills/unsupported-entry"
ln -s ../.mirasim/skills "$TEST_HOME/.claude/skills"
assert_exit 3 isolated_uninstall --yes --backup-dir "$TEST_ROOT/unverifiable-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/.mirasim"
[ -L "$TEST_HOME/.claude/skills" ] || { printf 'FAIL: unverifiable Skills link changed\n' >&2; exit 1; }
printf 'PASS: unverifiable Skills gate\n'

uninstall_with_answer() {
  local answer=$1
  shift
  printf '%s' "$answer" | isolated_uninstall "$@"
}

setup_removal_fixture() {
  TEST_HOME="$TEST_ROOT/$1-home"
  SCAN_ROOT="$TEST_ROOT/$1-projects"
  export HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.mirasim/app" \
    "$TEST_HOME/Library/Application Support/@mirasim" \
    "$TEST_HOME/Library/LaunchAgents" \
    "$TEST_HOME/Applications/Mirasim.app/Contents" \
    "$TEST_HOME/Applications/Unrelated.app" \
    "$SCAN_ROOT/project/.mirasim" \
    "$SCAN_ROOT/project/keep" \
    "$TEST_ROOT/removal-bin"
  printf 'host state\n' > "$TEST_HOME/.mirasim/app/mirasim"
  chmod +x "$TEST_HOME/.mirasim/app/mirasim"
  printf 'support\n' > "$TEST_HOME/Library/Application Support/@mirasim/state"
  printf 'project\n' > "$SCAN_ROOT/project/.mirasim/state"
  printf 'keep\n' > "$SCAN_ROOT/project/keep/state"
  printf 'keep\n' > "$TEST_HOME/Applications/Unrelated.app/state"
  printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>ai.mirofish.mirasim</string></dict></plist>' > "$TEST_HOME/Applications/Mirasim.app/Contents/Info.plist"
  printf 'mirasim\n' > "$TEST_HOME/Library/LaunchAgents/ai.mirofish.mirasim.plist"
  [ ! -L "$TEST_ROOT/removal-bin/mirasim" ] || /bin/rm "$TEST_ROOT/removal-bin/mirasim"
  ln -s "$TEST_HOME/.mirasim/app/mirasim" "$TEST_ROOT/removal-bin/mirasim"
}

setup_removal_fixture confirmed
LAUNCHCTL_LOG="$TEST_ROOT/launchctl.log"
export LAUNCHCTL_LOG
printf '%s\n' '#!/bin/sh' '[ -e "$3" ] || exit 9' 'printf "present %s\n" "$*" >> "$LAUNCHCTL_LOG"' > "$TEST_ROOT/removal-bin/launchctl"
chmod +x "$TEST_ROOT/removal-bin/launchctl"

PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 2 uninstall_with_answer $'n\n' --backup-dir "$TEST_ROOT/confirmed-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/.mirasim/app/mirasim"
assert_path_exists "$TEST_HOME/Applications/Mirasim.app"
assert_path_exists "$SCAN_ROOT/project/.mirasim"
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 2 uninstall_with_answer $'Y\n' --backup-dir "$TEST_ROOT/confirmed-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/Library/LaunchAgents/ai.mirofish.mirasim.plist"
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 2 uninstall_with_answer $'y \n' --backup-dir "$TEST_ROOT/confirmed-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_ROOT/removal-bin/mirasim"
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 2 uninstall_with_answer '' --backup-dir "$TEST_ROOT/confirmed-backup" --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_HOME/.mirasim/app/mirasim"
printf '%s\n' '#include <unistd.h>' 'int main(void) { sleep(60); return 0; }' > "$TEST_ROOT/fixture-process.c"
/usr/bin/cc -o "$TEST_HOME/.mirasim/app/mirasim" "$TEST_ROOT/fixture-process.c"
"$TEST_HOME/.mirasim/app/mirasim" 60 &
TEST_PROCESS_PID=$!
/bin/sleep 1
case "$(/bin/ps -p "$TEST_PROCESS_PID" -o comm=)" in
  "$TEST_HOME/.mirasim/app/mirasim") ;;
  *) printf 'FAIL: fixture executable ownership is not visible to ps\n' >&2; exit 1 ;;
esac
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 0 uninstall_with_answer $'y\n' --backup-dir "$TEST_ROOT/confirmed-backup" --scan-root "$SCAN_ROOT"
wait "$TEST_PROCESS_PID" 2>/dev/null || true
/bin/kill -0 "$TEST_PROCESS_PID" 2>/dev/null && { printf 'FAIL: verified process is still running\n' >&2; exit 1; }
TEST_PROCESS_PID=
assert_contains "Backup location: $TEST_ROOT/confirmed-backup"
assert_path_missing "$TEST_HOME/.mirasim"
assert_path_missing "$TEST_HOME/Library/Application Support/@mirasim"
assert_path_missing "$TEST_HOME/Library/LaunchAgents/ai.mirofish.mirasim.plist"
assert_path_missing "$TEST_HOME/Applications/Mirasim.app"
assert_path_missing "$TEST_ROOT/removal-bin/mirasim"
assert_path_missing "$SCAN_ROOT/project/.mirasim"
assert_path_exists "$SCAN_ROOT/project/keep/state"
assert_path_exists "$TEST_HOME/Applications/Unrelated.app/state"
assert_contains 'Post-removal discovered: 0'
assert_path_exists "$LAUNCHCTL_LOG"
case "$(< "$LAUNCHCTL_LOG")" in
  *"present bootout gui/$UID $TEST_HOME/Library/LaunchAgents/ai.mirofish.mirasim.plist"*) ;;
  *) printf 'FAIL: launchctl bootout did not precede plist removal\n' >&2; exit 1 ;;
esac
printf 'PASS: confirmed removal and launchd ordering\n'

setup_removal_fixture unattended
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 0 isolated_uninstall --yes --backup-dir "$TEST_ROOT/unattended-backup" --scan-root "$SCAN_ROOT"
assert_path_missing "$TEST_HOME/.mirasim"
assert_path_missing "$TEST_HOME/Library/Application Support/@mirasim"
assert_path_missing "$TEST_HOME/Library/LaunchAgents/ai.mirofish.mirasim.plist"
assert_path_missing "$TEST_HOME/Applications/Mirasim.app"
assert_path_missing "$TEST_ROOT/removal-bin/mirasim"
assert_path_missing "$SCAN_ROOT/project/.mirasim"
assert_path_exists "$SCAN_ROOT/project/keep/state"
printf 'PASS: unattended removal\n'

setup_removal_fixture survivor
/usr/bin/cc -o "$TEST_HOME/.mirasim/app/mirasim" "$TEST_ROOT/fixture-process.c"
"$TEST_HOME/.mirasim/app/mirasim" &
TEST_PROCESS_PID=$!
/bin/sleep 1
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 1 isolated_uninstall_mode survivor --yes --scan-root "$SCAN_ROOT"
assert_contains "Residue: verified process PID $TEST_PROCESS_PID"
/bin/kill "$TEST_PROCESS_PID" 2>/dev/null || true
wait "$TEST_PROCESS_PID" 2>/dev/null || true
TEST_PROCESS_PID=
printf 'PASS: surviving verified process is residue\n'

setup_removal_fixture system_unprivileged
mkdir -p "$TEST_ROOT/system/LaunchDaemons"
printf 'mirasim\n' > "$TEST_ROOT/system/LaunchDaemons/ai.mirofish.mirasim.plist"
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 1 isolated_uninstall_mode system_unprivileged --yes --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_ROOT/system/LaunchDaemons/ai.mirofish.mirasim.plist"
assert_contains 'Privileged launchd residue:'
printf 'PASS: unprivileged system launchd residue\n'

setup_removal_fixture system_privileged
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 0 isolated_uninstall_mode system_privileged --yes --scan-root "$SCAN_ROOT"
assert_path_missing "$TEST_ROOT/system/LaunchDaemons/ai.mirofish.mirasim.plist"
case "$(< "$LAUNCHCTL_LOG")" in
  *"present bootout system $TEST_ROOT/system/LaunchDaemons/ai.mirofish.mirasim.plist"*) ;;
  *) printf 'FAIL: system launchd bootout was not used\n' >&2; exit 1 ;;
esac
printf 'PASS: privileged system launchd bootout\n'

setup_removal_fixture swap
mkdir -p "$TEST_ROOT/foreign-support/@mirasim"
printf 'unrelated\n' > "$TEST_ROOT/foreign-support/@mirasim/sentinel"
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 1 isolated_uninstall_mode swap_parent --yes --scan-root "$SCAN_ROOT"
assert_path_exists "$TEST_ROOT/foreign-support/@mirasim/sentinel"
assert_contains 'Unsafe deletion candidate:'
printf 'PASS: changed parent blocks deletion\n'

setup_removal_fixture listener
TEST_LISTENER_EXEC="$TEST_HOME/.mirasim/app/mirasim"
export TEST_LISTENER_EXEC
printf '%s\n' '#!/bin/sh' \
  'case "$*" in' \
  '  *-iTCP*) printf "p424242\nn127.0.0.1:2121\n" ;;' \
  '  *"-d txt"*) printf "n%s\n" "$TEST_LISTENER_EXEC" ;;' \
  'esac' > "$TEST_ROOT/removal-bin/lsof"
chmod +x "$TEST_ROOT/removal-bin/lsof"
PATH="$TEST_ROOT/removal-bin:$PATH" assert_exit 1 isolated_uninstall --yes --scan-root "$SCAN_ROOT"
assert_contains 'Residue: verified listener 127.0.0.1:2121'
printf 'PASS: surviving verified listener is residue\n'

for safety_case in swap_app swap_plist swap_cli swap_path unsafe_link absolute_internal_link absolute_external_link dangling_external_skill_link dangling_internal_link internal_link self_referential_internal_link change_source eof_y eof_empty process_report writer_order survivor_before_backup; do
  /bin/bash "$REPO_ROOT/tests/test_final_safety.sh" "$safety_case" || exit 1
done
