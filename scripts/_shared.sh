#!/bin/bash

# Shared helpers for the flatpak scripts. Sourced, never run directly.

FLATPAK_REMOTE="${FLATPAK_REMOTE:-flathub}"

# gum picks up the active Omarchy theme only through this, and a theme switch
# mid-session leaves the captured login environment stale.
if command -v omarchy-restart-gum >/dev/null 2>&1; then
  # shellcheck disable=SC1091  # a command on PATH, not a file
  source omarchy-restart-gum
fi

fail() {
  echo -e "\033[31m$*\033[0m" >&2
  exit 1
}

info() {
  echo -e "\033[32m$*\033[0m"
}

# Ask which installation to act on. The panel cannot know the answer: a user
# may want one app system-wide and the next one kept private, and neither is
# wrong. Asked every time rather than remembered, so an install is never
# silently placed in a scope the user did not choose.
#
# Sets SCOPE to "user" or "system".
choose_scope() {
  local header="${1:-Where should this be installed?}"
  local choice=""

  choice=$(gum choose --header="$header" "System (all users)" "Only this user") || exit 0

  case "$choice" in
    "System"*) SCOPE="system" ;;
    "Only"*) SCOPE="user" ;;
    *) exit 0 ;;
  esac

  if [[ $SCOPE == "system" ]]; then
    # Keep the ask-elevated timer alive for the whole flatpak run, which can
    # outlive one sudo prompt.
    # Resolved through PATH like every other omarchy helper, so it works
    # wherever the helpers are installed and can be shadowed in tests.
    if command -v omarchy-sudo-keepalive >/dev/null 2>&1; then
      # shellcheck disable=SC1091  # a command on PATH, not a file
      source omarchy-sudo-keepalive
    fi
    # shellcheck disable=SC2034  # read by the sourcing script
    FLATPAK=(sudo flatpak --system)
  else
    # shellcheck disable=SC2034  # read by the sourcing script
    FLATPAK=(flatpak --user)
  fi
}

# The scope an app is actually installed in, for actions where asking would be
# a lie: flatpak uninstall needs the installation the app lives in, and
# "Only this user" is wrong whenever the app is system-wide.
detect_scope() {
  local app_id="$1"

  if flatpak --user info "$app_id" >/dev/null 2>&1; then
    SCOPE="user"
  elif flatpak --system info "$app_id" >/dev/null 2>&1; then
    SCOPE="system"
  else
    return 1
  fi

  if [[ $SCOPE == "system" ]]; then
    # shellcheck disable=SC2034  # read by the sourcing script
    FLATPAK=(sudo flatpak --system)
  else
    # shellcheck disable=SC2034  # read by the sourcing script
    FLATPAK=(flatpak --user)
  fi
}

app_name() {
  local app_id="$1"
  local name=""
  name=$(env LC_ALL=C flatpak info --show-location "$app_id" 2>/dev/null)
  printf '%s' "${name:-$app_id}"
}

# Which installation to read the $FLATPAK_REMOTE catalogue and per-app info
# from, as the --user/--system flag to pass.
#
# The flag is not optional. `flatpak remote-ls flathub` with neither scope
# makes flatpak stop and ask which installation to use once both have a remote
# of that name, and it answers that by reading stdin: a script run from a
# terminal can be handed the question, but a Process inside the status bar
# cannot, so the catalogue comes back empty and search silently does nothing.
# Every catalogue query is therefore scoped, and this is the one place that
# decides which scope.
#
# The system remote is preferred because it ships with the OS and the user one
# usually does not, so system succeeding means the common case costs no extra
# lookup. A user who has it only in their own installation falls through to
# user. Sets REMOTE_SCOPE to "--system" or "--user"; returns 1 if neither
# installation has the remote, which the caller reports rather than guesses.
resolve_remote_scope() {
  if flatpak --system remotes --columns=name 2>/dev/null | grep -qxF "$FLATPAK_REMOTE"; then
    # shellcheck disable=SC2034  # read by the sourcing script
    REMOTE_SCOPE="--system"
  elif flatpak --user remotes --columns=name 2>/dev/null | grep -qxF "$FLATPAK_REMOTE"; then
    # shellcheck disable=SC2034  # read by the sourcing script
    REMOTE_SCOPE="--user"
  else
    return 1
  fi
}

# A fresh install has flathub configured for the system but not for the user,
# so `flatpak --user install flathub <app>` fails with "remote not found" the
# first time anyone picks the user scope. Adding it here is a one-time, no-sudo
# change confined to the user installation. The system remote is left alone.
ensure_user_remote() {
  local remote="$FLATPAK_REMOTE"
  local url="https://dl.flathub.org/repo/flathub.flatpakrepo"

  if flatpak --user remotes --columns=name 2>/dev/null | grep -qxF "$remote"; then
    return 0
  fi

  info "Adding the $remote remote to your user installation (first run only)…"
  if ! flatpak --user remote-add --if-not-exists "$remote" "$url"; then
    fail "Could not add the $remote remote. Check your connection and try again."
  fi
}

# Push the new state back into the bar widget. The terminal is about to close
# and the panel is polling, but "about to close" is exactly when a refresh
# would be dropped, so ask for one explicitly. -q because the shell may not be
# running and this must never turn into a visible error here.
#
# A dedicated target, not the plugin id: the panel's own ipcTarget already has
# an IpcHandler from qs.Ui.Panel, and Quickshell keeps only the first handler
# registered for a target, so anything added there is dropped.
refresh_panel() {
  omarchy-shell -q io.github.archlatam.flatpak-refresh refresh >/dev/null 2>&1 || true
}
