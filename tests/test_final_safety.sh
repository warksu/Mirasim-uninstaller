#!/usr/bin/env bash
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd -P "$TEST_ROOT" && pwd -P)
TEST_PROCESS_PID=
TEST_UNRELATED_PID=
trap 'for fixture_pid in "$TEST_PROCESS_PID" "$TEST_UNRELATED_PID"; do [ -z "$fixture_pid" ] || { /bin/kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; }; done; /bin/rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME" "$TEST_ROOT/bin" "$TEST_ROOT/projects"
export PATH="$TEST_ROOT/bin:$PATH"
export MIRASIM_UNINSTALL_OS_NAME=Darwin

run_fixture() {
  local mode=$1
  shift
  set +e
  OUTPUT=$(/bin/bash -c '
    source "$1"
    mode=$2
    eval "$(declare -f is_mirasim_app | sed "1s/is_mirasim_app/original_is_mirasim_app/")"
    is_mirasim_app() {
      [ "$1" != /Applications/Mirasim.app ] || return 1
      original_is_mirasim_app "$1"
    }
    launchd_roots() { printf "%s\n" "$HOME/Library/LaunchAgents"; }
    launchctl() { return 0; }
    security() { return 0; }
    scutil() { return 0; }
    lsof() { return 0; }
    case "$mode" in
      survivor_before_backup) stop_verified_processes() { :; } ;;
      swap_*)
        eval "$(declare -f confirm_removal | sed "1s/confirm_removal/original_confirm_removal/")"
        confirm_removal() {
          case "$mode" in
            swap_app) /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.unrelated" "$HOME/Applications/Mirasim.app/Contents/Info.plist" ;;
            swap_plist) printf "unrelated\n" > "$HOME/Library/LaunchAgents/worker.plist" ;;
            swap_cli) /bin/rm "$(command -v mirasim)"; /bin/ln -s "$HOME/unrelated" "${PATH%%:*}/mirasim" ;;
            swap_path) /bin/mv "$HOME/.mirasim" "$HOME/original"; /bin/mkdir "$HOME/.mirasim"; printf "unrelated\n" > "$HOME/.mirasim/sentinel" ;;
          esac
          original_confirm_removal
        } ;;
      change_source)
        eval "$(declare -f restore_taken_over_skills | sed "1s/restore_taken_over_skills/original_restore_taken_over_skills/")"
        restore_taken_over_skills() {
          original_restore_taken_over_skills
          printf "new unbacked data\n" > "$HOME/.mirasim/skills/late-file"
        } ;;
    esac
    main "${@:3}"
  ' _ "$REPO_ROOT/mirasim-uninstall.sh" "$mode" "$@" 2>&1)
  STATUS=$?
  set -e
}

expect_status() {
  [ "$STATUS" -eq "$1" ] || { printf 'FAIL: expected exit %s, got %s\n%s\n' "$1" "$STATUS" "$OUTPUT"; exit 1; }
}

skills_fixture() {
  mkdir -p "$HOME/.mirasim/skills/demo" "$HOME/.claude"
  printf 'skill data\n' > "$HOME/.mirasim/skills/demo/SKILL.md"
  ln -s ../.mirasim/skills "$HOME/.claude/skills"
}

case ${1:?test case required} in
  swap_app|swap_plist|swap_cli|swap_path)
    mkdir -p "$HOME/.mirasim/app" "$HOME/Applications/Mirasim.app/Contents" "$HOME/Library/LaunchAgents"
    printf '<plist><dict><key>CFBundleIdentifier</key><string>ai.mirofish.mirasim</string></dict></plist>\n' > "$HOME/Applications/Mirasim.app/Contents/Info.plist"
    printf 'mirasim\n' > "$HOME/Library/LaunchAgents/worker.plist"
    printf 'cli\n' > "$HOME/.mirasim/app/mirasim"
    chmod +x "$HOME/.mirasim/app/mirasim"
    ln -s "$HOME/.mirasim/app/mirasim" "$TEST_ROOT/bin/mirasim"
    printf 'unrelated\n' > "$HOME/unrelated"
    run_fixture "$1" --uninstall --scan-root "$TEST_ROOT/projects" <<< y
    expect_status 1
    [ -d "$HOME/.mirasim" ]
    [ -f "$HOME/Applications/Mirasim.app/Contents/Info.plist" ]
    [ -f "$HOME/Library/LaunchAgents/worker.plist" ]
    [ -L "$TEST_ROOT/bin/mirasim" ]
    ;;
  unsafe_link|internal_link|absolute_internal_link|absolute_external_link|dangling_external_skill_link|dangling_internal_link|self_referential_internal_link)
    skills_fixture
    case "$1" in
      unsafe_link) mkdir -p "$HOME/.mirasim/other"; printf 'not backed up\n' > "$HOME/.mirasim/other/file"; ln -s ../../other/file "$HOME/.mirasim/skills/demo/link" ;;
      internal_link) ln -s SKILL.md "$HOME/.mirasim/skills/demo/link" ;;
      absolute_internal_link) ln -s "$HOME/.mirasim/skills/demo/SKILL.md" "$HOME/.mirasim/skills/demo/link" ;;
      absolute_external_link) mkdir -p "$HOME/external-skills"; printf 'external skill\n' > "$HOME/external-skills/SKILL.md"; ln -s "$HOME/external-skills/SKILL.md" "$HOME/.mirasim/skills/demo/link" ;;
      dangling_external_skill_link) rm "$HOME/.mirasim/skills/demo/SKILL.md"; ln -s "$HOME/external-skills/missing/SKILL.md" "$HOME/.mirasim/skills/demo/SKILL.md" ;;
      dangling_internal_link) ln -s missing.md "$HOME/.mirasim/skills/demo/link" ;;
      self_referential_internal_link) ln -s hf-cli "$HOME/.mirasim/skills/hf-cli" ;;
    esac
    run_fixture normal --uninstall --yes --backup-dir "$TEST_ROOT/backup" --scan-root "$TEST_ROOT/projects"
    if [ "$1" = internal_link ] || [ "$1" = absolute_external_link ] || [ "$1" = dangling_external_skill_link ] || [ "$1" = self_referential_internal_link ]; then
      expect_status 0
      if [ "$1" = internal_link ]; then
        [ "$(< "$HOME/.claude/skills/demo/link")" = 'skill data' ]
      elif [ "$1" = absolute_external_link ]; then
        [ -L "$HOME/.claude/skills/demo/link" ]
        [ "$(/usr/bin/readlink "$HOME/.claude/skills/demo/link")" = "$HOME/external-skills/SKILL.md" ]
        [ "$(< "$HOME/.claude/skills/demo/link")" = 'external skill' ]
      elif [ "$1" = dangling_external_skill_link ]; then
        [ -L "$HOME/.claude/skills/demo/SKILL.md" ]
        [ "$(/usr/bin/readlink "$HOME/.claude/skills/demo/SKILL.md")" = "$HOME/external-skills/missing/SKILL.md" ]
      else
        [ -L "$HOME/.claude/skills/hf-cli" ]
        [ "$(/usr/bin/readlink "$HOME/.claude/skills/hf-cli")" = hf-cli ]
      fi
    else
      expect_status 3
      [ -f "$HOME/.mirasim/skills/demo/SKILL.md" ]
      [ -L "$HOME/.claude/skills" ]
    fi
    ;;
  change_source)
    skills_fixture
    run_fixture change_source --uninstall --yes --backup-dir "$TEST_ROOT/backup" --scan-root "$TEST_ROOT/projects"
    expect_status 3
    [ "$(< "$HOME/.mirasim/skills/late-file")" = 'new unbacked data' ]
    ;;
  eof_y|eof_empty)
    mkdir -p "$HOME/.mirasim"
    answer=
    [ "$1" != eof_y ] || answer=y
    # A regular file preserves the EOF-without-newline condition.
    printf '%s' "$answer" > "$TEST_ROOT/answer"
    run_fixture normal --uninstall --scan-root "$TEST_ROOT/projects" < "$TEST_ROOT/answer"
    expect_status 2
    [ -d "$HOME/.mirasim" ]
    ;;
  process_report|writer_order|survivor_before_backup)
    skills_fixture
    mkdir -p "$HOME/.mirasim/app"
    printf '%s\n' '#include <signal.h>' '#include <stdio.h>' '#include <unistd.h>' 'static volatile sig_atomic_t stopped;' 'static void stop(int sig) { stopped = sig; }' 'int main(int argc, char **argv) { signal(SIGTERM, stop); while (!stopped) pause(); FILE *f = fopen(argv[1], "w"); if (!f) return 1; fputs("final writer data\n", f); fclose(f); return 0; }' > "$TEST_ROOT/writer.c"
    /usr/bin/cc -o "$HOME/.mirasim/app/mirasim" "$TEST_ROOT/writer.c"
    ln -s "$HOME/.mirasim/app/mirasim" "$TEST_ROOT/bin/mirasim"
    "$HOME/.mirasim/app/mirasim" "$HOME/.mirasim/skills/final-file" &
    TEST_PROCESS_PID=$!
    /bin/sleep 1
    if [ "$1" = process_report ]; then
      cp "$HOME/.mirasim/app/mirasim" "$HOME/unrelated-mirasim"
      "$HOME/unrelated-mirasim" "$HOME/unrelated-output" &
      TEST_UNRELATED_PID=$!
      /bin/sleep 1
      run_fixture normal --check --scan-root "$TEST_ROOT/projects"
      expect_status 0
      case "$OUTPUT" in *"Process: PID $TEST_PROCESS_PID Executable: $HOME/.mirasim/app/mirasim"*) ;; *) printf 'FAIL: non-listening verified process omitted\n%s\n' "$OUTPUT"; exit 1 ;; esac
      case "$OUTPUT" in *"Process: PID $TEST_UNRELATED_PID "*|*"Executable: $HOME/unrelated-mirasim"*) printf 'FAIL: unrelated executable reported as Mirasim\n'; exit 1 ;; esac
    elif [ "$1" = survivor_before_backup ]; then
      run_fixture survivor_before_backup --uninstall --yes --backup-dir "$TEST_ROOT/backup" --scan-root "$TEST_ROOT/projects"
      expect_status 1
      [ ! -d "$TEST_ROOT/backup" ] || { printf 'FAIL: backup ran while verified writer survived\n'; exit 1; }
      [ -L "$HOME/.claude/skills" ]
      [ -d "$HOME/.mirasim" ]
    else
      run_fixture normal --uninstall --yes --backup-dir "$TEST_ROOT/backup" --scan-root "$TEST_ROOT/projects"
      expect_status 0
      wait "$TEST_PROCESS_PID" || true
      TEST_PROCESS_PID=
      [ -f "$HOME/.claude/skills/final-file" ] || { printf 'FAIL: writer final data was not recovered\n'; exit 1; }
      [ "$(< "$HOME/.claude/skills/final-file")" = 'final writer data' ]
    fi
    ;;
  *) exit 1 ;;
esac
printf 'PASS: final safety %s\n' "$1"
