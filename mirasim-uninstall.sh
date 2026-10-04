#!/usr/bin/env bash
set -u

MODE=check
SCAN_ROOT=${HOME:?}
BACKUP_DIR=
REPORT_PATH=
ASSUME_YES=0
MODE_SEEN=0
DELETE_PATHS=()
DELETE_IDENTITIES=()
DELETE_PROOFS=()
LAUNCHD_PLISTS=()
PROJECT_STATES=()
WARNINGS=()
DETAILS=()
VERIFIED_APPS=()
VERIFIED_CLI=
VERIFIED_CLI_PATH=
VERIFIED_RUNTIME_APPS=()
VERIFIED_RUNTIME_CLI=
DISCOVERED_COUNT=0
TAKEN_OVER_SKILLS=()
SKILLS_BACKUP_MANIFEST=

die() {
  local code=$1
  shift
  printf '%s\n' "ERROR: $*" >&2
  exit "$code"
}

usage() {
  printf '%s\n' \
    'Usage: mirasim-uninstall.sh [--check | --uninstall] [options]' \
    'Options:' \
    '  --check             Inspect only (default)' \
    '  --uninstall         Remove verified Mirasim artifacts after confirmation' \
    '  --yes               Confirm unattended uninstall' \
    '  --scan-root PATH    Directory to inspect (default: HOME)' \
    '  --backup-dir PATH   Skills backup directory (when restoration is needed)' \
    '  --report PATH       Write report to this file' \
    '  --help              Show this help'
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check|--uninstall)
        [ "$MODE_SEEN" -eq 0 ] || die 1 'Choose exactly one mode.'
        MODE=${1#--}
        MODE_SEEN=1
        ;;
      --yes)
        ASSUME_YES=1
        ;;
      --scan-root|--backup-dir|--report)
        local option=$1
        shift
        [ "$#" -gt 0 ] || die 1 "Missing path for $option."
        [ -n "$1" ] || die 1 "Empty path for $option."
        case "$option" in
          --scan-root) SCAN_ROOT=$1 ;;
          --backup-dir) BACKUP_DIR=$1 ;;
          --report) REPORT_PATH=$1 ;;
        esac
        ;;
      --help)
        usage
        exit 0
        ;;
      *) die 1 "Unknown argument: $1" ;;
    esac
    shift
  done
  [ "$ASSUME_YES" -eq 0 ] || [ "$MODE" = uninstall ] || die 1 '--yes requires --uninstall.'
}

require_macos() {
  local os_name=${MIRASIM_UNINSTALL_OS_NAME:-$(/usr/bin/uname -s)}
  [ "$os_name" = Darwin ] || die 1 'This tool supports macOS only.'
}

validate_safe_directory() {
  case "$1" in
    /*) ;;
    *) die 1 "Expected an absolute directory: $1" ;;
  esac
  [ -d "$1" ] && [ ! -L "$1" ] && has_safe_parent_chain "$1" || die 1 "Not a safe directory: $1"
}

has_safe_parent_chain() {
  local parent
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *'//'*|*'/./'*|*'/../'*|*'/.'|*'/..'|*/ ) return 1 ;;
  esac
  parent=${1%/*}
  [ -n "$parent" ] || parent=/
  while [ "$parent" != / ]; do
    [ ! -L "$parent" ] || return 1
    parent=${parent%/*}
    [ -n "$parent" ] || parent=/
  done
}

add_delete_path() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  has_safe_parent_chain "$1" || return 1
  local existing
  for existing in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
    [ "$existing" != "$1" ] || return 0
  done
  DELETE_PATHS[${#DELETE_PATHS[@]}]=$1
  DISCOVERED_COUNT=$((DISCOVERED_COUNT + 1))
}

is_mirasim_app() {
  has_safe_parent_chain "$1" && [ -d "$1" ] && [ ! -L "$1" ] && [ -d "$1/Contents" ] && [ ! -L "$1/Contents" ] && [ -f "$1/Contents/Info.plist" ] && [ ! -L "$1/Contents/Info.plist" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = ai.mirofish.mirasim ]
}

discover_app() {
  local app file name hash version
  for app in /Applications/Mirasim.app "$HOME/Applications/Mirasim.app"; do
    is_mirasim_app "$app" || continue
    VERIFIED_APPS[${#VERIFIED_APPS[@]}]=$app
    add_delete_path "$app"
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null) || version=unknown
    DETAILS[${#DETAILS[@]}]="Verified App: $app Bundle ID: ai.mirofish.mirasim Version: $version"
    while IFS= read -r -d '' file; do
      name=${file##*/}
      if printf '%s\n' "$name" | /usr/bin/grep -Eiq 'codex-hijack|apodex|mitm|askpass'; then
        hash=$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')
        WARNINGS[${#WARNINGS[@]}]="App file: $file SHA-256: $hash"
      fi
    done < <(/usr/bin/find -P "$app" -type f -print0)
  done
}

discover_host_state() {
  local state="$HOME/.mirasim" file key path
  [ -e "$state" ] || [ -L "$state" ] || return 0
  has_safe_parent_chain "$state" || return 0
  add_delete_path "$state"
  [ -d "$state" ] && [ ! -L "$state" ] || return 0
  for path in "$state/app" "$state/updates"; do
    if [ -d "$path" ] && [ ! -L "$path" ] && has_safe_parent_chain "$path"; then
      if [ "$path" = "$state/updates" ]; then
        DETAILS[${#DETAILS[@]}]="Host state: $path ($(file_metadata "$path"))"
      else
        DETAILS[${#DETAILS[@]}]="Host state: $path"
      fi
      while IFS= read -r -d '' file; do
        DETAILS[${#DETAILS[@]}]="Host state: $file ($(file_metadata "$file"))"
      done < <(/usr/bin/find -P "$path" -type f -print0 | LC_ALL=C /usr/bin/sort -z)
      if [ "$path" = "$state/app" ]; then
        while IFS= read -r -d '' file; do
          DETAILS[${#DETAILS[@]}]="App version: $file"
        done < <(/usr/bin/find -P "$path" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C /usr/bin/sort -z)
      fi
    fi
  done
  for file in "$state/setting.json" "$state/mirachannel-discovery.json"; do
    [ -f "$file" ] && [ ! -L "$file" ] && has_safe_parent_chain "$file" || continue
    DETAILS[${#DETAILS[@]}]="State file: $file ($(file_metadata "$file"))"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      DETAILS[${#DETAILS[@]}]="State key: $file: $key"
    done < <(/usr/bin/grep -Eo '"(mirachannel[A-Za-z0-9_]*|nodeId|e2e[A-Za-z0-9_]*)"[[:space:]]*:' "$file" | /usr/bin/sed -E 's/^"([^"]+)"[[:space:]]*:$/\1/' | LC_ALL=C /usr/bin/sort -u)
  done
}

file_metadata() {
  /usr/bin/stat -f 'size: %z bytes; modified: %Sm' -t '%Y-%m-%d %H:%M:%S %z' "$1"
}

discover_library() {
  local base path name
  base="$HOME/Library/Application Support/@mirasim"
  add_delete_path "$base"
  for base in "$HOME/Library/Preferences" "$HOME/Library/Application Support" "$HOME/Library/Caches" "$HOME/Library/Saved Application State" "$HOME/Library/Logs"; do
    [ -d "$base" ] && [ ! -L "$base" ] && has_safe_parent_chain "$base" || continue
    while IFS= read -r -d '' path; do
      [ "$path" != "$HOME/Library/Application Support/@mirasim" ] || continue
      name=${path##*/}
      if printf '%s\n' "$name" | /usr/bin/grep -Eiq 'mirasim|mirofish|apodex'; then
        add_delete_path "$path"
      fi
    done < <(/usr/bin/find -P "$base" -mindepth 1 -maxdepth 2 \( -path "$HOME/Library/Application Support/@mirasim" -o -name node_modules \) -prune -o -print0 | LC_ALL=C /usr/bin/sort -z)
  done
}

discover_cli() {
  local cli resolved
  cli=$(command -v mirasim 2>/dev/null) || return 0
  has_safe_parent_chain "$cli" || return 0
  [ -f "$cli" ] || return 0
  resolved=$(resolve_path "$cli" 2>/dev/null) || return 0
  has_safe_parent_chain "$resolved" || return 0
  case "$resolved" in
    "$HOME/.mirasim/"*|"$HOME/Library/Application Support/@mirasim/"*)
      VERIFIED_CLI=$resolved
      VERIFIED_CLI_PATH=$cli
      add_delete_path "$cli"
      ;;
  esac
}

launchd_roots() {
  printf '%s\n' "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons
}

is_system_launchd_plist() {
  case "$1" in /Library/LaunchAgents/*|/Library/LaunchDaemons/*) return 0 ;; esac
  return 1
}

is_privileged() {
  [ "$EUID" -eq 0 ]
}

discover_launchd() {
  local base path name
  while IFS= read -r base; do
    [ -d "$base" ] && [ ! -L "$base" ] && has_safe_parent_chain "$base" || continue
    while IFS= read -r -d '' path; do
      name=${path##*/}
      case "$name" in *.plist) ;; *) continue ;; esac
      if printf '%s\n' "$name" | /usr/bin/grep -Eiq 'mirasim|mirofish|apodex' || { [ -f "$path" ] && [ ! -L "$path" ] && /usr/bin/grep -Eiq 'mirasim|mirofish|apodex' "$path"; }; then
        if add_delete_path "$path"; then
          LAUNCHD_PLISTS[${#LAUNCHD_PLISTS[@]}]=$path
        fi
      fi
    done < <(/usr/bin/find -P "$base" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 | LC_ALL=C /usr/bin/sort -z)
  done < <(launchd_roots)
}

discover_projects() {
  local path backup git_state
  backup=
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    backup=$(cd -P "$BACKUP_DIR" 2>/dev/null && pwd -P)
  fi
  while IFS= read -r -d '' path; do
    [ "$path" != "$HOME/.mirasim" ] || continue
    add_delete_path "$path" || continue
    git_state=
    if GIT_OPTIONAL_LOCKS=0 git -C "${path%/*}" rev-parse --is-inside-work-tree 2>/dev/null | /usr/bin/grep -qx true; then
      git_state=$(GIT_OPTIONAL_LOCKS=0 git -C "${path%/*}" status --short -- .mirasim 2>/dev/null)
    fi
    PROJECT_STATES[${#PROJECT_STATES[@]}]="$path (git: ${git_state:-none})"
  done < <(/usr/bin/find -P "$SCAN_ROOT" \( -type d \( -name .git -o -name node_modules -o -name .Trash -o -name .cache -o -name Caches -o -path "$backup" \) \) -prune -o -type d -name .mirasim -prune -print0 | LC_ALL=C /usr/bin/sort -z)
}

discover_runtime_risks() {
  local file line app pid executable entry address certificate_name keychain hash quoted_keychain delete_prefix
  while read -r pid executable; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ] || continue
    if is_discovered_executable "$executable"; then
      DETAILS[${#DETAILS[@]}]="Process: PID $pid Executable: $executable"
    fi
  done < <(/bin/ps -axo pid=,comm=)
  for file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile" "$HOME/.claude/settings.json" "$HOME/.codex/config.toml" "$HOME/.ssh/config" "$HOME/.gitconfig"; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    while IFS= read -r line; do
      WARNINGS[${#WARNINGS[@]}]="Config: $file:${line%%:*}:<redacted>"
    done < <(/usr/bin/grep -inE 'mirasim|mirofish|apodex' "$file" 2>/dev/null)
  done
  if [ "${#VERIFIED_APPS[@]}" -gt 0 ]; then
    WARNINGS[${#WARNINGS[@]}]='TCC review: tccutil reset All ai.mirofish.mirasim'
  fi
  if command -v scutil >/dev/null 2>&1 && scutil --proxy 2>/dev/null | /usr/bin/grep -Eiq 'mirasim|mirofish|apodex'; then
    WARNINGS[${#WARNINGS[@]}]='Proxy settings mention Mirasim; review manually.'
  fi
  if command -v security >/dev/null 2>&1; then
    for keychain in "$HOME/Library/Keychains/login.keychain-db" /Library/Keychains/System.keychain; do
      has_safe_parent_chain "$keychain" || continue
      printf -v quoted_keychain '%q' "$keychain"
      delete_prefix=
      [ "$keychain" != /Library/Keychains/System.keychain ] || delete_prefix='sudo '
      for certificate_name in Mirasim MiroFish Apodex mirofish.ai; do
        while IFS= read -r hash; do
          hash=${hash#SHA-1 hash: }
          WARNINGS[${#WARNINGS[@]}]="Keychain certificate: $certificate_name SHA-1: $hash Keychain: $keychain; review: security find-certificate -a -Z -c $certificate_name $quoted_keychain; manual deletion: ${delete_prefix}security delete-certificate -Z $hash $quoted_keychain"
        done < <(security find-certificate -a -Z -c "$certificate_name" "$keychain" 2>/dev/null | /usr/bin/grep -Eo 'SHA-1 hash: [[:xdigit:]]{40}' | LC_ALL=C /usr/bin/sort -u)
      done
    done
  fi
  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r entry; do
      case "$entry" in p*) pid=${entry#p}; executable= ;; n*)
        address=${entry#n}
        [ -n "${pid:-}" ] || continue
        executable=$(lsof -nP -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/sed -n 's/^n//p' | /usr/bin/head -n 1)
        for app in "${VERIFIED_APPS[@]+"${VERIFIED_APPS[@]}"}"; do
          case "$executable" in "$app/"*) WARNINGS[${#WARNINGS[@]}]="Listener: $address" ;; esac
        done
        if [ -n "$VERIFIED_CLI" ] && [ "$executable" = "$VERIFIED_CLI" ]; then
          WARNINGS[${#WARNINGS[@]}]="Listener: $address"
        fi
        ;;
      esac
    done < <(lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null)
  fi
  if [ -e "$HOME/.mirasim" ] || [ -L "$HOME/.mirasim" ]; then
    WARNINGS[${#WARNINGS[@]}]='Credential review: consider signing out of Claude Code and rotating exposed API keys.'
  fi
}

discover_all() {
  DELETE_PATHS=()
  LAUNCHD_PLISTS=()
  PROJECT_STATES=()
  WARNINGS=()
  DETAILS=()
  VERIFIED_APPS=()
  VERIFIED_CLI=
  VERIFIED_CLI_PATH=
  DISCOVERED_COUNT=0
  discover_app
  # Remove the CLI link while its verified target still exists.
  discover_cli
  discover_host_state
  discover_library
  discover_launchd
  discover_projects
  discover_runtime_risks
}

resolve_path() {
  local path=$1 parent link hops=0
  while :; do
    while [ "$path" != / ]; do
      case "$path" in
        /.) path=/ ;;
        */.) path=${path%/.} ;;
        */) path=${path%/} ;;
        *) break ;;
      esac
    done
    parent=$(cd -P "$(/usr/bin/dirname "$path")" 2>/dev/null && pwd -P) || return 1
    path="$parent/${path##*/}"
    [ -L "$path" ] || break
    [ "$hops" -lt 40 ] || return 1
    link=$(/usr/bin/readlink "$path") || return 1
    case "$link" in
      /*) path=$link ;;
      *) path="$parent/$link" ;;
    esac
    hops=$((hops + 1))
  done
  [ -e "$path" ] || return 1
  if [ -d "$path" ]; then
    (cd -P "$path" 2>/dev/null && pwd -P)
    return $?
  fi
  printf '%s\n' "$path"
}

inspect_skills() {
  local target resolved source="$HOME/.mirasim/skills"
  TAKEN_OVER_SKILLS=()
  for target in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
    [ -e "$target" ] || [ -L "$target" ] || continue
    has_safe_parent_chain "$target" || die 3 "Unsafe Skills parent: $target. Restore manually from Time Machine or source."
    if [ -L "$target" ]; then
      resolved=$(resolve_path "$target") || die 3 "Dangling or unresolvable Skills link: $target. Restore manually from Time Machine or source."
      [ "$resolved" = "$source" ] || die 3 "Skills link has an unexpected target: $target. Restore manually from Time Machine or source."
      [ -d "$source" ] && [ ! -L "$source" ] && has_safe_parent_chain "$source" || die 3 'Mirasim Skills source is unsafe. Restore manually from Time Machine or source.'
      TAKEN_OVER_SKILLS[${#TAKEN_OVER_SKILLS[@]}]=$target
    else
      [ -d "$target" ] || die 3 "Skills path is not a directory: $target. Restore manually from Time Machine or source."
    fi
  done
  if [ "${#TAKEN_OVER_SKILLS[@]}" -gt 0 ]; then
    validate_skills_links "$source"
  fi
}

validate_skills_links() {
  /usr/bin/perl -MFile::Find -MCwd=abs_path -e '
    my $root = abs_path($ARGV[0]);
    die "Unsafe Skills root\n" unless defined $root && -d $root;
    find({ no_chdir => 1, wanted => sub {
      return unless -l $_;
      my $link = readlink($_);
      my ($leaf) = $_ =~ m{([^/]+)\z};
      my $is_self_link = defined $leaf && defined $link && $link eq $leaf;
      my $target = $is_self_link ? undef : abs_path($_);
      my $is_internal = defined $target && ($target eq $root || index($target, "$root/") == 0);
      my $is_external_absolute_file = defined $link && $link =~ m{^/}
        && defined $target && -f $target && !$is_internal;
      my $is_external_absolute_skill_link = defined $link && $link =~ m{^/}
        && $_ =~ m{^\Q$root\E/[^/]+/SKILL\.md\z} && $link =~ m{/SKILL\.md\z}
        && $link !~ m{^\Q$root\E(?:/|\z)} && $link !~ m{(?:^|/)\.\.?(?:/|\z)};
      die "Skills link is not safely relocatable: $_\n"
        unless defined $link && $link !~ m{^/} && ($is_self_link ||
          (defined $target && -e $_ && $is_internal)) || $is_external_absolute_file || $is_external_absolute_skill_link;
    } }, $root);
  ' "$1" || die 3 'Unsafe Skills source links. Restore manually from Time Machine or source.'
}

validate_backup_dir() {
  local candidate parent
  [ "${#TAKEN_OVER_SKILLS[@]}" -gt 0 ] || return 0
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$HOME/Desktop/mirasim-uninstall-backup-$(/bin/date '+%Y%m%d-%H%M%S')"
  fi
  case "$BACKUP_DIR" in
    /*) ;;
    *) die 3 "Backup directory must be absolute: $BACKUP_DIR" ;;
  esac
  has_safe_parent_chain "$BACKUP_DIR" || die 3 "Unsafe backup directory: $BACKUP_DIR"
  for candidate in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
    case "$BACKUP_DIR" in
      "$candidate"|"$candidate/"*) die 3 "Backup directory is inside a deletion candidate: $BACKUP_DIR" ;;
    esac
  done
  [ ! -e "$BACKUP_DIR" ] && [ ! -L "$BACKUP_DIR" ] || die 3 "Backup directory already exists: $BACKUP_DIR"
  parent=${BACKUP_DIR%/*}
  [ -n "$parent" ] || parent=/
  [ -d "$parent" ] && [ ! -L "$parent" ] || die 3 "Backup parent is not a safe directory: $parent"
}

prepare_backup_dir() {
  [ "${#TAKEN_OVER_SKILLS[@]}" -gt 0 ] || return 0
  validate_backup_dir
  (umask 077; /bin/mkdir -m 700 "$BACKUP_DIR") || die 3 "Cannot create backup directory: $BACKUP_DIR"
}

manifest_tree() {
  (
    set -o pipefail
    cd -P "$1" || exit 1
    /usr/bin/find -P . -print0 |
      /usr/bin/perl -0ne '
        BEGIN { require Digest::SHA; }
        s/\0\z//;
        push @paths, $_;
        END {
          for my $path (sort @paths) {
            my $digest;
            if (-l $path) {
              my $link = readlink($path);
              die "Cannot read Skills link\n" unless defined $link;
              $digest = Digest::SHA::sha256_hex("link\0" . $link);
            } elsif (-d $path) {
              $digest = Digest::SHA::sha256_hex("directory\0");
            } elsif (-f $path) {
              open my $file, "<", $path or die "Cannot read Skills file\n";
              binmode $file;
              $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
              close $file or die "Cannot close Skills file\n";
            } else {
              die "Unsupported Skills entry\n";
            }
            print "$digest  $path\n";
          }
        }
      '
  )
}

restore_taken_over_skills() {
  local source="$HOME/.mirasim/skills" target original_manifest backup_manifest restored_manifest
  [ "${#TAKEN_OVER_SKILLS[@]}" -gt 0 ] || return 0
  validate_skills_links "$source"
  original_manifest=$(manifest_tree "$source") || die 3 'Cannot verify Mirasim Skills source. Restore manually from Time Machine or source.'
  (umask 077; /usr/bin/ditto "$source" "$BACKUP_DIR/mirasim-skills") || die 3 'Cannot back up Mirasim Skills.'
  backup_manifest=$(manifest_tree "$BACKUP_DIR/mirasim-skills") || die 3 'Cannot verify Skills backup.'
  [ "$backup_manifest" = "$original_manifest" ] || die 3 'Skills backup differs from source.'
  validate_skills_links "$BACKUP_DIR/mirasim-skills"
  SKILLS_BACKUP_MANIFEST=$backup_manifest
  (umask 077; printf '%s\n' "$original_manifest" > "$BACKUP_DIR/skills.sha256") || die 3 'Cannot write Skills manifest.'
  for target in "${TAKEN_OVER_SKILLS[@]}"; do
    [ -L "$target" ] && [ "$(resolve_path "$target")" = "$source" ] || die 3 "Skills link changed: $target"
    /bin/rm "$target" || die 3 "Cannot remove Skills link: $target"
    (umask 077; /bin/mkdir -m 700 "$target" && /usr/bin/ditto "$BACKUP_DIR/mirasim-skills" "$target") || die 3 "Cannot restore Skills: $target"
    [ -d "$target" ] && [ ! -L "$target" ] || die 3 "Skills restoration is unsafe: $target"
    restored_manifest=$(manifest_tree "$target") || die 3 "Cannot verify restored Skills: $target"
    [ "$restored_manifest" = "$original_manifest" ] || die 3 "Restored Skills differ from source: $target"
    validate_skills_links "$target"
  done
}

verify_skills_backup_current() {
  local source_manifest backup_manifest
  [ "${#TAKEN_OVER_SKILLS[@]}" -gt 0 ] || return 0
  validate_skills_links "$HOME/.mirasim/skills"
  source_manifest=$(manifest_tree "$HOME/.mirasim/skills") || die 3 'Cannot recheck Skills source before removal.'
  backup_manifest=$(manifest_tree "$BACKUP_DIR/mirasim-skills") || die 3 'Cannot recheck Skills backup before removal.'
  [ "$source_manifest" = "$SKILLS_BACKUP_MANIFEST" ] && [ "$backup_manifest" = "$SKILLS_BACKUP_MANIFEST" ] || die 3 'Skills source or backup changed after backup; Host state was preserved.'
}

write_report() {
  local report item
  report=$(printf 'Date: %s\nMode: %s\nScan root: %s\nDiscovered: %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %z')" "$MODE" "$SCAN_ROOT" "$DISCOVERED_COUNT")
  for item in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do report+=$'\n'"Delete candidate: $item"; done
  for item in "${DETAILS[@]+"${DETAILS[@]}"}"; do report+=$'\n'"$item"; done
  for item in "${LAUNCHD_PLISTS[@]+"${LAUNCHD_PLISTS[@]}"}"; do report+=$'\n'"Launchd plist: $item"; done
  for item in "${PROJECT_STATES[@]+"${PROJECT_STATES[@]}"}"; do report+=$'\n'"Project state: $item"; done
  for item in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do report+=$'\n'"Warning: $item"; done
  if [ -n "$REPORT_PATH" ]; then
    [ ! -e "$REPORT_PATH" ] && [ ! -L "$REPORT_PATH" ] || die 1 "Report path already exists: $REPORT_PATH"
    ( set -C; printf '%s\n' "$report" > "$REPORT_PATH" ) 2>/dev/null || die 1 "Cannot create report: $REPORT_PATH"
  else
    printf '%s\n' "$report"
  fi
}

print_removal_plan() {
  local index=1 path
  printf 'Removal plan:\n'
  for path in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
    printf '%d. %s\n' "$index" "$path"
    index=$((index + 1))
  done
  printf 'Backup location: %s\n' "${BACKUP_DIR:-not needed}"
}

confirm_removal() {
  local answer=
  [ "$ASSUME_YES" -eq 0 ] || return 0
  printf 'Type y to remove the listed paths: '
  IFS= read -r answer || die 2 'Removal cancelled; no listed paths were deleted.'
  [ "$answer" = y ] || die 2 'Removal cancelled; no listed paths were deleted.'
}

is_discovered_executable() {
  local executable=$1 app
  for app in "${VERIFIED_APPS[@]+"${VERIFIED_APPS[@]}"}"; do
    case "$executable" in "$app/"*) return 0 ;; esac
  done
  [ -n "$VERIFIED_CLI" ] && [ "$executable" = "$VERIFIED_CLI" ]
}

is_verified_executable() {
  local executable=$1 app
  for app in "${VERIFIED_RUNTIME_APPS[@]+"${VERIFIED_RUNTIME_APPS[@]}"}"; do
    case "$executable" in "$app/"*) return 0 ;; esac
  done
  [ -n "$VERIFIED_RUNTIME_CLI" ] && [ "$executable" = "$VERIFIED_RUNTIME_CLI" ]
}

verified_process_pids() {
  local pid executable
  while read -r pid executable; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ] || continue
    is_verified_executable "$executable" && printf '%s\n' "$pid"
  done < <(/bin/ps -axo pid=,comm=)
}

verified_listener_addresses() {
  local entry pid= executable address
  command -v lsof >/dev/null 2>&1 || return 0
  while IFS= read -r entry; do
    case "$entry" in
      p*) pid=${entry#p} ;;
      n*)
        [ -n "$pid" ] || continue
        address=${entry#n}
        executable=$(lsof -nP -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/sed -n 's/^n//p' | /usr/bin/head -n 1)
        is_verified_executable "$executable" && printf '%s\n' "$address"
        ;;
    esac
  done < <(lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null)
}

stop_verified_processes() {
  local pid second remaining=() count=0 failed=0
  local pids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] && pids[${#pids[@]}]=$pid
  done < <(verified_process_pids)
  for pid in "${pids[@]+"${pids[@]}"}"; do
    second=$(/bin/ps -p "$pid" -o comm= 2>/dev/null) || continue
    is_verified_executable "$second" || continue
    /bin/kill -TERM "$pid" 2>/dev/null || failed=1
  done
  while [ "$count" -lt 5 ]; do
    remaining=()
    for pid in "${pids[@]+"${pids[@]}"}"; do
      /bin/kill -0 "$pid" 2>/dev/null && remaining[${#remaining[@]}]=$pid
    done
    [ "${#remaining[@]}" -gt 0 ] || break
    /bin/sleep 1
    count=$((count + 1))
  done
  for pid in "${remaining[@]+"${remaining[@]}"}"; do
    second=$(/bin/ps -p "$pid" -o comm= 2>/dev/null) || continue
    is_verified_executable "$second" || continue
    /bin/kill -KILL "$pid" 2>/dev/null || failed=1
  done
  return "$failed"
}

validate_delete_path() {
  local path=$1 discovered
  case "$path" in /*) ;; *) return 1 ;; esac
  has_safe_parent_chain "$path" || return 1
  case "$path" in
    /|"$HOME"|"$SCAN_ROOT"|"$HOME/.claude/skills"|"$HOME/.agents/skills") return 1 ;;
  esac
  if [ -n "$BACKUP_DIR" ]; then
    case "$BACKUP_DIR" in "$path"|"$path/"*) return 1 ;; esac
  fi
  for discovered in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
    [ "$path" != "$discovered" ] || return 0
  done
  return 1
}

path_chain_identity() {
  local path=$1 identity= component
  while :; do
    component=$(/usr/bin/stat -f '%d:%i:%HT' "$path") || return 1
    identity="$identity/$component"
    [ "$path" != / ] || break
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  printf '%s\n' "$identity"
}

validate_removal_plan() {
  local path plist identity proof
  DELETE_IDENTITIES=()
  DELETE_PROOFS=()
  for path in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
    validate_delete_path "$path" || die 1 "Unsafe deletion candidate: $path"
    identity=$(path_chain_identity "$path") || die 1 "Deletion candidate changed: $path"
    DELETE_IDENTITIES[${#DELETE_IDENTITIES[@]}]=$identity
    proof=$(candidate_ownership_proof "$path") || die 1 "Unverified deletion candidate: $path"
    DELETE_PROOFS[${#DELETE_PROOFS[@]}]=$proof
  done
  for plist in "${LAUNCHD_PLISTS[@]+"${LAUNCHD_PLISTS[@]}"}"; do
    validate_delete_path "$plist" || die 1 "Unsafe launchd candidate: $plist"
  done
}

candidate_ownership_proof() {
  local path=$1 app plist resolved
  for app in "${VERIFIED_APPS[@]+"${VERIFIED_APPS[@]}"}"; do
    [ "$path" = "$app" ] || continue
    is_mirasim_app "$path" || return 1
    path_chain_identity "$path/Contents/Info.plist" || return 1
    /usr/bin/shasum -a 256 "$path/Contents/Info.plist"
    return $?
  done
  if [ -n "$VERIFIED_CLI_PATH" ] && [ "$path" = "$VERIFIED_CLI_PATH" ]; then
    resolved=$(resolve_path "$path") || return 1
    [ "$resolved" = "$VERIFIED_CLI" ] && has_safe_parent_chain "$resolved" || return 1
    case "$resolved" in "$HOME/.mirasim/"*|"$HOME/Library/Application Support/@mirasim/"*) ;; *) return 1 ;; esac
    path_chain_identity "$resolved" || return 1
    /usr/bin/shasum -a 256 "$resolved" || return 1
  fi
  for plist in "${LAUNCHD_PLISTS[@]+"${LAUNCHD_PLISTS[@]}"}"; do
    [ "$path" = "$plist" ] || continue
    printf '%s\n' "${path##*/}" | /usr/bin/grep -Eiq 'mirasim|mirofish|apodex' ||
      { [ -f "$path" ] && [ ! -L "$path" ] && /usr/bin/grep -Eiq 'mirasim|mirofish|apodex' "$path"; } || return 1
  done
  if [ -L "$path" ]; then
    /usr/bin/readlink "$path"
  elif [ -f "$path" ]; then
    /usr/bin/shasum -a 256 "$path"
  elif [ -d "$path" ]; then
    # Directory ownership is its discovered exact name and stable object identity.
    printf 'directory:%s\n' "$path"
  else
    return 1
  fi
}

recheck_removal_plan() {
  local path index=0
  for path in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
    check_candidate_unchanged "$path" "$index" || die 1 "Deletion candidate disappeared: $path"
    index=$((index + 1))
  done
}

check_candidate_unchanged() {
  local path=$1 index=$2 identity proof
  validate_delete_path "$path" || die 1 "Unsafe deletion candidate: $path"
  [ -e "$path" ] || [ -L "$path" ] || return 2
  identity=$(path_chain_identity "$path") || die 1 "Deletion candidate changed: $path"
  [ "$identity" = "${DELETE_IDENTITIES[$index]}" ] || die 1 "Deletion candidate changed: $path"
  proof=$(candidate_ownership_proof "$path") || die 1 "Deletion ownership changed: $path"
  [ "$proof" = "${DELETE_PROOFS[$index]}" ] || die 1 "Deletion ownership changed: $path"
}

remove_verified_artifacts() {
  local path plist failed=0 skip index=0
  for path in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
    check_candidate_unchanged "$path" "$index" || {
      index=$((index + 1))
      continue
    }
    skip=0
    for plist in "${LAUNCHD_PLISTS[@]+"${LAUNCHD_PLISTS[@]}"}"; do
      [ "$path" = "$plist" ] || continue
      if is_system_launchd_plist "$plist"; then
          if ! is_privileged; then
            printf 'ERROR: Privileged launchd residue: %s; run sudo launchctl bootout system %q and review the plist manually.\n' "$plist" "$plist" >&2
            failed=1
            skip=1
          elif ! launchctl bootout system "$plist"; then
            printf 'ERROR: Failed to boot out system launchd plist: %s\n' "$plist" >&2
            failed=1
            skip=1
          fi
      else
          if ! launchctl bootout "gui/$UID" "$plist"; then
            printf 'ERROR: Failed to boot out user launchd plist: %s\n' "$plist" >&2
            failed=1
          fi
      fi
      break
    done
    if [ "$skip" -ne 0 ]; then
      index=$((index + 1))
      continue
    fi
    check_candidate_unchanged "$path" "$index" || {
      index=$((index + 1))
      continue
    }
    if [ "$path" = "$HOME/.mirasim" ]; then
      verify_skills_backup_current
      check_candidate_unchanged "$path" "$index" || die 1 "Host state changed: $path"
    fi
    /bin/rm -rf "$path" || { printf 'ERROR: Cannot remove %s\n' "$path" >&2; failed=1; }
    index=$((index + 1))
  done
  return "$failed"
}

verify_removal() {
  local pid address residual=0 warning
  discover_all
  printf 'Post-removal discovered: %s\n' "$DISCOVERED_COUNT"
  if [ "$DISCOVERED_COUNT" -gt 0 ]; then
    for pid in "${DELETE_PATHS[@]+"${DELETE_PATHS[@]}"}"; do
      printf 'Residue: %s\n' "$pid" >&2
    done
    residual=1
  fi
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    printf 'Residue: verified process PID %s\n' "$pid" >&2
    residual=1
  done < <(verified_process_pids)
  while IFS= read -r address; do
    [ -n "$address" ] || continue
    printf 'Residue: verified listener %s\n' "$address" >&2
    residual=1
  done < <(verified_listener_addresses)
  for warning in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
    printf 'Warning: %s\n' "$warning"
  done
  return "$residual"
}

main() {
  parse_args "$@"
  require_macos
  validate_safe_directory "$HOME"
  validate_safe_directory "$SCAN_ROOT"
  discover_all
  write_report
  if [ "$MODE" = uninstall ]; then
    inspect_skills
    if [ "${#TAKEN_OVER_SKILLS[@]}" -gt 0 ] && [ -z "$BACKUP_DIR" ]; then
      BACKUP_DIR="$HOME/Desktop/mirasim-uninstall-backup-$(/bin/date '+%Y%m%d-%H%M%S')"
    fi
    validate_backup_dir
    VERIFIED_RUNTIME_APPS=("${VERIFIED_APPS[@]+"${VERIFIED_APPS[@]}"}")
    VERIFIED_RUNTIME_CLI=$VERIFIED_CLI
    validate_removal_plan
    print_removal_plan
    confirm_removal
    recheck_removal_plan
    local failed=0 pid surviving=
    stop_verified_processes || die 1 'Cannot stop verified Mirasim processes; removal aborted.'
    surviving=$(verified_process_pids)
    if [ -n "$surviving" ]; then
      while IFS= read -r pid; do
        printf 'Residue: verified process PID %s\n' "$pid" >&2
      done <<< "$surviving"
      die 1 'Verified writers remain; backup and removal aborted.'
    fi
    recheck_removal_plan
    prepare_backup_dir
    restore_taken_over_skills
    recheck_removal_plan
    remove_verified_artifacts || failed=1
    verify_removal || failed=1
    return "$failed"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
