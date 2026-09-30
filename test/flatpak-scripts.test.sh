#!/bin/bash
# Test harness for the scripts in scripts/.
#
# Every stub binary here records the exact argv it was called with, so a test
# asserts on the command line a script builds rather than on what it printed.
# Nothing in this harness touches the real machine: `flatpak`, `gum`, `sudo`,
# `hyprctl`, `omarchy` and `omarchy-shell` are shadowed by a stub directory that
# comes first on PATH, and HOME is a throwaway directory, so the destructive
# branches can be exercised without installing, updating or removing anything.
#
# The two Omarchy helpers the scripts source when they are on PATH are stubbed
# with empty files on purpose. The real `omarchy-sudo-keepalive` runs `sudo -v`
# and then a `sudo -n true` loop in the background, which is exactly what a
# test must not do; an empty file keeps the sourcing branch itself covered while
# making the rest of the run hermetic.
#
# Usage: ./test/flatpak-scripts.test.sh [name-filter]

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FILTER="${1-}"

SANDBOX="$(mktemp -d)"
BIN="$SANDBOX/bin"
NOFLATPAK="$SANDBOX/noflatpak"
HOME_DIR="$SANDBOX/home"
LOG="$SANDBOX/calls.log"
CATALOGUE="$SANDBOX/catalogue.tsv"
GUM_QUEUE="$SANDBOX/gum-queue"
GUM_PICK_QUEUE="$SANDBOX/gum-picks"
GUM_CAPTURE="$SANDBOX/gum-input"
RUN_PATH="$BIN:/usr/bin:/bin"
XDG_TEST="UNSET"
CURRENT=""
OUT=""
STATUS=0
PASSED=0
FAILED=0
FAILED_NAMES=()

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ------------------------------------------------------------------ fixtures

make_catalogue() {
  printf '%s\n' \
    $'com.spotify.Client\tSpotify' \
    $'com.valvesoftware.Steam\tSteam' \
    $'org.gnome.Calculator\tCalculator' \
    $'org.mozilla.firefox\tFirefox' \
    >"$CATALOGUE"
}

# A PATH that has everything a script legitimately needs except flatpak, so
# "flatpak is not installed" can be tested without touching the real one.
make_noflatpak_bin() {
  mkdir -p "$NOFLATPAK"
  local tool
  for tool in bash awk grep cat env mktemp date cp mv dirname basename cut tr; do
    ln -sf "$(command -v "$tool")" "$NOFLATPAK/$tool"
  done
  local stub
  for stub in gum sudo hyprctl omarchy omarchy-shell omarchy-restart-gum omarchy-sudo-keepalive; do
    cp "$BIN/$stub" "$NOFLATPAK/$stub"
  done
}

make_stubs() {
  mkdir -p "$BIN" "$HOME_DIR"
  : >"$LOG"

  cat >"$BIN/flatpak" <<'STUB'
#!/bin/bash
# Records the argv, then answers from the fixture data the harness set up.
printf 'flatpak %s%s\n' "${STUB_ELEVATED:+[sudo] }" "$*" >>"$STUB_LOG"

scope=""
cmd=""
declare -a pos=()
for arg in "$@"; do
  case "$arg" in
    --user) scope="user" ;;
    --system) scope="system" ;;
    -*) ;;
    *)
      if [[ -z $cmd ]]; then cmd="$arg"; else pos+=("$arg"); fi
      ;;
  esac
done

contains() {
  local needle="$1" word
  shift
  for word in $1; do
    [[ $word == "$needle" ]] && return 0
  done
  return 1
}

name_of() {
  awk -F'\t' -v id="$1" '$1 == id { print $2; found = 1 } END { if (!found) exit 1 }' "$STUB_CATALOGUE_FILE"
}

for failing in ${STUB_FAIL-}; do
  if [[ $failing == "$cmd" ]]; then
    echo "flatpak: stubbed failure for '$cmd'" >&2
    exit 1
  fi
done

case "$cmd" in
  version)
    echo "Flatpak 1.16.0"
    ;;
  list)
    if [[ $scope == "user" ]]; then
      installed="${STUB_INSTALLED_USER-}"
    else
      installed="${STUB_INSTALLED_SYSTEM-}"
    fi
    for id in $installed; do
      if [[ $* == *name* ]]; then
        printf '%s\t%s\n' "$id" "$(name_of "$id" 2>/dev/null || echo "$id")"
      else
        printf '%s\n' "$id"
      fi
    done
    ;;
  info)
    if [[ $scope == "user" ]]; then
      contains "${pos[0]-}" "${STUB_INSTALLED_USER-}"
    else
      contains "${pos[0]-}" "${STUB_INSTALLED_SYSTEM-}"
    fi
    ;;
  remotes)
    for remote in ${STUB_REMOTES-flathub}; do
      printf '%s\n' "$remote"
    done
    ;;
  remote-add)
    echo "added remote ${pos[0]-}"
    ;;
  remote-ls)
    if [[ ${pos[0]-} == "${FLATPAK_REMOTE:-flathub}" ]]; then
      cat "$STUB_CATALOGUE_FILE"
    fi
    ;;
  remote-info)
    if name_of "${pos[1]-}" >/dev/null 2>&1; then
      echo "Spotify - Online music streaming service"
      echo "         ID: ${pos[1]-}"
      echo "      Branch: stable"
      echo "   Download Size: 1.2 MB"
    else
      echo "error: nothing matches ${pos[1]-}" >&2
      exit 1
    fi
    ;;
  install | update | uninstall)
    echo "stub: $cmd ok"
    ;;
  *)
    echo "flatpak: unhandled stub command '$cmd'" >&2
    exit 1
    ;;
esac
STUB

  cat >"$BIN/gum" <<'STUB'
#!/bin/bash
# `choose` answers from a queue file when there is one (a script can ask twice:
# once for the app, once for the scope), and otherwise from STUB_GUM_CHOOSE.
# With neither, it declines. The rows it was given are captured so a test can
# assert on what the picker was actually offered.
# `confirm` consumes one answer per call from its own queue file, which is how a
# test says "yes to the first prompt, no to the second".
printf 'gum %s\n' "$*" >>"$STUB_LOG"

take_from_queue() {
  local queue="$1"
  [[ -n $queue && -s $queue ]] || return 1
  head -n 1 "$queue"
  tail -n +2 "$queue" >"$queue.rest" && mv "$queue.rest" "$queue"
}

case "${1-}" in
  choose)
    input="$(cat)"
    printf '%s' "$input" >"${STUB_GUM_CAPTURE:-$STUB_LOG}.gum"
    if answer="$(take_from_queue "${STUB_GUM_CHOOSE_QUEUE:-}")"; then
      printf '%s\n' "$answer"
      exit 0
    fi
    [[ -n ${STUB_GUM_CHOOSE-} ]] || exit 1
    printf '%s\n' "$STUB_GUM_CHOOSE"
    ;;
  confirm)
    if ! answer="$(take_from_queue "${STUB_GUM_QUEUE:-}")"; then
      exit 1
    fi
    case "$answer" in
      y | Y | yes | Yes) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    echo "gum: unhandled stub subcommand '${1-}'" >&2
    exit 1
    ;;
esac
STUB

  cat >"$BIN/sudo" <<'STUB'
#!/bin/bash
# Records the call, then runs the rest of the argv with the elevation marker
# set, so the log shows which flatpak calls would have asked for a password.
printf 'sudo %s\n' "$*" >>"$STUB_LOG"
case "${1-}" in
  -n | -v | -k | -A)
    exit 0
    ;;
esac
STUB_ELEVATED=1
export STUB_ELEVATED
exec "$@"
STUB

  for name in hyprctl omarchy omarchy-shell; do
    cat >"$BIN/$name" <<STUB
#!/bin/bash
printf '$name %s\n' "\$*" >>"\$STUB_LOG"
exit 0
STUB
  done

  # Sourced, not executed: an empty file is the whole point (see the header).
  printf '# stub: sourcing this must not prompt for sudo\n' >"$BIN/omarchy-sudo-keepalive"
  printf '# stub: sourcing this must not read the live theme\n' >"$BIN/omarchy-restart-gum"

  chmod +x "$BIN"/*
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/.config/hypr"
}

HYPRLAND_FIXTURE='-- omarchy
require("hypr.config")
require("hypr.theme")
require("hypr.monitor")

-- personal overrides
require("hypr.binding")
require("hypr.myrule")
'

NO_MODULES_FIXTURE='# a hyprland config with no personal modules at all
local greeting = "hello"
'

write_hyprland() { printf '%s' "${1-$HYPRLAND_FIXTURE}" >"$HOME_DIR/.config/hypr/hyprland.lua"; }

# ------------------------------------------------------------------- running

run() {
  local script="$1"
  shift
  : >"$LOG"
  rm -f "$GUM_CAPTURE.gum"
  local -a invocation=(env)
  if [[ $XDG_TEST == "UNSET" ]]; then
    invocation+=(-u XDG_DATA_DIRS)
  else
    invocation+=("XDG_DATA_DIRS=$XDG_TEST")
  fi
  invocation+=(PATH="$RUN_PATH" HOME="$HOME_DIR" STUB_LOG="$LOG" STUB_CATALOGUE_FILE="$CATALOGUE"
    STUB_GUM_QUEUE="$GUM_QUEUE" STUB_GUM_CHOOSE_QUEUE="$GUM_PICK_QUEUE" LANG=C
    STUB_GUM_CAPTURE="$GUM_CAPTURE" LANG=C
    STUB_INSTALLED_USER="$STUB_INSTALLED_USER" STUB_INSTALLED_SYSTEM="$STUB_INSTALLED_SYSTEM"
    STUB_REMOTES="$STUB_REMOTES" STUB_FAIL="$STUB_FAIL" STUB_GUM_CHOOSE="$STUB_GUM_CHOOSE")
  OUT="$("${invocation[@]}" "$SCRIPTS/$script" "$@" 2>&1)"
  STATUS=$?
}

# Restores the default fixture state for a flatpak script test.
reset_fixtures() {
  STUB_INSTALLED_USER="org.mozilla.firefox com.spotify.Client"
  STUB_INSTALLED_SYSTEM="com.valvesoftware.Steam"
  STUB_REMOTES="flathub"
  STUB_FAIL=""
  STUB_GUM_CHOOSE=""
  : >"$GUM_QUEUE"
  : >"$GUM_PICK_QUEUE"
  RUN_PATH="$BIN:/usr/bin:/bin"
  XDG_TEST="UNSET"
}

confirm_queue() { printf '%s\n' "$@" >"$GUM_QUEUE"; }

# Answers for successive `gum choose` calls, for a script that asks twice.
pick_queue() { printf '%s\n' "$@" >"$GUM_PICK_QUEUE"; }

# ---------------------------------------------------------------- assertions

pass() {
  PASSED=$((PASSED + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  FAILED_NAMES+=("$CURRENT: $1")
  printf '  FAIL  %s\n' "$1"
  [[ -n ${2-} ]] && printf '        %s\n' "$2"
  return 0
}

log_dump() { tr '\n' '|' <"$LOG"; }

expect_status() {
  if [[ $STATUS == "$1" ]]; then
    pass "exit status is $1"
  else
    fail "exit status is $1" "got $STATUS; output: ${OUT//$'\n'/ | }"
  fi
}

expect_output() {
  if [[ $OUT == *"$1"* ]]; then
    pass "output mentions '$1'"
  else
    fail "output mentions '$1'" "output: ${OUT//$'\n'/ | }"
  fi
}

expect_no_output() {
  if [[ $OUT != *"$1"* ]]; then
    pass "output does not mention '$1'"
  else
    fail "output does not mention '$1'" "output: ${OUT//$'\n'/ | }"
  fi
}

expect_log() {
  if grep -qF -- "$1" "$LOG"; then
    pass "calls include '$1'"
  else
    fail "calls include '$1'" "calls: $(log_dump)"
  fi
}

expect_no_log() {
  if grep -qF -- "$1" "$LOG"; then
    fail "calls exclude '$1'" "calls: $(log_dump)"
  else
    pass "calls exclude '$1'"
  fi
}

expect_log_re() {
  if grep -qE -- "$1" "$LOG"; then
    pass "calls match /$1/"
  else
    fail "calls match /$1/" "calls: $(log_dump)"
  fi
}

expect_no_log_re() {
  if grep -qE -- "$1" "$LOG"; then
    fail "calls exclude /$1/" "calls: $(log_dump)"
  else
    pass "calls exclude /$1/"
  fi
}

# Every logged line matching $1 has to contain $2 as well.
expect_all_matching() {
  local matched
  matched="$(grep -E -- "$1" "$LOG")"
  if [[ -z $matched ]]; then
    fail "at least one call matches /$1/" "calls: $(log_dump)"
    return 0
  fi
  local line
  while IFS= read -r line; do
    if [[ $line != *"$2"* ]]; then
      fail "every /$1/ call contains '$2'" "offending call: $line"
      return 0
    fi
  done <<<"$matched"
  pass "every /$1/ call contains '$2'"
}

expect_count() {
  local count
  count="$(grep -cF -- "$1" "$LOG")"
  if [[ $count == "$2" ]]; then
    pass "'$1' appears $2 time(s)"
  else
    fail "'$1' appears $2 time(s)" "appeared $count time(s); calls: $(log_dump)"
  fi
}

expect_file() {
  if [[ -f $1 ]]; then
    pass "$(basename "$1") exists"
  else
    fail "$(basename "$1") exists" "missing: $1"
  fi
}

expect_no_file() {
  if [[ ! -e $1 ]]; then
    pass "$(basename "$1") does not exist"
  else
    fail "$(basename "$1") does not exist" "unexpected: $1"
  fi
}

expect_file_contains() {
  if [[ -f $1 ]] && grep -qF -- "$2" "$1"; then
    pass "$(basename "$1") contains '$2'"
  else
    fail "$(basename "$1") contains '$2'" "content: $(tr '\n' '|' <"$1" 2>/dev/null)"
  fi
}

expect_same_file() {
  # Command substitution strips the trailing newline on both sides, so a file
  # and the heredoc it was written from compare equal.
  if [[ -f $1 ]] && [[ "$(cat "$1")" == "${2%$'\n'}" ]]; then
    pass "$(basename "$1") is byte-identical"
  else
    fail "$(basename "$1") is byte-identical" "content: $(tr '\n' '|' <"$1" 2>/dev/null)"
  fi
}

# ---------------------------------------------------------------- flatpak-install

test_install_user_scope() {
  reset_fixtures
  STUB_GUM_CHOOSE="Only this user"
  run flatpak-install org.gnome.Calculator
  expect_status 0
  expect_log "flatpak --user install --noninteractive --assumeyes flathub org.gnome.Calculator"
  expect_no_log "[sudo]"
  expect_log "omarchy-shell -q io.github.archlatam.flatpak-refresh refresh"
}

test_install_system_scope_elevates() {
  reset_fixtures
  STUB_GUM_CHOOSE="System (all users)"
  run flatpak-install org.gnome.Calculator
  expect_status 0
  expect_log "flatpak [sudo] --system install --noninteractive --assumeyes flathub org.gnome.Calculator"
  expect_log "sudo flatpak --system"
}

test_install_unknown_app() {
  reset_fixtures
  STUB_GUM_CHOOSE="Only this user"
  run flatpak-install org.example.NotThere
  expect_status 1
  expect_output "is not available on flathub"
  expect_no_log "install --noninteractive"
  expect_no_log "omarchy-shell"
}

test_install_already_installed_declined() {
  reset_fixtures
  STUB_GUM_CHOOSE="Only this user"
  confirm_queue n
  run flatpak-install com.spotify.Client
  expect_status 0
  expect_output "com.spotify.Client is already installed."
  expect_no_log "install --noninteractive"
}

test_install_already_installed_confirmed() {
  reset_fixtures
  STUB_GUM_CHOOSE="Only this user"
  confirm_queue y
  run flatpak-install com.spotify.Client
  expect_status 0
  expect_log "flatpak --user install --noninteractive --assumeyes flathub com.spotify.Client"
}

test_install_adds_user_remote_once() {
  reset_fixtures
  STUB_REMOTES=""
  STUB_GUM_CHOOSE="Only this user"
  run flatpak-install org.gnome.Calculator
  expect_status 0
  expect_log "flatpak --user remotes --columns=name"
  expect_log "flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
  expect_log "flatpak --user install --noninteractive --assumeyes flathub org.gnome.Calculator"
}

test_install_keeps_existing_user_remote() {
  reset_fixtures
  STUB_REMOTES="flathub"
  STUB_GUM_CHOOSE="Only this user"
  run flatpak-install org.gnome.Calculator
  expect_status 0
  expect_no_log "remote-add"
}

test_install_system_scope_leaves_user_remote_alone() {
  reset_fixtures
  STUB_REMOTES=""
  STUB_GUM_CHOOSE="System (all users)"
  run flatpak-install org.gnome.Calculator
  expect_status 0
  expect_no_log "remote-add"
}

test_install_picker_by_name() {
  reset_fixtures
  pick_queue $'Calculator\torg.gnome.Calculator' "Only this user"
  run flatpak-install
  expect_status 0
  expect_log "flatpak --user install --noninteractive --assumeyes flathub org.gnome.Calculator"
}

test_install_picker_cancelled() {
  reset_fixtures
  STUB_GUM_CHOOSE=""
  run flatpak-install
  expect_status 0
  expect_no_log "install --noninteractive"
}

test_install_reports_failure() {
  reset_fixtures
  STUB_FAIL="install"
  STUB_GUM_CHOOSE="Only this user"
  run flatpak-install org.gnome.Calculator
  expect_status 1
  expect_output "flatpak install failed for org.gnome.Calculator"
  expect_no_log "omarchy-shell"
}

test_install_without_flatpak() {
  reset_fixtures
  # Only the symlink farm: /usr/bin has the real flatpak, so it must not be on
  # PATH here or the missing-dependency branch would never run.
  RUN_PATH="$NOFLATPAK"
  run flatpak-install org.gnome.Calculator
  expect_status 1
  expect_output "flatpak is not installed"
  expect_no_log "gum "
}

# ----------------------------------------------------------------- flatpak-update

test_update_one_app_user_scope() {
  reset_fixtures
  run flatpak-update com.spotify.Client
  expect_status 0
  expect_log "flatpak --user update --noninteractive --assumeyes com.spotify.Client"
  expect_no_log "[sudo]"
  expect_log "omarchy-shell -q io.github.archlatam.flatpak-refresh refresh"
}

test_update_one_app_system_scope() {
  reset_fixtures
  run flatpak-update com.valvesoftware.Steam
  expect_status 0
  expect_log "flatpak [sudo] --system update --noninteractive --assumeyes com.valvesoftware.Steam"
}

test_update_one_app_detects_user_over_system() {
  reset_fixtures
  STUB_INSTALLED_USER="com.valvesoftware.Steam"
  run flatpak-update com.valvesoftware.Steam
  expect_status 0
  expect_log "flatpak --user update --noninteractive --assumeyes com.valvesoftware.Steam"
  expect_no_log "[sudo]"
}

test_update_all_touches_only_populated_scope() {
  reset_fixtures
  STUB_INSTALLED_SYSTEM=""
  run flatpak-update
  expect_status 0
  expect_log "flatpak --user update --noninteractive --assumeyes --app"
  expect_no_log "--system update"
}

test_update_all_covers_both_scopes_apps_only() {
  reset_fixtures
  run flatpak-update
  expect_status 0
  expect_log "flatpak --user update --noninteractive --assumeyes --app"
  expect_log "flatpak [sudo] --system update --noninteractive --assumeyes --app"
  # The point of --app: a bare `flatpak update` would drag runtimes along.
  expect_all_matching "^flatpak .*update" "--app"
  expect_no_log_re "update --noninteractive --assumeyes [a-z]"
}

test_update_all_nothing_installed() {
  reset_fixtures
  STUB_INSTALLED_USER=""
  STUB_INSTALLED_SYSTEM=""
  run flatpak-update
  expect_status 0
  expect_output "No flatpaks installed. Nothing to update."
  expect_no_log "update --noninteractive"
}

test_update_unknown_app() {
  reset_fixtures
  run flatpak-update org.example.NotThere
  expect_status 1
  expect_output "org.example.NotThere is not installed"
  expect_no_log "update --noninteractive"
}

test_update_reports_failure() {
  reset_fixtures
  STUB_FAIL="update"
  run flatpak-update com.spotify.Client
  expect_status 1
  expect_output "flatpak update failed for com.spotify.Client"
  expect_no_log "omarchy-shell"
}

# ----------------------------------------------------------------- flatpak-remove

test_remove_user_app_with_unused_sweep() {
  reset_fixtures
  confirm_queue y y
  run flatpak-remove com.spotify.Client
  expect_status 0
  expect_log "flatpak --user uninstall --noninteractive --assumeyes com.spotify.Client"
  expect_log "flatpak --user uninstall --unused --noninteractive --assumeyes"
  expect_log "omarchy-shell -q io.github.archlatam.flatpak-refresh refresh"
}

test_remove_declines_unused_sweep() {
  reset_fixtures
  confirm_queue n y
  run flatpak-remove com.spotify.Client
  expect_status 0
  expect_log "flatpak --user uninstall --noninteractive --assumeyes com.spotify.Client"
  expect_no_log "--unused"
}

test_remove_declines_final_confirm() {
  reset_fixtures
  confirm_queue y n
  run flatpak-remove com.spotify.Client
  expect_status 0
  expect_no_log "uninstall --noninteractive"
  expect_no_log "omarchy-shell"
}

test_remove_system_app_elevates() {
  reset_fixtures
  confirm_queue y y
  run flatpak-remove com.valvesoftware.Steam
  expect_status 0
  expect_log "flatpak [sudo] --system uninstall --noninteractive --assumeyes com.valvesoftware.Steam"
}

test_remove_picker_lists_both_scopes() {
  reset_fixtures
  confirm_queue y y
  STUB_GUM_CHOOSE=$'Steam\tcom.valvesoftware.Steam\tsystem'
  run flatpak-remove
  expect_status 0
  expect_file_contains "$GUM_CAPTURE.gum" $'Firefox\torg.mozilla.firefox\tuser'
  expect_file_contains "$GUM_CAPTURE.gum" $'Steam\tcom.valvesoftware.Steam\tsystem'
  expect_log "flatpak [sudo] --system uninstall --noninteractive --assumeyes com.valvesoftware.Steam"
}

test_remove_unknown_app() {
  reset_fixtures
  confirm_queue y y
  run flatpak-remove org.example.NotThere
  expect_status 1
  expect_output "org.example.NotThere is not installed"
  expect_no_log "uninstall --noninteractive"
}

test_remove_nothing_installed() {
  reset_fixtures
  STUB_INSTALLED_USER=""
  STUB_INSTALLED_SYSTEM=""
  run flatpak-remove
  expect_status 1
  expect_output "no flatpaks are installed"
  expect_no_log "gum "
}

test_remove_reports_failure() {
  reset_fixtures
  STUB_FAIL="uninstall"
  confirm_queue y y
  run flatpak-remove com.spotify.Client
  expect_status 1
  expect_output "flatpak uninstall failed for com.spotify.Client"
  expect_no_log "omarchy-shell"
}

# ------------------------------------------------------------ ensure-launcher-path

XDG_OK="/home/u/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/share"

test_launcher_check_sees_flatpaks() {
  XDG_TEST="$XDG_OK"
  run ensure-launcher-path
  expect_status 0
  expect_output "ok"
}

test_launcher_check_explicit_flag() {
  XDG_TEST="$XDG_OK"
  run ensure-launcher-path --check
  expect_status 0
  expect_output "ok"
}

test_launcher_check_reports_broken() {
  XDG_TEST="/usr/local/share:/usr/share"
  run ensure-launcher-path
  expect_status 1
  expect_output "broken"
}

test_launcher_check_without_xdg_data_dirs() {
  XDG_TEST="UNSET"
  run ensure-launcher-path
  expect_status 1
  expect_output "broken"
}

test_launcher_check_tolerates_trailing_slash() {
  XDG_TEST="/home/u/.local/share/flatpak/exports/share/:/usr/share"
  run ensure-launcher-path
  expect_status 0
  expect_output "ok"
}

test_launcher_check_requires_whole_path_element() {
  # "/opt/flatpak/exports/share-extra" must not satisfy the check: only a real
  # exports directory on its own does.
  XDG_TEST="/opt/flatpak/exports/share-extra:/usr/share"
  run ensure-launcher-path
  expect_status 1
  expect_output "broken"
}

test_launcher_status_prose() {
  XDG_TEST="$XDG_OK"
  run ensure-launcher-path --status
  expect_status 0
  expect_output "The launcher can see Flatpak apps."
}

test_launcher_status_prose_when_broken() {
  XDG_TEST="/usr/share"
  run ensure-launcher-path --status
  expect_status 1
  expect_output "The launcher cannot see Flatpak apps."
  expect_output "XDG_DATA_DIRS is: /usr/share"
}

test_launcher_rejects_unknown_argument() {
  fresh_home
  XDG_TEST="UNSET"
  run ensure-launcher-path --wat
  expect_status 1
  expect_output "usage:"
  expect_no_log "hyprctl"
}

test_launcher_fix_noop_when_already_working() {
  fresh_home
  write_hyprland
  XDG_TEST="$XDG_OK"
  run ensure-launcher-path --fix
  expect_status 0
  expect_output "Nothing to do."
  expect_no_file "$HOME_DIR/.config/hypr/envs.lua"
  expect_no_log "hyprctl"
  expect_no_log "omarchy restart shell"
}

test_launcher_fix_without_hyprland_config() {
  fresh_home
  rm -f "$HOME_DIR/.config/hypr/hyprland.lua"
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  expect_status 1
  expect_output "hyprland.lua not found"
  expect_no_file "$HOME_DIR/.config/hypr/envs.lua"
}

test_launcher_fix_writes_config_and_reloads() {
  fresh_home
  write_hyprland
  before="$(cat "$HOME_DIR/.config/hypr/hyprland.lua")"
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  expect_status 0
  expect_file "$HOME_DIR/.config/hypr/envs.lua"
  expect_file_contains "$HOME_DIR/.config/hypr/envs.lua" 'hl.env("XDG_DATA_DIRS"'
  expect_file_contains "$HOME_DIR/.config/hypr/envs.lua" "/flatpak/exports/share"
  expect_file_contains "$HOME_DIR/.config/hypr/hyprland.lua" 'require("hypr.envs")'
  # The require goes after the last personal module, not at the top.
  if [[ $(grep -n 'require("hypr.envs")' "$HOME_DIR/.config/hypr/hyprland.lua" | head -1 | cut -d: -f1) -gt \
        $(grep -n 'require("hypr.myrule")' "$HOME_DIR/.config/hypr/hyprland.lua" | head -1 | cut -d: -f1) ]]; then
    pass "require(\"hypr.envs\") comes after the last personal require"
  else
    fail "require(\"hypr.envs\") comes after the last personal require" \
      "$(tr '\n' '|' <"$HOME_DIR/.config/hypr/hyprland.lua")"
  fi
  expect_log_re "^hyprctl reload"
  expect_log "omarchy restart shell"
  if [[ $before != "$(cat "$HOME_DIR/.config/hypr/hyprland.lua")" ]]; then
    pass "hyprland.lua was changed"
  else
    fail "hyprland.lua was changed" "unchanged, nothing was added"
  fi
}

test_launcher_fix_backs_up_hyprland_config() {
  fresh_home
  write_hyprland
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  backups="$(find "$HOME_DIR/.config/hypr" -name 'hyprland.lua.bak.*' | wc -l)"
  if [[ $backups == 1 ]]; then
    pass "hyprland.lua was backed up once"
  else
    fail "hyprland.lua was backed up once" "found $backups backups"
  fi
  backup="$(find "$HOME_DIR/.config/hypr" -name 'hyprland.lua.bak.*' | head -1)"
  expect_same_file "$backup" "$HYPRLAND_FIXTURE"
}

test_launcher_fix_is_idempotent() {
  fresh_home
  write_hyprland
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  expect_status 0
  fixed="$(cat "$HOME_DIR/.config/hypr/hyprland.lua")"
  envs="$(cat "$HOME_DIR/.config/hypr/envs.lua")"
  backups="$(find "$HOME_DIR/.config/hypr" -name 'hyprland.lua.bak.*' | wc -l)"

  # The session still cannot see the exports, because nothing reloaded it yet:
  # that is what makes a second run reach the writing branches.
  run ensure-launcher-path --fix
  expect_status 0
  expect_same_file "$HOME_DIR/.config/hypr/hyprland.lua" "$fixed"
  expect_same_file "$HOME_DIR/.config/hypr/envs.lua" "$envs"
  if [[ $(find "$HOME_DIR/.config/hypr" -name 'hyprland.lua.bak.*' | wc -l) == "$backups" ]]; then
    pass "a second --fix makes no new backup"
  else
    fail "a second --fix makes no new backup" "backup count changed"
  fi
  if [[ $(grep -cF 'require("hypr.envs")' "$HOME_DIR/.config/hypr/hyprland.lua") == 1 ]]; then
    pass "the require is still there exactly once"
  else
    fail "the require is still there exactly once" \
      "$(grep -cF 'require("hypr.envs")' "$HOME_DIR/.config/hypr/hyprland.lua") copies"
  fi
}

test_launcher_fix_refuses_to_overwrite_handwritten_envs() {
  fresh_home
  write_hyprland
  handwritten='# mine, do not touch
local x = 1
'
  printf '%s' "$handwritten" >"$HOME_DIR/.config/hypr/envs.lua"
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  expect_status 1
  expect_output "will not overwrite it"
  expect_same_file "$HOME_DIR/.config/hypr/envs.lua" "$handwritten"
  if ! grep -qF 'require("hypr.envs")' "$HOME_DIR/.config/hypr/hyprland.lua"; then
    pass "hyprland.lua was not touched either"
  else
    fail "hyprland.lua was not touched either" "the require was added anyway"
  fi
}

test_launcher_fix_keeps_envs_that_already_handles_the_variable() {
  fresh_home
  write_hyprland
  existing='# written by hand, already correct
local data_home = os.getenv("XDG_DATA_HOME")
hl.env("XDG_DATA_DIRS", "/var/lib/flatpak/exports/share")
'
  printf '%s' "$existing" >"$HOME_DIR/.config/hypr/envs.lua"
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  expect_status 0
  expect_output "already exports XDG_DATA_DIRS"
  expect_same_file "$HOME_DIR/.config/hypr/envs.lua" "$existing"
  expect_file_contains "$HOME_DIR/.config/hypr/hyprland.lua" 'require("hypr.envs")'
}

test_launcher_fix_with_no_personal_modules() {
  fresh_home
  write_hyprland "$NO_MODULES_FIXTURE"
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  expect_status 0
  if [[ $(tail -n 1 "$HOME_DIR/.config/hypr/hyprland.lua") == 'require("hypr.envs")' ]]; then
    pass "the require is appended when there are no personal modules"
  else
    fail "the require is appended when there are no personal modules" \
      "last line: $(tail -n 1 "$HOME_DIR/.config/hypr/hyprland.lua")"
  fi
}

test_launcher_fix_with_require_already_present() {
  fresh_home
  write_hyprland
  printf '%s\n%s\n' "$HYPRLAND_FIXTURE" 'require("hypr.envs")' \
    >"$HOME_DIR/.config/hypr/hyprland.lua"
  XDG_TEST="UNSET"
  run ensure-launcher-path --fix
  expect_status 0
  expect_output "already loads it."
  if [[ $(grep -cF 'require("hypr.envs")' "$HOME_DIR/.config/hypr/hyprland.lua") == 1 ]]; then
    pass "the require appears once, not twice"
  else
    fail "the require appears once, not twice" \
      "$(grep -cF 'require("hypr.envs")' "$HOME_DIR/.config/hypr/hyprland.lua") copies"
  fi
  if [[ $(find "$HOME_DIR/.config/hypr" -name 'hyprland.lua.bak.*' | wc -l) == 0 ]]; then
    pass "no backup when there is nothing to rewrite"
  else
    fail "no backup when there is nothing to rewrite" "a backup was written anyway"
  fi
}

# --------------------------------------------------------------------- driver

main() {
  make_catalogue
  make_stubs
  make_noflatpak_bin

  local tests=()
  while IFS= read -r name; do
    tests+=("$name")
  done < <(declare -F | awk '{ print $3 }' | grep '^test_' | sort)

  local test
  for test in "${tests[@]}"; do
    if [[ -n $FILTER && $test != *"$FILTER"* ]]; then
      continue
    fi
    CURRENT="$test"
    reset_fixtures
    fresh_home
    "$test"
  done

  echo
  printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
  if ((FAILED > 0)); then
    printf 'failing checks:\n'
    local name
    for name in "${FAILED_NAMES[@]}"; do
      printf '  - %s\n' "$name"
    done
    return 1
  fi
  return 0
}

main "$@"
