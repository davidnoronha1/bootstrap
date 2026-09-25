#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh - distro-agnostic dev-machine setup with an interactive TUI
#
#  Install & run (config files live in ./files/ next to this script):
#      git clone https://github.com/davidnoronha1/bootstrap && cd bootstrap
#      bash bootstrap.sh                 # interactive, asked per step
#      bash bootstrap.sh -y              # run everything, no prompts
#      bash bootstrap.sh -y --files-dir /path/to/files   # custom config dir
#
#  The dotfile/tool configs are kept as plain files in ./files/ instead of
#  being embedded here. Point elsewhere with --files-dir or BOOTSTRAP_FILES_DIR.
#  When run via `curl ... | bash` there's no local files dir, so the config
#  steps are skipped.
#
#  Works on Ubuntu 20.04+ and most other distros. Uses only latest/unpinned
#  sources (setup_lts.x, dotnet-install.sh LTS, nvm latest, ...) so it never
#  goes stale. Config defaults come from the author's laptop but machine
#  specific bits (paths, hostnames, keys, identity) are generated or prompted.
# =============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
#  Globals / defaults
# ----------------------------------------------------------------------------
VERSION="1.5.0"
ASSUME_YES=0
TUI_OFF=0
REMOTE_MODE=0
MANAGE_MODE=""
MANAGE_ARG=""
SKIP_USER=0
SKIP_NETWORK=0
SKIP_DOCKER=0
SKIP_NVIDIA=0
SKIP_GHOSTTY=0
SKIP_TOOLS=0
SKIP_NVIM=0
SKIP_TOOLCHAINS=0
SKIP_VSCODE=0
SKIP_CONFIGS=0
SKIP_EXTRAS=0
SKIP_SCPT=0
USER_FLAG=""
RESULTS=()
STEPS_TOTAL=13
SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
INSTALLED_LOG="$HOME/.local/var/bootstrap-managed.txt"

# Run-tracking, used only to offer an opt-in undo if the run is interrupted.
# Installed packages/tools are NEVER auto-removed, no matter what.
TEMP_PATHS=()
CREATED_FILES=()
BACKED_UP_FILES=()
CREATED_USER=""
SSH_KEY_CREATED=0
SSH_KEY_PATH=""
WRITTEN_RC=""
SPINNER_PID=""

ID="" ID_LIKE="" VERSION_ID="" CODENAME="" PRETTY_NAME=""
ARCH="$(uname -m)"
PM="none"
SCRIPT_DIR=""
FILES_DIR=""
DEFAULT_USER=""
TARGET_USER=""
TARGET_HOME=""

# ----------------------------------------------------------------------------
#  TUI helpers
# ----------------------------------------------------------------------------
init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" && $TUI_OFF -eq 0 ]]; then
        C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
        C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
        C_ORANGE=$'\e[38;5;208m'; C_GRAY=$'\e[90m'
    else
        C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_ORANGE=; C_GRAY=
    fi
}

ok()   { printf '%s %s%s%s\n' "${C_GREEN}✓${C_RESET}" "$C_DIM" "$*" "$C_RESET"; }
info() { printf '%s\n' "$*"; }
warn() { printf '%s %s%s%s\n' "${C_ORANGE}⚠${C_RESET}" "$C_DIM" "$*" "$C_RESET" >&2; }
err()  { printf '%s %s\n' "${C_RED}✗${C_RESET}" "$*" >&2; }

# ----------------------------------------------------------------------------
#  Temp-file tracking / cleanup (always runs, on normal exit or interrupt)
# ----------------------------------------------------------------------------
new_tmp() { local t; t="$(mktemp)"; TEMP_PATHS+=("$t"); printf '%s' "$t"; }
new_tmpdir() { local t; t="$(mktemp -d)"; TEMP_PATHS+=("$t"); printf '%s' "$t"; }
register_tmp() { TEMP_PATHS+=("$1"); }

cleanup_tmp() {
    local p
    for p in "${TEMP_PATHS[@]:-}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf "$p"
    done
    TEMP_PATHS=()
}

register_managed() { # register_managed NAME METHOD [PATH]
    local name="$1" method="$2" path="${3:-}"
    local entry="$name|$method"
    [[ -n "$path" ]] && entry="$entry|$path"
    mkdir -p "${INSTALLED_LOG%/*}" 2>/dev/null || asroot mkdir -p "${INSTALLED_LOG%/*}" 2>/dev/null
    printf '%s\n' "$entry" | tee -a "$INSTALLED_LOG" >/dev/null 2>&1 || asroot tee -a "$INSTALLED_LOG" >/dev/null 2>&1 <<< "$entry"
}

# Manage mode: list or remove managed tools
manage_list() {
    if [[ ! -f "$INSTALLED_LOG" ]]; then
        info "no managed tools recorded"
        return 0
    fi
    info "managed tools (installed by this bootstrap):"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '  %s\n' "$line"
    done < "$INSTALLED_LOG"
}

manage_remove() { # manage_remove TOOL
    local target="$1"
    [[ -z "$target" ]] && { err "usage: bootstrap.sh manage remove TOOL"; return 1; }
    [[ ! -f "$INSTALLED_LOG" ]] && { err "no managed tools found"; return 1; }

    local entry name method path found=0 pm
    local tmp="$(new_tmp)"
    while IFS='|' read -r name method path; do
        [[ -z "$name" ]] && continue
        if [[ "$name" == "$target" ]]; then
            found=1
            case "$method" in
                snap)
                    info "removing snap: $name"
                    asroot snap remove "$name" || warn "snap remove $name failed"
                    ;;
                tarball)
                    info "removing tarball: $name from $path"
                    if [[ -n "$path" && -e "$path" ]]; then
                        asroot rm -rf "$path" || warn "rm failed for $path"
                    fi
                    asroot rm -f "/usr/local/bin/$name" 2>/dev/null || true
                    ;;
                distro:*)
                    pm="${method#distro:}"
                    info "removing $name via $pm package manager"
                    case "$pm" in
                        apt)    apt_get remove -y "$name" || warn "apt-get remove $name failed" ;;
                        dnf|yum) asroot "$pm" remove -y "$name" || warn "$pm remove $name failed" ;;
                        pacman) asroot pacman -R --noconfirm "$name" || warn "pacman -R $name failed" ;;
                        zypper) asroot zypper --non-interactive remove "$name" || warn "zypper remove $name failed" ;;
                        apk)    asroot apk del "$name" || warn "apk del $name failed" ;;
                    esac
                    ;;
                *)
                    info "unknown method '$method' for $name; manual removal may be needed"
                    ;;
            esac
        else
            printf '%s|%s' "$name" "$method" >> "$tmp"
            [[ -n "$path" ]] && printf '|%s' "$path" >> "$tmp"
            printf '\n' >> "$tmp"
        fi
    done < "$INSTALLED_LOG"
    [[ $found -eq 0 ]] && { err "tool '$target' not found in managed list"; return 1; }
    asroot cp "$tmp" "$INSTALLED_LOG" 2>/dev/null || cp "$tmp" "$INSTALLED_LOG" 2>/dev/null
    ok "removed $target from managed tools"
}

_manage_load() { # populates MT_NAMES/MT_METHODS arrays from INSTALLED_LOG
    MT_NAMES=(); MT_METHODS=()
    [[ -f "$INSTALLED_LOG" ]] || return 0
    local name method path
    while IFS='|' read -r name method path; do
        [[ -z "$name" ]] && continue
        MT_NAMES+=("$name"); MT_METHODS+=("$method")
    done < "$INSTALLED_LOG"
}

# Interactive TUI: list managed tools, pick some/all to remove, confirm once.
manage_tui() {
    local MT_NAMES=() MT_METHODS=()
    _manage_load
    if [[ ${#MT_NAMES[@]} -eq 0 ]]; then
        info "no managed tools recorded (nothing installed via package manager tracking, snap, or tarball)"
        return 0
    fi

    while true; do
        printf '\n%sManaged tools%s %s(installed by bootstrap.sh)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
        local i
        for i in "${!MT_NAMES[@]}"; do
            printf '  %s%2d)%s %-22s %s(%s)%s\n' "$C_ORANGE" "$((i + 1))" "$C_RESET" "${MT_NAMES[i]}" "$C_DIM" "${MT_METHODS[i]}" "$C_RESET"
        done
        printf '\n  %sa%s) select all   %sq%s) quit\n' "$C_ORANGE" "$C_RESET" "$C_ORANGE" "$C_RESET"
        read_line "Remove which tool(s)? (e.g. '1 3', 'a', or 'q'): "
        local sel="${REPLY:-}"
        [[ -z "$sel" || "$sel" == "q" || "$sel" == "Q" ]] && return 0

        local targets=() tok idx
        if [[ "$sel" == "a" || "$sel" == "A" ]]; then
            targets=("${MT_NAMES[@]}")
        else
            for tok in ${sel//,/ }; do
                if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#MT_NAMES[@]} )); then
                    targets+=("${MT_NAMES[$((tok - 1))]}")
                else
                    warn "skipping invalid selection: $tok"
                fi
            done
        fi
        if [[ ${#targets[@]} -eq 0 ]]; then
            warn "nothing selected"
            continue
        fi

        printf '\n%sAbout to remove:%s %s\n' "$C_BOLD" "$C_RESET" "${targets[*]}"
        if confirm "Proceed with removal?" n; then
            local t
            for t in "${targets[@]}"; do
                manage_remove "$t"
            done
        else
            info "cancelled"
        fi

        _manage_load
        if [[ ${#MT_NAMES[@]} -eq 0 ]]; then
            info "no managed tools remain"
            return 0
        fi
    done
}

# Offered only on Ctrl-C (SIGINT), only interactively, only for things this
# run actually wrote (files it created/overwrote, an ssh key, a new user).
# Never touches anything installed via a package manager or install script.
offer_rollback() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local any=0
    [[ ${#CREATED_FILES[@]} -gt 0 ]] && any=1
    [[ ${#BACKED_UP_FILES[@]} -gt 0 ]] && any=1
    [[ -n "$CREATED_USER" ]] && any=1
    [[ $SSH_KEY_CREATED -eq 1 ]] && any=1
    [[ $any -eq 0 ]] && return 0

    printf '\n%sChanges made so far this run (installed packages/tools are never auto-removed):%s\n' "$C_DIM" "$C_RESET"

    local f
    for f in "${CREATED_FILES[@]:-}"; do
        [[ -z "$f" ]] && continue
        if confirm "Remove newly created file $f?" n; then
            rm -f "$f" 2>/dev/null || asroot rm -f "$f" 2>/dev/null
            [[ "$f" == /etc/netplan/* ]] && { asroot netplan apply 2>/dev/null || true; }
            ok "removed $f"
        fi
    done

    local pair dest bak
    for pair in "${BACKED_UP_FILES[@]:-}"; do
        [[ -z "$pair" ]] && continue
        dest="${pair%%:*}"; bak="${pair#*:}"
        if confirm "Restore original $dest (undo this run's overwrite)?" n; then
            cp "$bak" "$dest" 2>/dev/null || asroot cp "$bak" "$dest" 2>/dev/null
            ok "restored $dest"
        fi
    done

    if [[ $SSH_KEY_CREATED -eq 1 && -n "$SSH_KEY_PATH" ]]; then
        if confirm "Remove the SSH signing key generated this run ($SSH_KEY_PATH)?" n; then
            rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub" 2>/dev/null || asroot rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub" 2>/dev/null
            ok "removed generated ssh key"
        fi
    fi

    if [[ -n "$CREATED_USER" ]]; then
        if confirm "Delete the user '$CREATED_USER' created this run (and its home directory)?" n; then
            if asroot userdel -r "$CREATED_USER" 2>/dev/null; then
                ok "removed user $CREATED_USER"
            else
                warn "failed to remove user $CREATED_USER"
            fi
        fi
    fi
}

TTY_FD=""

tty_open() { # copy stdin from the controlling terminal when stdin is not a tty
    TTY_FD=""
    [[ -t 0 ]] && return 0
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        local fd
        if exec {fd}<>/dev/tty 2>/dev/null; then TTY_FD="$fd"; return 0; fi
    fi
    return 1
}

tty_close() {
    if [[ -n "$TTY_FD" ]]; then
        exec {TTY_FD}<&- 2>/dev/null || true
        TTY_FD=""
    fi
}

tty_read() {
    if [[ -t 0 ]]; then read -r "$1"; else read -r "$1" <&"$TTY_FD"; fi
}

read_line() {
    local prompt="$1"
    REPLY=""
    [[ $ASSUME_YES -eq 1 ]] && return 0
    if tty_open; then
        printf '%s' "$prompt" >&2
        tty_read REPLY
        tty_close
    fi
}

read_hidden() {
    local prompt="$1"
    REPLY=""
    [[ $ASSUME_YES -eq 1 ]] && return 0
    if tty_open; then
        printf '%s' "$prompt" >&2
        if [[ -t 0 ]]; then
            read -r -s REPLY
        else
            read -r -s REPLY <&"$TTY_FD"
        fi
        printf '\n' >&2
        tty_close
    fi
}

confirm() {
    local prompt="$1" default="${2:-N}"
    if [[ $ASSUME_YES -eq 1 ]]; then
        printf '%s %s%s (yes)%s\n' "${C_GREEN}✓${C_RESET}" "$C_DIM" "$prompt" "$C_RESET"
        return 0
    fi
    local yes_opt no_opt q
    if [[ "$default" == [yY]* ]]; then
        yes_opt="${C_DIM}Y${C_RESET}"; no_opt="n"
    else
        yes_opt="y"; no_opt="${C_DIM}N${C_RESET}"
    fi
    q="?"
    [[ "$prompt" == *\? ]] && q=""
    local ans=""
    if tty_open; then
        printf '%s%s [%s/%s] ' "$prompt" "$q" "$yes_opt" "$no_opt"
        tty_read ans
        tty_close
    fi
    case "${ans:-}" in
        ""  ) [[ "$default" == [yY]* ]] && return 0 || return 1 ;;
        [yY]|[yY][eE][sS]) return 0 ;;
        *   ) return 1 ;;
    esac
}

render_bar() { # render_bar DONE TOTAL WIDTH -> bar string (no color codes)
    local done="$1" total="$2" width="${3:-24}" filled=0 bar="" i
    [[ "$total" -gt 0 ]] && filled=$(( done * width / total ))
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = filled; i < width; i++)); do bar+="░"; done
    printf '%s' "$bar"
}

spinner() {
    local msg="$1"; shift
    if [[ -t 1 && $TUI_OFF -eq 0 ]]; then
        local done="${#RESULTS[@]}" bar suffix
        bar="$(render_bar "$done" "$STEPS_TOTAL" 14)"
        suffix=" ${C_ORANGE}${bar}${C_RESET}"
        local log pid rc i
        log="$(new_tmp)"
        "$@" </dev/null >"$log" 2>&1 & pid=$!
        SPINNER_PID=$pid
        i=0
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r\e[K%s%s  %s' "$msg" "$suffix" "${SPIN[i % ${#SPIN[@]}]}"
            i=$((i + 1))
            sleep 0.1
        done
        wait "$pid"; rc=$?
        SPINNER_PID=""
        printf '\r\e[K'
        if [[ $rc -eq 0 ]]; then
            printf '%s %s%s%s\n' "${C_GREEN}✓${C_RESET}" "$C_DIM" "$msg" "$C_RESET"
        else
            printf '%s %s%s%s\n' "${C_RED}✗${C_RESET}" "$C_DIM" "$msg" "$C_RESET"
            [[ -s "$log" ]] && sed 's/^/    /' "$log" >&2
        fi
        rm -f "$log"
        return "$rc"
    fi
    printf '%s ...\n' "$msg"
    "$@"
}

install() { # install LABEL CMD...
    local label="$1" cmd status
    shift
    if [[ -t 1 && $TUI_OFF -eq 0 ]]; then
        printf '%s installing %s%s\n' "$C_DIM" "$label" "$C_RESET"
        printf '%s $ %s\n' "$C_GRAY" "$(printf '%q ' "$@")" "$C_RESET" >&2
    else
        printf '%s\n' "installing $label"
    fi
    "$@"
}

progress_header() {
    local title="$1"
    local done="${#RESULTS[@]}"
    local pct=0
    [[ $STEPS_TOTAL -gt 0 ]] && pct=$(( done * 100 / STEPS_TOTAL ))
    printf '\n%s[%s/%s]%s %s\n' "$C_ORANGE" "$((done + 1))" "$STEPS_TOTAL" "$C_RESET" "$C_BOLD$title$C_RESET"
    printf '   %s%s%s  %s%%\n' "$C_ORANGE" "$(render_bar "$done" "$STEPS_TOTAL" 24)" "$C_RESET" "$pct"
}

run_step() {
    local title="$1" fn="$2" rc
    progress_header "$title"
    if "$fn"; then
        rc=0
        RESULTS+=("${C_GREEN}✓${C_RESET} $title")
    else
        rc=1
        RESULTS+=("${C_RED}✗${C_RESET} $title")
    fi
    return "$rc"
}

skip_step() {
    local title="$1"
    RESULTS+=("${C_DIM}○${C_RESET} $title (skipped)")
    printf '\n%s[%s/%s] %s\n' "$C_ORANGE" "${#RESULTS[@]}" "$STEPS_TOTAL" "$C_DIM$title - skipped$C_RESET"
}

# ----------------------------------------------------------------------------
#  System helpers
# ----------------------------------------------------------------------------
asroot() {
    if [[ $EUID -eq 0 ]]; then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    else err "needs root privileges"; return 1; fi
}

run_user() { # run_user USER cmd args...
    local u="$1"; shift
    local home
    home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
    if [[ -z "$home" || ! -d "$home" ]]; then
        err "no valid home directory for user '$u'"
        return 1
    fi
    local script argcmd
    # Deliberately no trailing $PATH: inheriting the invoking user's PATH would
    # make existence checks (user_cmd_exists) resolve tools that belong to the
    # wrong user when TARGET_USER differs from the one running the script.
    script='export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$HOME/.opencode/bin:$HOME/.dotnet:/snap/bin"; cd "$HOME" || exit 1; eval "$ARG_CMD"'
    argcmd="$(printf '%q ' "$@")"
    if [[ $EUID -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
        ARG_CMD="$argcmd" runuser -u "$u" -- env HOME="$home" bash -c "$script"
    elif [[ $EUID -eq 0 ]]; then
        ARG_CMD="$argcmd" su -s /bin/bash "$u" -c "$script"
    elif [[ "$(id -u)" -eq "$(id -u "$u" 2>/dev/null)" ]]; then
        ARG_CMD="$argcmd" env HOME="$home" bash -c "$script"
    else
        # Not root and a different target user: switch via sudo, otherwise the
        # command runs as the wrong user and can't even cd into the target home.
        ARG_CMD="$argcmd" sudo -u "$u" env HOME="$home" bash -c "$script"
    fi
}

# Check whether a tool is available for the TARGET user specifically. Always
# resolve as that user (never the invoking user's PATH), so a tool installed
# only for the current user isn't mistaken for one the target user has.
user_cmd_exists() {
    run_user "$TARGET_USER" bash -c "command -v $1 >/dev/null 2>&1"
}

# Non-interactive apt-get: without this, dpkg/debconf (or Ubuntu's needrestart)
# can pop a whiptail dialog that gets silently swallowed by spinner()'s output
# capture, leaving the terminal looking stuck and eating the next keypress
# meant for a later confirm() prompt.
apt_get() {
    asroot env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
        apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

_pm_install() {
    case "$PM" in
        apt)   apt_get install -y "$@" && for pkg in "$@"; do register_managed "$pkg" "distro:apt"; done ;;
        dnf|yum) asroot "$PM" install -y "$@" && for pkg in "$@"; do register_managed "$pkg" "distro:$PM"; done ;;
        pacman) asroot pacman -S --needed --noconfirm "$@" && for pkg in "$@"; do register_managed "$pkg" "distro:pacman"; done ;;
        zypper) asroot zypper --non-interactive install -y "$@" && for pkg in "$@"; do register_managed "$pkg" "distro:zypper"; done ;;
        apk)   asroot apk add "$@" && for pkg in "$@"; do register_managed "$pkg" "distro:apk"; done ;;
        *)     warn "no package manager for: $*"; return 1 ;;
    esac
}

ensure_pkg() { # ensure_pkg BINARY PKGNAME
    command -v "$1" >/dev/null 2>&1 && return 0
    info "installing $2 (provides $1)"
    case "$PM" in
        apt) apt_get update -qq || true; apt_get install -y "$2" ;;
        *)   _pm_install "$2" ;;
    esac
}

ensure_pkg_ask() { # ensure_pkg_ask BINARY PKGNAME DESC  (prompts only when missing)
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 present"
    elif confirm "Install $1 (${3:-$2})?" y; then
        ensure_pkg "$1" "$2"
    else
        warn "skipping $1"
    fi
}

is_ver_ge() { # is_ver_ge A B  -> true if A >= B
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# Reads a config file from the local files/ directory (see --files-dir /
# BOOTSTRAP_FILES_DIR). Content functions output these to stdout, so a missing
# file surfaces as an error instead of an empty install.
read_file() { # read_file RELPATH -> stdout
    local rel="$1"
    if [[ ! -f "$FILES_DIR/$rel" ]]; then
        err "missing config file: $FILES_DIR/$rel"
        err "config files live next to bootstrap.sh; run from the repo checkout or set --files-dir/BOOTSTRAP_FILES_DIR"
        return 1
    fi
    cat "$FILES_DIR/$rel"
}

# Replaces __VAR__ placeholders in a template with the current values of the
# named variables (via indirect expansion), e.g.:
#   GIT_NAME="Jane" subst_template "$FILES_DIR/gitconfig" GIT_NAME GIT_EMAIL
# Values are used literally; `&` in a value is escaped so it isn't treated as
# a pattern-replacement anchor.
subst_template() { # subst_template TEMPLATE VAR...
    local tmpl="$1" v line repl
    shift
    if [[ ! -f "$tmpl" ]]; then
        err "missing template: $tmpl"
        return 1
    fi
    while IFS= read -r line; do
        for v in "$@"; do
            repl="${!v//&/\\&}"
            line="${line//__${v}__/$repl}"
        done
        printf '%s\n' "$line"
    done < "$tmpl"
}

_write_file() { # _write_file DEST FUNC
    local dest="$1" srcfn="$2" tmp
    tmp="$(new_tmp)"
    if ! "$srcfn" > "$tmp"; then
        err "failed to generate content for $dest"
        rm -f "$tmp"
        return 1
    fi
    if [[ -e "$dest" ]]; then
        local bak; bak="$(new_tmp)"
        if cp "$dest" "$bak" 2>/dev/null || asroot cp "$dest" "$bak" 2>/dev/null; then
            BACKED_UP_FILES+=("$dest:$bak")
        fi
    else
        CREATED_FILES+=("$dest")
    fi
    asroot install -D -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
    ok "wrote $dest"
}

# Pre-create the standard user directories (XDG-style) owned by TARGET_USER.
# Without these, tools that mkdir their own subdirs (nvim, ghostty, ...) hit a
# root-owned ~/.local or ~/.config left behind by an asroot install -d and fail.
ensure_user_dirs() {
    TARGET_HOME="${TARGET_HOME:-$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)}"
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || return 0
    local dir g
    g="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    for dir in \
        "$TARGET_HOME/.local/bin" \
        "$TARGET_HOME/.local/share" \
        "$TARGET_HOME/.local/state" \
        "$TARGET_HOME/.local/lib" \
        "$TARGET_HOME/.cache" \
        "$TARGET_HOME/.config"; do
        asroot install -d -m 0755 -o "$TARGET_USER" -g "$g" "$dir" 2>/dev/null || true
    done
}

# Final safety net: make the whole home dir owned by TARGET_USER. Tools that
# were installed/symlinked as the invoking user (or root via sudo) may leave
# files or dirs in the home owned by the wrong user, breaking later writes.
ensure_home_ownership() {
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || return 0
    if asroot chown -R "$TARGET_USER:" "$TARGET_HOME" 2>/dev/null; then
        ok "ensured $TARGET_HOME is owned by $TARGET_USER"
    else
        warn "could not chown $TARGET_HOME to $TARGET_USER; check ownership manually"
    fi
}

# ----------------------------------------------------------------------------
#  GPU / driver status
# ----------------------------------------------------------------------------
gpu_status() {
    printf '\n%sGPU / driver status:%s\n' "${C_BOLD}" "$C_RESET"
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/  /'
        cat /proc/driver/nvidia/version 2>/dev/null | head -1 | sed 's/^/  /'
        ok "NVIDIA driver present (nvidia-smi works)"
    elif [[ -d /proc/driver/nvidia ]]; then
        head -1 /proc/driver/nvidia/version 2>/dev/null | sed 's/^/  /'
        ok "NVIDIA driver present"
    else
        if command -v lspci >/dev/null 2>&1; then
            lspci 2>/dev/null | grep -iE 'vga|3d controller|display controller' | sed 's/^/  /'
        fi
        if command -v glxinfo >/dev/null 2>&1; then
            glxinfo -B 2>/dev/null | grep -E 'OpenGL renderer|OpenGL version' | sed 's/^/  /'
        fi
        warn "no NVIDIA driver detected (fine if the GPU is Intel/AMD)"
    fi
}

# ----------------------------------------------------------------------------
#  Step: preflight
# ----------------------------------------------------------------------------
step_preflight() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    ID="${ID:-linux}"; ID_LIKE="${ID_LIKE:-}"; VERSION_ID="${VERSION_ID:-0}"
    CODENAME="${VERSION_CODENAME:-}"; PRETTY_NAME="${PRETTY_NAME:-$ID $VERSION_ID}"
    case "$ARCH" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; esac

    if command -v apt-get >/dev/null 2>&1; then PM=apt
    elif command -v dnf >/dev/null 2>&1; then PM=dnf
    elif command -v yum >/dev/null 2>&1; then PM=yum
    elif command -v pacman >/dev/null 2>&1; then PM=pacman
    elif command -v zypper >/dev/null 2>&1; then PM=zypper
    elif command -v apk >/dev/null 2>&1; then PM=apk
    else PM=none; fi

    info "distro: $PRETTY_NAME   (id=$ID version=$VERSION_ID codename=${CODENAME:-?})"
    info "arch:   $ARCH   package manager: $PM"

    if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
        err "This script needs root (directly or via sudo)."
        return 1
    fi

    ensure_pkg_ask curl curl "needed for downloads"
    ensure_pkg_ask gpg gnupg "needed for repo signing keys"

    gpu_status
    return 0
}

# ----------------------------------------------------------------------------
#  Step: network
# ----------------------------------------------------------------------------
network_status() {
    printf '\n%sNetwork devices:%s\n' "$C_BOLD" "$C_RESET"
    if command -v ip >/dev/null 2>&1; then
        ip -brief link show 2>/dev/null | sed 's/^/  /'
        printf '\n%sAddresses:%s\n' "$C_BOLD" "$C_RESET"
        ip -brief addr show 2>/dev/null | sed 's/^/  /'
        printf '\n%sDefault route:%s\n' "$C_BOLD" "$C_RESET"
        ip route show default 2>/dev/null | sed 's/^/  /'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig -a 2>/dev/null | sed 's/^/  /'
    else
        warn "neither 'ip' nor 'ifconfig' found; can't show network devices"
    fi
}

_apply_netplan_static() {
    local iface="$1" addr="$2" gw="$3" dns="$4"
    local file="/etc/netplan/99-bootstrap-static.yaml"
    local dns_csv tmp
    dns_csv="$(printf '%s' "$dns" | tr -s ' ' ',')"
    tmp="$(new_tmp)"
    {
        printf 'network:\n'
        printf '  version: 2\n'
        printf '  ethernets:\n'
        printf '    %s:\n' "$iface"
        printf '      dhcp4: false\n'
        printf '      addresses: [%s]\n' "$addr"
        printf '      routes:\n'
        printf '        - to: default\n'
        printf '          via: %s\n' "$gw"
        printf '      nameservers:\n'
        printf '        addresses: [%s]\n' "$dns_csv"
    } > "$tmp"
    info "netplan config to write to $file:"
    sed 's/^/    /' "$tmp"
    if ! confirm "Write and apply this config now (runs 'netplan apply')?" n; then
        info "left unapplied; review $tmp yourself and copy it to $file if you want it"
        return 0
    fi
    if asroot install -m 0600 "$tmp" "$file"; then
        CREATED_FILES+=("$file")
    else
        err "failed to write $file"
        return 1
    fi
    if asroot netplan apply; then
        ok "static IP applied via netplan ($file)"
    else
        err "netplan apply failed; check $file and run 'sudo netplan apply' manually"
        return 1
    fi
}

_apply_nmcli_static() {
    local iface="$1" addr="$2" gw="$3" dns="$4" con
    if ! confirm "Apply static IP via NetworkManager (nmcli) now?" n; then
        info "skipped; the equivalent command is:"
        info "  nmcli con mod <profile> ipv4.addresses $addr ipv4.gateway $gw ipv4.dns \"$dns\" ipv4.method manual"
        return 0
    fi
    con="$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$iface" '$2==d{print $1; exit}')"
    if [[ -z "$con" ]]; then
        warn "no active NetworkManager connection found for $iface"
        return 1
    fi
    if asroot nmcli con mod "$con" ipv4.addresses "$addr" ipv4.gateway "$gw" ipv4.dns "$dns" ipv4.method manual \
        && asroot nmcli con up "$con"; then
        ok "static IP applied via NetworkManager ($con)"
    else
        err "nmcli configuration failed"
        return 1
    fi
}

step_network() {
    network_status
    if ! confirm "Configure a static IP for this machine?" n; then
        info "leaving network configuration as-is (DHCP/current)"
        return 0
    fi
    warn "Misconfiguring this can drop your network/SSH connection."
    if ! confirm "Are you SURE you want to continue?" n; then
        info "static IP setup cancelled"
        return 0
    fi

    read_line "Interface to configure (e.g. eth0): "; local iface="${REPLY:-}"
    if [[ -z "$iface" ]]; then warn "no interface given, aborting"; return 1; fi
    if command -v ip >/dev/null 2>&1 && ! ip link show "$iface" >/dev/null 2>&1; then
        warn "interface '$iface' not found"
        return 1
    fi

    read_line "Static IP with CIDR (e.g. 192.168.1.50/24): "; local addr="${REPLY:-}"
    read_line "Gateway (e.g. 192.168.1.1): "; local gw="${REPLY:-}"
    read_line "DNS servers, space separated [1.1.1.1 8.8.8.8]: "; local dns="${REPLY:-1.1.1.1 8.8.8.8}"
    if [[ -z "$addr" || -z "$gw" ]]; then
        warn "IP/gateway required; aborting static IP setup"
        return 1
    fi

    if command -v netplan >/dev/null 2>&1 || [[ -d /etc/netplan ]]; then
        _apply_netplan_static "$iface" "$addr" "$gw" "$dns"
    elif command -v nmcli >/dev/null 2>&1; then
        _apply_nmcli_static "$iface" "$addr" "$gw" "$dns"
    else
        warn "no supported network manager (netplan/NetworkManager) found; configure '$iface' -> $addr via $gw manually"
        return 1
    fi
}

# ----------------------------------------------------------------------------
#  Step: user
# ----------------------------------------------------------------------------
step_user() {
    if [[ -n "$USER_FLAG" ]]; then
        TARGET_USER="$USER_FLAG"
    else
        if confirm "Create a dedicated new user for this setup?" n; then
            read_line "New username: "
            local nu="${REPLY:-}"
            if [[ -z "$nu" ]]; then
                warn "empty username, keeping current user"
            elif getent passwd "$nu" >/dev/null 2>&1; then
                warn "user '$nu' already exists, using it"
                TARGET_USER="$nu"
            else
                if ! asroot useradd -m -s /bin/bash "$nu"; then
                    err "failed to create user '$nu'"
                    return 1
                fi
                local nu_home
                nu_home="$(getent passwd "$nu" 2>/dev/null | cut -d: -f6)"
                if [[ -n "$nu_home" && -d "$nu_home" ]]; then
                    asroot chown -R "$nu:$nu" "$nu_home" 2>/dev/null || true
                fi
                CREATED_USER="$nu"
                read_hidden "Password for $nu (leave empty for none): "
                if [[ -n "${REPLY:-}" ]]; then
                    printf '%s:%s\n' "$nu" "$REPLY" | asroot chpasswd
                fi
                TARGET_USER="$nu"
            fi
        else
            read_line "Target user for this setup [${DEFAULT_USER}]: "
            if [[ -n "${REPLY:-}" ]]; then
                if getent passwd "${REPLY}" >/dev/null 2>&1; then
                    TARGET_USER="${REPLY}"
                else
                    warn "user '${REPLY}' does not exist; using ${DEFAULT_USER}"
                fi
            fi
        fi
    fi
    TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        err "target user '$TARGET_USER' has no valid home directory"
        return 1
    fi
    ensure_user_dirs
    # Grant sudo/wheel and docker separately: usermod -aG is atomic across all
    # named groups, and the 'docker' group doesn't exist until step_docker
    # installs Docker later, which would otherwise silently block sudo too.
    if asroot usermod -aG sudo "$TARGET_USER" 2>/dev/null || asroot usermod -aG wheel "$TARGET_USER" 2>/dev/null; then
        ok "target user: $TARGET_USER ($TARGET_HOME) [sudo]"
    else
        warn "could not add $TARGET_USER to sudo/wheel group"
    fi
    asroot groupadd -f docker 2>/dev/null || true
    asroot usermod -aG docker "$TARGET_USER" 2>/dev/null || true
    return 0
}

# ----------------------------------------------------------------------------
#  Step: docker
# ----------------------------------------------------------------------------
_docker_apt_repo() {
    asroot install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | asroot gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg || return 1
    asroot chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    local arch dist
    arch="$(dpkg --print-architecture 2>/dev/null || echo "$ARCH")"
    dist="${CODENAME:-$VERSION_ID}"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$arch" "$ID" "$dist" | asroot tee /etc/apt/sources.list.d/docker.list >/dev/null || return 1
    apt_get update -qq || return 1
}

_docker_apt_install() {
    apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Set up a Docker credential store via the `pass` helper so `docker login`
# creds aren't kept in plaintext ~/.docker/config.json. Generates a
# passwordless GPG key for the target user if they don't have one yet.
_docker_creds_store() {
    local dcfg="$TARGET_HOME/.docker/config.json"
    local gpgid="" arch ver tmpdir g

    ensure_pkg gpg gnupg
    ensure_pkg pass pass
    ensure_pkg jq jq
    command -v pass >/dev/null 2>&1 || { warn "pass not available; docker credentials would stay in plaintext"; return 1; }
    g="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"

    gpgid="$(run_user "$TARGET_USER" gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/{print $5; exit}')"
    if [[ -z "$gpgid" ]]; then
        info "generating a passwordless ed25519 GPG key for the pass store..."
        if ! run_user "$TARGET_USER" bash -c '
            gpg --batch --quiet --gen-key <<"EOF"
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Bootstrap Pass
Name-Email: bootstrap@localhost
Expire-Date: 0
%commit
EOF
        '; then
            err "gpg key generation failed"
            return 1
        fi
        gpgid="$(run_user "$TARGET_USER" gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/{print $5; exit}')"
    fi
    if [[ -z "$gpgid" ]]; then
        err "could not determine the gpg key id"
        return 1
    fi

    if [[ ! -d "$TARGET_HOME/.password-store" ]]; then
        if ! run_user "$TARGET_USER" pass init "$gpgid"; then
            err "pass init failed"
            return 1
        fi
        ok "password store initialized with gpg key $gpgid"
    fi

    if ! command -v docker-credential-pass >/dev/null 2>&1; then
        info "installing docker-credential-pass..."
        _pm_install golang-docker-credential-helpers 2>/dev/null \
            || _pm_install golang-github-docker-docker-credential-helpers 2>/dev/null || true
        if ! command -v docker-credential-pass >/dev/null 2>&1; then
            ver="$(curl -fsSL https://api.github.com/repos/docker/docker-credential-helpers/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"
            arch="amd64"; [[ "$ARCH" == arm64 ]] && arch="arm64"
            if [[ -n "$ver" ]]; then
                tmpdir="$(new_tmpdir)"
                if curl -fSL --retry 2 -# -o "$tmpdir/docker-credential-pass" \
                    "https://github.com/docker/docker-credential-helpers/releases/download/v${ver}/docker-credential-pass-v${ver}.linux-${arch}"; then
                    asroot install -m 0755 "$tmpdir/docker-credential-pass" /usr/local/bin/docker-credential-pass
                    register_managed "docker-credential-pass" "binary" "/usr/local/bin/docker-credential-pass"
                else
                    warn "docker-credential-pass download failed"
                fi
            else
                warn "could not determine docker-credential-helpers release"
            fi
        fi
    fi
    command -v docker-credential-pass >/dev/null 2>&1 || { warn "docker-credential-pass not installed; creds stay in plaintext"; return 1; }

    asroot install -d -m 0755 -o "$TARGET_USER" -g "$g" "$TARGET_HOME/.docker"
    local tmp
    tmp="$(new_tmp)"
    if [[ -f "$dcfg" ]]; then
        jq '.credsStore = "pass"' "$dcfg" > "$tmp" 2>/dev/null || cp "$dcfg" "$tmp"
    else
        printf '{ "credsStore": "pass" }\n' > "$tmp"
    fi
    asroot install -o "$TARGET_USER" -g "$g" -m 0600 "$tmp" "$dcfg"
    rm -f "$tmp"
    ok "docker credential store set to 'pass' ($dcfg)"
    return 0
}

step_docker() {
    if command -v docker >/dev/null 2>&1; then
        ok "docker already installed: $(docker --version 2>/dev/null | head -1)"
    else
        if ! confirm "Install Docker + Docker Compose?" y; then return 0; fi

        case "$PM" in
            apt)
                if ! _docker_apt_repo || ! _docker_apt_install; then
                    warn "official Docker repo failed; falling back to distro package"
                    asroot rm -f /etc/apt/sources.list.d/docker.list
                    apt_get update -qq || true
                    _pm_install docker.io docker-compose-v2 2>/dev/null || _pm_install docker.io docker-compose || true
                fi
                ;;
            dnf|yum)
                asroot "$PM" config-manager --add-repo "https://download.docker.com/linux/${ID}/docker-ce.repo" 2>/dev/null \
                    || curl -fsSL "https://download.docker.com/linux/${ID}/docker-ce.repo" | asroot tee /etc/yum.repos.d/docker-ce.repo >/dev/null
                _pm_install docker-ce docker-ce-cli containerd.io docker-compose-plugin || _pm_install docker docker-compose || true
                ;;
            pacman) _pm_install docker docker-compose || true ;;
            zypper) _pm_install docker docker-compose || true ;;
            apk)    _pm_install docker docker-cli-compose || true ;;
            *)
                warn "no native docker package; using Docker's convenience script"
                if confirm "Run get.docker.com convenience script?" y; then
                    curl -fsSL https://get.docker.com | asroot sh || return 1
                fi
                ;;
        esac

        command -v docker >/dev/null 2>&1 || { err "docker install failed"; return 1; }
        asroot systemctl enable --now docker >/dev/null 2>&1 || true
        asroot usermod -aG docker "$TARGET_USER" 2>/dev/null || true
        ok "docker enabled and '$TARGET_USER' added to the docker group"

        if docker compose version >/dev/null 2>&1; then
            ok "docker compose v2 available"
        elif command -v docker-compose >/dev/null 2>&1; then
            ok "docker-compose (v1) available"
        else
            warn "docker compose plugin not found"
        fi
    fi

    if confirm "Set up a Docker credential store (docker login creds kept in pass, not plaintext)?" y; then
        _docker_creds_store || warn "docker credential store setup incomplete; see messages above"
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Step: nvidia
# ----------------------------------------------------------------------------
step_nvidia() {
    if command -v nvidia-container-runtime >/dev/null 2>&1 \
        || { command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W nvidia-container-toolkit >/dev/null 2>&1; }; then
        ok "nvidia container toolkit already installed"
        return 0
    fi
    if ! command -v nvidia-smi >/dev/null 2>&1 && [[ ! -d /proc/driver/nvidia ]] \
        && ! (command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi nvidia); then
        ok "no NVIDIA GPU detected; skipping container toolkit"
        return 0
    fi
    if ! confirm "Install NVIDIA Container Toolkit?" y; then return 0; fi

    case "$PM" in
        apt)
            local dist="$ID$VERSION_ID"
            asroot install -m 0755 -d /usr/share/keyrings
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | asroot gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg || return 1
            curl -fsSL "https://nvidia.github.io/libnvidia-container/${dist}/libnvidia-container.list" \
                | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                | asroot tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null || return 1
            apt_get update -qq || true
            _pm_install nvidia-container-toolkit || { warn "nvidia-container-toolkit install failed"; return 1; }
            ;;
        dnf|yum)
            curl -fsSL "https://nvidia.github.io/libnvidia-container/${ID}${VERSION_ID}/libnvidia-container.repo" \
                | asroot tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null || return 1
            _pm_install nvidia-container-toolkit || { warn "nvidia-container-toolkit install failed"; return 1; }
            ;;
        pacman)
            _pm_install nvidia-container-toolkit || warn "nvidia-container-toolkit not in repos (try AUR)" ;;
        *)
            warn "no packaged nvidia container toolkit for '$PM'; skipping"
            return 0
            ;;
    esac

    if command -v nvidia-ctk >/dev/null 2>&1; then
        asroot nvidia-ctk runtime configure --runtime=docker || warn "nvidia-ctk runtime configure failed"
        asroot systemctl restart docker >/dev/null 2>&1 || true
        ok "nvidia runtime configured for docker"
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Step: ghostty
# ----------------------------------------------------------------------------
_install_ghostty() {
    if ! command -v snap >/dev/null 2>&1; then
        _pm_install snapd || return 1
        asroot systemctl enable --now snapd.socket >/dev/null 2>&1 || true
        local i
        for i in $(seq 1 30); do snap version >/dev/null 2>&1 && break; sleep 1; done
    fi
    asroot snap install ghostty --classic
    register_managed "ghostty" "snap"
}

_ghostty_terminfo() {
    local src=""
    local f
    for f in \
        /usr/share/terminfo/x/xterm-ghostty \
        /usr/lib/terminfo/x/xterm-ghostty \
        /lib/terminfo/x/xterm-ghostty \
        /snap/ghostty/current/usr/share/terminfo/x/xterm-ghostty \
        /snap/ghostty/current/usr/share/terminfo/78/xterm-ghostty \
        /snap/ghostty/current/share/terminfo/x/xterm-ghostty \
        /snap/ghostty/current/share/terminfo/78/xterm-ghostty; do
        [[ -f "$f" ]] && { src="$f"; break; }
    done
    if [[ -n "$src" ]]; then
        asroot install -d -m 0755 "$TARGET_HOME/.terminfo/x"
        asroot cp "$src" "$TARGET_HOME/.terminfo/x/xterm-ghostty"
        asroot chown -R "$TARGET_USER:" "$TARGET_HOME/.terminfo" 2>/dev/null || true
        ok "terminfo xterm-ghostty -> $TARGET_HOME/.terminfo/x/"
    elif command -v infocmp >/dev/null 2>&1 && infocmp -x xterm-ghostty >/dev/null 2>&1; then
        if infocmp -x xterm-ghostty | asroot tic -x -o "$TARGET_HOME/.terminfo" - >/dev/null 2>&1; then
            asroot chown -R "$TARGET_USER:" "$TARGET_HOME/.terminfo" 2>/dev/null || true
            ok "terminfo xterm-ghostty compiled into $TARGET_HOME/.terminfo"
        else
            warn "terminfo compile failed"
        fi
    else
        warn "couldn't find the xterm-ghostty terminfo entry; programs may want TERM=xterm-256color"
    fi
}

step_ghostty() {
    ensure_user_dirs
    if command -v ghostty >/dev/null 2>&1; then
        ok "ghostty already installed ($(ghostty --version 2>/dev/null | head -1 || echo '?')), skipping"
        return 0
    fi
    if ! confirm "Install Ghostty (via snap)?" y; then return 0; fi

    if spinner "installing ghostty" _install_ghostty; then
        ok "ghostty installed: $(ghostty --version 2>/dev/null | head -1)"
        _ghostty_terminfo
    else
        err "ghostty install failed"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Step: tools
# ----------------------------------------------------------------------------
_install_gh() {
    case "$PM" in
        apt|dnf|yum|pacman|zypper)
            _pm_install github-cli || _pm_install gh || return 1
            ;;
        *)
            local ver tmp
            ver="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"
            [[ -n "$ver" ]] || return 1
            tmp="$(new_tmp)"
            printf '%s\n' "downloading gh v${ver}..."
            curl -fSL --retry 2 -# -o "$tmp" "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_${ARCH}.tar.gz" || return 1
            asroot tar -xzf "$tmp" -C /usr/local --strip-components=1
            register_managed "gh" "tarball" "/usr/local/bin/gh"
            ;;
    esac
    command -v gh >/dev/null 2>&1
}

# Debian/Ubuntu ship fd/bat under different binary names to avoid clashes
# with unrelated packages; symlink them into ~/.local/bin so `fd`/`bat` work.
_symlink_local_bin() { # _symlink_local_bin SRC_BIN LINK_NAME
    local src link
    src="$(command -v "$1" 2>/dev/null)" || return 1
    link="$TARGET_HOME/.local/bin/$2"
    asroot install -d -m 0755 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$TARGET_HOME/.local/bin"
    asroot ln -sf "$src" "$link"
    asroot chown -h "$TARGET_USER:" "$link" 2>/dev/null || true
}

_install_fd() {
    command -v fd >/dev/null 2>&1 && return 0
    case "$PM" in
        apt) _pm_install fd-find || return 1 ;;
        *)   _pm_install fd 2>/dev/null || _pm_install fd-find || return 1 ;;
    esac
    command -v fd >/dev/null 2>&1 && return 0
    command -v fdfind >/dev/null 2>&1 && _symlink_local_bin fdfind fd
    command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1
}

_install_bat() {
    command -v bat >/dev/null 2>&1 && return 0
    _pm_install bat || return 1
    command -v bat >/dev/null 2>&1 && return 0
    command -v batcat >/dev/null 2>&1 && _symlink_local_bin batcat bat
    command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1
}

_install_zoxide() {
    command -v zoxide >/dev/null 2>&1 && return 0
    if _pm_install zoxide 2>/dev/null && command -v zoxide >/dev/null 2>&1; then return 0; fi
    printf '%s installing zoxide from upstream...%s\n' "$C_DIM" "$C_RESET"
    run_user "$TARGET_USER" bash -c 'curl -fSL --retry 2 -# https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash'
}

write_rc_file() { # write_rc_file HOME RC_FILE NAME  (e.g. write_rc_file /home/bob .zshrc zshrc)
    local home="$1" rcfile="$2" name="$3" tmp dest
    dest="$home/$rcfile"
    tmp="$(new_tmp)"
    if ! read_file "$name" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [[ -f "$dest" ]]; then
        asroot cp -p "$dest" "$dest.bak" 2>/dev/null || true
        asroot chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$dest.bak" 2>/dev/null || true
        BACKED_UP_FILES+=("$dest:$dest.bak")
        info "existing $rcfile backed up to $rcfile.bak"
    else
        CREATED_FILES+=("$dest")
    fi
    asroot install -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
    WRITTEN_RC="$rcfile"
    ok "wrote $dest"
}

step_tools() {
    ensure_user_dirs
    if confirm "Install git?" y; then
        if command -v git >/dev/null 2>&1; then ok "git already installed"
        else spinner "installing git" _pm_install git || warn "git install failed"; fi
    fi

    local want_zsh=0
    if confirm "Install zsh?" y; then
        want_zsh=1
        if command -v zsh >/dev/null 2>&1; then ok "zsh already installed"
        else spinner "installing zsh" _pm_install zsh || warn "zsh install failed"; fi
    fi

    if confirm "Install btop (system monitor)?" y; then
        if command -v btop >/dev/null 2>&1; then ok "btop already installed"
        else spinner "installing btop" _pm_install btop || warn "btop install failed"; fi
    fi

    if confirm "Install ripgrep (rg - faster grep)?" y; then
        if command -v rg >/dev/null 2>&1; then ok "ripgrep already installed"
        else spinner "installing ripgrep" _pm_install ripgrep || warn "ripgrep install failed"; fi
    fi

    if confirm "Install fd (faster find)?" y; then
        if command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1; then ok "fd already installed"
        else spinner "installing fd" _install_fd || warn "fd install failed"; fi
    fi

    if confirm "Install bat (cat with syntax highlighting)?" y; then
        if command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1; then ok "bat already installed"
        else spinner "installing bat" _install_bat || warn "bat install failed"; fi
    fi

    if confirm "Install zoxide (z - faster cd / navigation)?" y; then
        if command -v zoxide >/dev/null 2>&1; then ok "zoxide already installed"
        else spinner "installing zoxide" _install_zoxide || warn "zoxide install failed"; fi
    fi

    if confirm "Install fzf (fuzzy finder, pairs well with rg/fd)?" y; then
        if command -v fzf >/dev/null 2>&1; then ok "fzf already installed"
        else spinner "installing fzf" _pm_install fzf || warn "fzf install failed"; fi
    fi

    if confirm "Install jq (JSON processor)?" y; then
        if command -v jq >/dev/null 2>&1; then ok "jq already installed"
        else spinner "installing jq" _pm_install jq || warn "jq install failed"; fi
    fi

    if confirm "Install eza (modern ls replacement)?" n; then
        if command -v eza >/dev/null 2>&1; then ok "eza already installed"
        else spinner "installing eza" _pm_install eza || warn "eza install failed (not packaged on every distro)"; fi
    fi

    if confirm "Install ncdu (interactive disk usage)?" n; then
        if command -v ncdu >/dev/null 2>&1; then ok "ncdu already installed"
        else spinner "installing ncdu" _pm_install ncdu || warn "ncdu install failed"; fi
    fi

    if confirm "Install GitHub CLI (gh)?" y; then
        if user_cmd_exists gh; then ok "gh already installed"
        else spinner "installing GitHub CLI" _install_gh || warn "gh install failed"; fi
    fi

    if confirm "Install Claude Code?" y; then
        if user_cmd_exists claude; then ok "claude code already installed"
        else
            info "installing Claude Code (native binary)"
            if run_user "$TARGET_USER" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
                ok "claude code installed"
            else
                warn "claude code install failed"
            fi
        fi
    fi

    if confirm "Install opencode?" y; then
        if user_cmd_exists opencode; then ok "opencode already installed"
        else
            info "installing opencode"
            if run_user "$TARGET_USER" bash -c 'curl -fsSL https://opencode.ai/install | bash'; then
                ok "opencode installed"
            else
                warn "opencode install failed"
            fi
        fi
    fi

    # Only write the rc file for the shell actually set as the target's login
    # shell. Switching shells is a user choice, so a declined chsh keeps bash
    # (and its config), while an existing zsh login shell gets .zshrc.
    local cur_shell zsh_cmd
    cur_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
    zsh_cmd="$(command -v zsh 2>/dev/null || true)"

    if [[ $want_zsh -eq 1 && -n "$zsh_cmd" ]] && confirm "Set default shell to zsh and write ~/.zshrc?" y; then
        if write_rc_file "$TARGET_HOME" ".zshrc" "zshrc"; then
            if [[ "$cur_shell" != "$zsh_cmd" ]]; then
                if asroot chsh -s "$zsh_cmd" "$TARGET_USER" 2>/dev/null; then
                    ok "default shell -> zsh for $TARGET_USER (new shells only)"
                else
                    warn "chsh failed; set shell manually with: chsh -s $zsh_cmd"
                fi
            fi
        else
            warn "failed to write ~/.zshrc"
        fi
    elif [[ "$cur_shell" == */zsh ]]; then
        if confirm "Write ~/.zshrc (adds zoxide & installed tools to PATH)?" y; then
            write_rc_file "$TARGET_HOME" ".zshrc" "zshrc" || warn "failed to write ~/.zshrc"
        fi
    else
        if confirm "Write ~/.bashrc (adds zoxide & installed tools to PATH)?" y; then
            write_rc_file "$TARGET_HOME" ".bashrc" "bashrc" || warn "failed to write ~/.bashrc"
        fi
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Step: neovim + lazyvim
# ----------------------------------------------------------------------------
_install_neovim() {
    local narch="x86_64" tmp url dir
    [[ "$ARCH" == arm64 ]] && narch="arm64"
    url="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${narch}.tar.gz"
    tmp="$(new_tmpdir)"
    printf '%s\n' "downloading neovim (linux-${narch})..."
    if curl -fSL --retry 2 -# "$url" -o "$tmp/nvim.tar.gz"; then
        asroot tar -xzf "$tmp/nvim.tar.gz" -C /opt 2>/dev/null || return 1
        dir="$(find /opt -maxdepth 1 -type d -name 'nvim-linux*' 2>/dev/null | head -1)"
        if [[ -n "$dir" ]]; then
            asroot ln -sf "$dir/bin/nvim" /usr/local/bin/nvim 2>/dev/null || true
            register_managed "nvim" "tarball" "$dir"
            command -v nvim >/dev/null 2>&1
        else
            warn "couldn't locate extracted neovim directory"
            return 1
        fi
    else
        warn "official neovim tarball fetch failed"
        return 1
    fi
}

_install_lazyvim() {
    local cfg="$TARGET_HOME/.config/nvim" stamp
    stamp="$(date +%Y%m%d%H%M%S)"
    if [[ -e "$cfg" ]]; then
        if ! confirm "Existing nvim config found at $cfg - back it up and replace with LazyVim?" n; then
            warn "skipping LazyVim; existing nvim config left untouched"
            return 0
        fi
        asroot mv "$cfg" "$cfg.bak-$stamp"
        info "backed up existing config to $cfg.bak-$stamp"
    fi
    local p
    for p in "$TARGET_HOME/.local/share/nvim" "$TARGET_HOME/.local/state/nvim" "$TARGET_HOME/.cache/nvim"; do
        [[ -e "$p" ]] && asroot mv "$p" "$p.bak-$stamp"
    done
    # Make sure .config is writable by the target user before cloning into it.
    ensure_user_dirs
    if run_user "$TARGET_USER" git clone --depth 1 https://github.com/LazyVim/starter "$cfg"; then
        run_user "$TARGET_USER" rm -rf "$cfg/.git" 2>/dev/null || true
        if [[ -f "$cfg/init.lua" ]]; then
            asroot chown -R "$TARGET_USER:" "$cfg" 2>/dev/null || true
            ok "LazyVim starter installed at $cfg"
            if spinner "installing LazyVim plugins" run_user "$TARGET_USER" nvim --headless "+Lazy! sync" +qa; then
                ok "LazyVim plugins installed"
            else
                warn "LazyVim plugin sync failed; run 'nvim' once to finish installing plugins"
            fi
        else
            warn "LazyVim clone incomplete (no init.lua in $cfg)"
            return 1
        fi
    else
        warn "LazyVim clone failed"
        return 1
    fi
    return 0
}

step_neovim() {
    ensure_user_dirs
    if confirm "Install latest Neovim?" y; then
        if command -v nvim >/dev/null 2>&1; then
            ok "neovim already installed: $(nvim --version 2>/dev/null | head -1)"
        elif spinner "installing neovim" _install_neovim; then
            ok "neovim installed: $(nvim --version 2>/dev/null | head -1)"
        else
            warn "neovim install failed"
            return 0
        fi
    else
        return 0
    fi

    if confirm "Install LazyVim (Neovim config distribution)?" y; then
        if ! _install_lazyvim; then
            warn "LazyVim setup failed; see messages above"
        fi
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Step: toolchains (unpinned / always-latest)
# ----------------------------------------------------------------------------
_install_node() {
    case "$PM" in
        apt)
            curl -fsSL https://deb.nodesource.com/setup_lts.x | asroot bash - || return 1
            apt_get install -y nodejs || return 1
            ;;
        dnf|yum)
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | asroot bash - || return 1
            asroot "$PM" install -y nodejs || return 1
            ;;
        pacman) _pm_install nodejs npm ;;
        *)
            local nvmver
            nvmver="$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"
            [[ -n "$nvmver" ]] || return 1
            run_user "$TARGET_USER" bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v${nvmver}/install.sh | bash" || return 1
            run_user "$TARGET_USER" bash -c 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm install --lts >/dev/null'
            ;;
    esac
}

_install_dotnet() { # always latest LTS via the official script (no pinned versions)
    register_tmp "/tmp/dotnet-install.sh"
    run_user "$TARGET_USER" bash -c \
        'curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && bash /tmp/dotnet-install.sh --channel LTS && rm -f /tmp/dotnet-install.sh'
}

step_toolchains() {
    if confirm "Install bun (JavaScript runtime)?" n; then
        if user_cmd_exists bun; then ok "bun already installed"
        elif run_user "$TARGET_USER" bash -c 'curl -fsSL https://bun.sh/install | bash'; then ok "bun installed"
        else warn "bun install failed"; fi
    fi

    if confirm "Install Node.js + npm (Nodesource LTS)?" n; then
        if user_cmd_exists node; then ok "node already installed"
        elif spinner "installing nodejs + npm" _install_node; then ok "node installed"
        else warn "node install failed"; fi
    fi

    if confirm "Install Rust (rustup)?" n; then
        if user_cmd_exists cargo; then ok "rust already installed"
        elif run_user "$TARGET_USER" bash -c 'curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'; then ok "rust installed"
        else warn "rustup install failed"; fi
    fi

    if confirm "Install .NET SDK (latest LTS)?" n; then
        if user_cmd_exists dotnet; then ok "dotnet already installed"
        elif spinner "installing dotnet sdk" _install_dotnet; then ok "dotnet sdk installed"
        else warn "dotnet install failed"; fi
    fi

    if confirm "Install meson (build system)?" n; then
        if command -v meson >/dev/null 2>&1; then ok "meson already installed"
        else spinner "installing meson" _pm_install meson || warn "meson install failed"; fi
    fi

    if confirm "Install ninja (build tool)?" n; then
        if command -v ninja >/dev/null 2>&1; then ok "ninja already installed"
        else
            local ninja_pkg="ninja"
            [[ "$PM" == apt || "$PM" == dnf || "$PM" == yum ]] && ninja_pkg="ninja-build"
            spinner "installing ninja" _pm_install "$ninja_pkg" || warn "ninja install failed"
        fi
    fi

    if confirm "Install cmake?" n; then
        if command -v cmake >/dev/null 2>&1; then
            ok "cmake already installed"
        else
            spinner "installing cmake" _pm_install cmake || warn "cmake install failed"
        fi
    fi

    if confirm "Install uv (Python package manager)?" y; then
        if user_cmd_exists uv; then ok "uv already installed"
        elif run_user "$TARGET_USER" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'; then ok "uv installed"
        else warn "uv install failed"; fi
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Step: vscode
# ----------------------------------------------------------------------------
_install_vscode() {
    case "$PM" in
        apt)
            local keyring=/etc/apt/keyrings/packages.microsoft.gpg
            asroot install -m 0755 -d /etc/apt/keyrings || return 1
            curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
                | asroot gpg --dearmor --yes -o "$keyring" || return 1
            asroot chmod a+r "$keyring" 2>/dev/null || true
            printf 'deb [arch=amd64,arm64,armhf signed-by=%s] https://packages.microsoft.com/repos/code stable main\n' \
                "$keyring" | asroot tee /etc/apt/sources.list.d/vscode.list >/dev/null || return 1
            apt_get update -qq || true
            apt_get install -y code || return 1
            ;;
        dnf|yum)
            asroot rpm --import https://packages.microsoft.com/keys/microsoft.asc || return 1
            printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
                | asroot tee /etc/yum.repos.d/vscode.repo >/dev/null || return 1
            _pm_install code || return 1
            ;;
        *)
            if command -v snap >/dev/null 2>&1 || _pm_install snapd 2>/dev/null; then
                asroot systemctl enable --now snapd.socket >/dev/null 2>&1 || true
                local i
                for i in $(seq 1 30); do snap version >/dev/null 2>&1 && break; sleep 1; done
                asroot snap install code --classic || return 1
                register_managed "code" "snap"
            else
                warn "no packaged VS Code for '$PM'; install manually from https://code.visualstudio.com"
                return 1
            fi
            ;;
    esac
    command -v code >/dev/null 2>&1
}

# Only add extensions for toolchains actually present, so the set matches
# what this machine was set up with rather than installing everything.
_install_vscode_extensions() {
    local exts=(
        llvm-vs-code-extensions.vscode-clangd    # clangd C/C++ (requested)
        ms-vscode-remote.remote-containers        # Dev Containers (requested)
        ms-azuretools.vscode-docker               # docker + compose already installed
        github.vscode-pull-request-github         # gh cli already installed/authed
        editorconfig.editorconfig
    )
    # cpptools is deliberately NOT included: it fights clangd over C/C++
    # IntelliSense, and clangd was explicitly requested as the C/C++ backend.
    command -v cmake >/dev/null 2>&1 && exts+=(ms-vscode.cmake-tools)
    user_cmd_exists cargo  && exts+=(rust-lang.rust-analyzer)
    user_cmd_exists uv     && exts+=(ms-python.python charliermarsh.ruff)
    user_cmd_exists dotnet && exts+=(ms-dotnettools.csharp)

    info "installing ${#exts[@]} extension(s) for $TARGET_USER..."
    local e ok_n=0
    for e in "${exts[@]}"; do
        if run_user "$TARGET_USER" code --install-extension "$e" --force >/dev/null 2>&1; then
            ok "extension: $e"
            ok_n=$((ok_n + 1))
        else
            warn "extension install failed: $e"
        fi
    done
    [[ $ok_n -gt 0 ]]
}

step_vscode() {
    if command -v code >/dev/null 2>&1; then
        ok "VS Code already installed: $(code --version 2>/dev/null | head -1)"
    else
        if ! confirm "Install Visual Studio Code?" y; then return 0; fi
        if ! spinner "installing VS Code" _install_vscode; then
            err "VS Code install failed"
            return 1
        fi
        ok "VS Code installed: $(code --version 2>/dev/null | head -1)"
    fi

    command -v code >/dev/null 2>&1 || { warn "'code' CLI not on PATH; skipping extensions"; return 0; }

    if confirm "Install VS Code extensions (clangd, Dev Containers, Docker + matching toolchains)?" y; then
        _install_vscode_extensions || warn "some extensions failed to install; see messages above"
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Step: configs  (content mirrors the author's laptop, minus machine-specifics)
# ----------------------------------------------------------------------------
_gitconfig_content() {
    local name email ghbin GIT_NAME GIT_EMAIL GH_BIN
    read_line "git user.name [${TARGET_USER}]: "; name="${REPLY:-${TARGET_USER}}"
    read_line "git user.email [${TARGET_USER}@$(hostname)]: "; email="${REPLY:-${TARGET_USER}@$(hostname)}"
    ghbin="$(command -v gh 2>/dev/null || echo /usr/bin/gh)"
    GIT_NAME="$name"; GIT_EMAIL="$email"; GH_BIN="$ghbin"
    subst_template "$FILES_DIR/gitconfig" GIT_NAME GIT_EMAIL GH_BIN TARGET_HOME
}

_ghostty_config_content() {
    read_file "ghostty/config"
}

_claude_settings_content() {
    read_file "claude/settings.json"
}

_statusline_script_content() {
    read_file "claude/statusline-command.sh"
}

_cost_aggregate_script_content() {
    read_file "claude/cost_aggregate.py"
}

_install_statusline_script() { # _install_statusline_script HOME
    local home="$1" tmp
    tmp="$(new_tmp)"

    if ! read_file "claude/statusline-command.sh" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    asroot install -D -m 0755 "$tmp" "$home/.claude/statusline-command.sh"
    asroot chown "$TARGET_USER:" "$home/.claude/statusline-command.sh" 2>/dev/null || true

    tmp="$(new_tmp)"
    if ! read_file "claude/cost_aggregate.py" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    asroot install -D -m 0755 "$tmp" "$home/.claude/cost_aggregate.py"
    asroot chown "$TARGET_USER:" "$home/.claude/cost_aggregate.py" 2>/dev/null || true

    ok "installed statusline scripts"
}

_merge_claude_settings() { # _merge_claude_settings HOME
    local home="$1" existing="$home/.claude/settings.json"
    local defaults tmp
    tmp="$(new_tmp)"

    if ! read_file "claude/settings.json" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    if [[ -f "$existing" ]]; then
        if command -v jq >/dev/null 2>&1; then
            jq -s '.[0] * .[1]' "$tmp" "$existing" > "$tmp.merged"
            mv "$tmp.merged" "$tmp"
        else
            warn "jq not found; using default Claude settings (preserve manually if needed)"
        fi
    fi

    asroot install -D -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" -m 0644 "$tmp" "$existing"
    ok "wrote $existing"
}

_opencode_config_content() {
    read_file "opencode/opencode.jsonc"
}

_tmux_content() {
    read_file "tmux.conf"
}

run_git_config() { # run_git_config KEY VALUE   (as the target user)
    run_user "$TARGET_USER" git config --global "$1" "$2" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
#  SSH helpers
# ----------------------------------------------------------------------------
# Find an existing SSH private key for TARGET_USER, preferring ed25519.
# Prints the private key path to stdout and returns 0 if found.
_find_existing_ssh_key() {
    local ssh_dir="$TARGET_HOME/.ssh"
    local cand
    for cand in id_ed25519 id_ecdsa id_rsa id_ed25519_sk id_ecdsa_sk; do
        if run_user "$TARGET_USER" bash -c "test -f \"$ssh_dir/$cand\"" 2>/dev/null; then
            printf '%s' "$ssh_dir/$cand"
            return 0
        fi
    done
    # Fallback: any *.pub with a matching private key (covers custom names)
    local pubs
    pubs="$(run_user "$TARGET_USER" bash -c "ls -1 \"$ssh_dir\"/*.pub 2>/dev/null" || true)"
    local pub
    while IFS= read -r pub; do
        [[ -z "$pub" ]] && continue
        local priv="${pub%.pub}"
        if run_user "$TARGET_USER" bash -c "test -f \"$priv\"" 2>/dev/null; then
            printf '%s' "$priv"
            return 0
        fi
    done <<< "$pubs"
    return 1
}

# Report existing git + SSH signing configuration for TARGET_USER.
# Prints a human-readable summary and returns 0 if signing looks fully configured.
_report_git_signing_status() {
    local fmt sk gpgsign tag_sign allowed email name
    fmt="$(run_user "$TARGET_USER" git config --global --get gpg.format 2>/dev/null || echo "")"
    sk="$(run_user "$TARGET_USER" git config --global --get user.signingkey 2>/dev/null || echo "")"
    gpgsign="$(run_user "$TARGET_USER" git config --global --get commit.gpgsign 2>/dev/null || echo "")"
    tag_sign="$(run_user "$TARGET_USER" git config --global --get tag.gpgsign 2>/dev/null || echo "")"
    allowed="$(run_user "$TARGET_USER" git config --global --get gpg.ssh.allowedSignersFile 2>/dev/null || echo "")"
    email="$(run_user "$TARGET_USER" git config --global --get user.email 2>/dev/null || echo "")"
    name="$(run_user "$TARGET_USER" git config --global --get user.name 2>/dev/null || echo "")"

    local has_key=0 has_allowed=0 has_pub=0
    local key_path="" pub_path=""
    if [[ -n "$sk" ]]; then
        # signingkey may be a path to .pub or the key material itself
        if [[ "$sk" == ssh-* ]]; then
            has_pub=1
            info "  git user.signingkey is inline key material (ssh-...)"
        elif run_user "$TARGET_USER" bash -c "test -f \"$sk\"" 2>/dev/null; then
            has_pub=1
            pub_path="$sk"
            key_path="${sk%.pub}"
            if run_user "$TARGET_USER" bash -c "test -f \"$key_path\"" 2>/dev/null; then has_key=1; fi
            info "  git user.signingkey: $sk $(run_user "$TARGET_USER" ssh-keygen -l -f "$sk" 2>/dev/null | sed 's/^/  /' || echo "")"
        else
            warn "  git user.signingkey: $sk (file not found)"
        fi
    else
        info "  git user.signingkey: (not set)"
    fi

    if [[ -n "$allowed" ]]; then
        if run_user "$TARGET_USER" bash -c "test -f \"$allowed\"" 2>/dev/null; then
            has_allowed=1
            info "  git gpg.ssh.allowedSignersFile: $allowed ($(run_user "$TARGET_USER" bash -c "wc -l < \"$allowed\" 2>/dev/null" || echo "?") line(s))"
            run_user "$TARGET_USER" bash -c "sed 's/^/    /' \"$allowed\" 2>/dev/null | head -n 5" || true
        else
            warn "  git gpg.ssh.allowedSignersFile: $allowed (file not found)"
        fi
    else
        info "  git gpg.ssh.allowedSignersFile: (not set)"
    fi

    info "  git gpg.format: ${fmt:-(not set)}"
    info "  git commit.gpgsign: ${gpgsign:-(not set)}  tag.gpgsign: ${tag_sign:-(not set)}"
    info "  git user.name: ${name:-(not set)}  user.email: ${email:-(not set)}"

    # Check GitHub side if gh is authenticated
    if command -v gh >/dev/null 2>&1 && run_user "$TARGET_USER" bash -c 'gh auth status >/dev/null 2>&1'; then
        local pubkey_for_check=""
        if [[ -n "$pub_path" ]] && run_user "$TARGET_USER" bash -c "test -f \"$pub_path\"" 2>/dev/null; then
            pubkey_for_check="$(run_user "$TARGET_USER" bash -c "cut -d' ' -f2 < \"$pub_path\"" 2>/dev/null || echo "")"
        elif [[ -n "$sk" && "$sk" == ssh-* ]]; then
            pubkey_for_check="$(printf '%s' "$sk" | cut -d' ' -f2)"
        else
            # fallback to detected key
            local det="$( _find_existing_ssh_key 2>/dev/null || echo "")"
            if [[ -n "$det" ]]; then
                pubkey_for_check="$(run_user "$TARGET_USER" bash -c "cut -d' ' -f2 < \"${det}.pub\"" 2>/dev/null || echo "")"
            fi
        fi
        if [[ -n "$pubkey_for_check" ]]; then
            local has_auth=0 has_sign=0
            if run_user "$TARGET_USER" bash -c "gh api user/keys --paginate 2>/dev/null | grep -qF \"$pubkey_for_check\"" 2>/dev/null; then has_auth=1; fi
            if run_user "$TARGET_USER" bash -c "gh api user/ssh_signing_keys --paginate 2>/dev/null | grep -qF \"$pubkey_for_check\"" 2>/dev/null; then has_sign=1; fi
            if [[ $has_auth -eq 1 ]]; then ok "  GitHub authentication key: present (push/pull will work)"; else warn "  GitHub authentication key: NOT found (push will fail until uploaded)"; fi
            if [[ $has_sign -eq 1 ]]; then ok "  GitHub SSH signing key: present (commits will show Verified)"; else warn "  GitHub SSH signing key: NOT found (commits will show Unverified until uploaded)"; fi
        else
            info "  GitHub keys: (no local pubkey to check against)"
        fi
    else
        info "  GitHub keys: (gh not authenticated — run 'gh auth login' to check/upload)"
    fi

    # Return 0 only if core signing looks fully configured
    if [[ "$fmt" == "ssh" && "$gpgsign" == "true" && $has_pub -eq 1 && $has_allowed -eq 1 ]]; then
        return 0
    fi
    return 1
}

# Report existing local SSH key status (for passwordless login)
_report_ssh_key_status() {
    local ssh_dir="$TARGET_HOME/.ssh"
    local existing
    if existing="$(_find_existing_ssh_key 2>/dev/null)"; then
        local pub="${existing}.pub"
        ok "  SSH key present: $existing"
        if run_user "$TARGET_USER" bash -c "test -f \"$pub\"" 2>/dev/null; then
            run_user "$TARGET_USER" ssh-keygen -l -f "$pub" 2>/dev/null | sed 's/^/    /' || true
            run_user "$TARGET_USER" bash -c "cat \"$pub\" 2>/dev/null | sed 's/^/    /' | cut -c1-80" || true
        else
            warn "  public key missing at $pub (private exists but .pub not found)"
        fi
        # Show ssh config snippet if present
        if [[ -f "$ssh_dir/config" ]]; then
            info "  ~/.ssh/config exists ($(wc -l < "$ssh_dir/config" 2>/dev/null | tr -d ' ') lines)"
            run_user "$TARGET_USER" bash -c "grep -E '^Host |IdentityFile|AddKeysToAgent' \"$ssh_dir/config\" 2>/dev/null | sed 's/^/    /'" || true
        else
            info "  ~/.ssh/config: (not present)"
        fi
        return 0
    else
        info "  SSH key: (none found in $ssh_dir — will generate ed25519 if requested)"
        return 1
    fi
}

_setup_ssh_signing() {
    local ssh_dir="$TARGET_HOME/.ssh"
    local email key pub
    email="$(run_user "$TARGET_USER" git config --global user.email 2>/dev/null)"
    email="${email:-${TARGET_USER}@$(hostname)}"

    printf '\n%sCurrent signing config for %s:%s\n' "$C_BOLD" "$TARGET_USER" "$C_RESET"
    if _report_git_signing_status; then
        ok "git commit signing already fully configured"
    else
        info "git commit signing not yet fully configured"
    fi
    _report_ssh_key_status || true
    printf '\n'

    asroot install -d -m 700 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$ssh_dir"
    # Ensure openssh-client (provides ssh-keygen, ssh-copy-id) is available
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        info "installing openssh-client (ssh-keygen)..."
        _pm_install openssh-client 2>/dev/null || warn "could not install openssh-client"
    fi

    # Detect existing key or generate a fresh one
    local existing
    if existing="$(_find_existing_ssh_key)"; then
        key="$existing"
        pub="${key}.pub"
        # If pub is missing (e.g. only private was kept), derive it
        if ! run_user "$TARGET_USER" bash -c "test -f \"$pub\"" 2>/dev/null; then
            info "public key missing for $key; deriving from private key..."
            if run_user "$TARGET_USER" bash -c "ssh-keygen -y -f \"$key\" > \"$pub\" 2>/dev/null"; then
                asroot chmod 644 "$pub" 2>/dev/null || true
                asroot chown "$TARGET_USER:" "$pub" 2>/dev/null || true
                ok "derived $pub from $key"
            else
                warn "could not derive public key for $key"
            fi
        fi
        # Fix permissions (common cause of SSH ignored keys)
        asroot chmod 700 "$ssh_dir" 2>/dev/null || true
        asroot chmod 600 "$key" 2>/dev/null || true
        asroot chmod 644 "$pub" 2>/dev/null || true
        asroot chown -R "$TARGET_USER:" "$ssh_dir" 2>/dev/null || true
        info "reusing existing ssh key at $key"
        # Show fingerprint for confirmation
        run_user "$TARGET_USER" ssh-keygen -l -f "$pub" 2>/dev/null | sed 's/^/  /' || true
    else
        key="$ssh_dir/id_ed25519"
        pub="$key.pub"
        info "no existing SSH key found; generating a fresh ed25519 key at $key"
        if [[ $EUID -eq 0 ]]; then
            run_user "$TARGET_USER" bash -c "ssh-keygen -t ed25519 -N '' -C '$email' -f '$key'" || { warn "ssh-keygen failed"; return 1; }
        else
            ssh-keygen -t ed25519 -N "" -C "$email" -f "$key" || { warn "ssh-keygen failed"; return 1; }
        fi
        asroot chmod 600 "$key" 2>/dev/null || true
        asroot chmod 644 "$pub" 2>/dev/null || true
        ok "generated $key"
        SSH_KEY_CREATED=1
        SSH_KEY_PATH="$key"
    fi

    # Double-check pub exists and is readable as TARGET_USER
    if ! run_user "$TARGET_USER" bash -c "test -f \"$pub\"" 2>/dev/null; then
        err "public key not found at $pub after setup"
        return 1
    fi
    local pubkey
    pubkey="$(run_user "$TARGET_USER" bash -c "cat \"$pub\"" 2>/dev/null)"
    if [[ -z "$pubkey" ]]; then
        err "public key at $pub is empty"
        return 1
    fi

    # SSH config: ensure github.com entry uses the correct IdentityFile and that
    # a global AddKeysToAgent is set (helps both GitHub and passwordless hosts).
    local cfg="$ssh_dir/config"
    local need_github=1 need_global=1
    if [[ -f "$cfg" ]]; then
        run_user "$TARGET_USER" bash -c "grep -q 'Host github.com' \"$cfg\" 2>/dev/null" && need_github=0
        run_user "$TARGET_USER" bash -c "grep -q 'AddKeysToAgent' \"$cfg\" 2>/dev/null" && need_global=0
    fi
    if [[ $need_global -eq 1 ]]; then
        {
            printf '\nHost *\n'
            printf '    AddKeysToAgent yes\n'
        } | asroot tee -a "$cfg" >/dev/null
        asroot chmod 600 "$cfg" 2>/dev/null || true
        asroot chown "$TARGET_USER:" "$cfg" 2>/dev/null || true
        ok "added Host * AddKeysToAgent to $cfg"
    fi
    if [[ $need_github -eq 1 ]]; then
        {
            printf '\nHost github.com\n'
            printf '    HostName github.com\n'
            printf '    User git\n'
            printf '    IdentityFile %s\n' "$key"
            printf '    IdentitiesOnly yes\n'
        } | asroot tee -a "$cfg" >/dev/null
        asroot chmod 600 "$cfg" 2>/dev/null || true
        asroot chown "$TARGET_USER:" "$cfg" 2>/dev/null || true
        ok "github.com entry added to $cfg (IdentityFile $key)"
    else
        # Existing entry may point at wrong key (e.g. old ed25519 path); update it
        if run_user "$TARGET_USER" bash -c "grep -A5 'Host github.com' \"$cfg\" 2>/dev/null | grep -q \"IdentityFile\"" 2>/dev/null; then
            local current_id
            current_id="$(run_user "$TARGET_USER" bash -c "awk '/Host github.com/{f=1;next} f && /IdentityFile/{print \$2; exit}' \"$cfg\"" 2>/dev/null)"
            if [[ -n "$current_id" && "$current_id" != "$key" ]]; then
                warn "github.com IdentityFile in $cfg is $current_id, updating to $key"
                # Replace only the IdentityFile line under Host github.com
                run_user "$TARGET_USER" bash -c "
                    awk -v newkey=\"$key\" '
                        /Host github.com/{in_github=1}
                        in_github && /IdentityFile/{sub(/IdentityFile.*/, \"    IdentityFile \" newkey); in_github=0}
                        {print}
                        /^Host / && !/Host github.com/{in_github=0}
                    ' \"$cfg\" > \"$cfg.tmp\" && mv \"$cfg.tmp\" \"$cfg\"
                " 2>/dev/null || true
                asroot chown "$TARGET_USER:" "$cfg" 2>/dev/null || true
                ok "updated github.com IdentityFile to $key"
            fi
        fi
    fi

    # allowed_signers: format is "PRINCIPAL SPACED_PUBKEY" (e.g. "user@host ssh-ed25519 AAAAC3... user@host")
    # Previous bug used "email pubkey email" (duplicate trailing principal). Fix by using single principal.
    local tmp
    tmp="$(new_tmp)"
    printf '%s %s\n' "$email" "$pubkey" > "$tmp"
    # If allowed_signers already contains this exact pubkey, don't duplicate
    local key_material
    key_material="$(printf '%s' "$pubkey" | cut -d' ' -f2)"
    if [[ -f "$ssh_dir/allowed_signers" ]] && grep -qF "$key_material" "$ssh_dir/allowed_signers" 2>/dev/null; then
        info "allowed_signers already contains this key; leaving it in place"
        rm -f "$tmp"
    else
        # If allowed_signers exists and has other keys, preserve them and append this one.
        if [[ -f "$ssh_dir/allowed_signers" ]] && ! grep -qF "$key_material" "$ssh_dir/allowed_signers" 2>/dev/null; then
            local merged
            merged="$(new_tmp)"
            cat "$ssh_dir/allowed_signers" > "$merged" 2>/dev/null || true
            cat "$tmp" >> "$merged"
            mv "$merged" "$tmp"
        fi
        asroot install -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" -m 600 "$tmp" "$ssh_dir/allowed_signers"
        rm -f "$tmp"
        ok "wrote $ssh_dir/allowed_signers (principal: $email)"
    fi

    run_git_config gpg.format ssh
    run_git_config user.signingkey "$pub"
    run_git_config commit.gpgsign true
    run_git_config tag.gpgsign true
    run_git_config gpg.ssh.allowedSignersFile "$ssh_dir/allowed_signers"
    ok "git commit signing (ssh) configured with $pub"

    # --- GitHub upload: distinguish authentication vs signing keys ---
    # Authentication keys (push/pull) live at /user/keys, signing keys at /user/ssh_signing_keys.
    # The old script only uploaded an authentication key, so commits showed "Unverified"
    # even though push worked. Now we upload both when gh is authenticated.
    if command -v gh >/dev/null 2>&1 && run_user "$TARGET_USER" bash -c 'gh auth status >/dev/null 2>&1'; then
        local title="bootstrap-$(hostname)-$(date +%Y%m%d)"
        local already_auth=0 already_sign=0

        # Check auth key exists (match by key material to avoid duplicate titles)
        if run_user "$TARGET_USER" bash -c "gh api user/keys --paginate 2>/dev/null | grep -qF \"$key_material\"" 2>/dev/null; then
            already_auth=1
            info "GitHub authentication key already present (skipping upload)"
        else
            if run_user "$TARGET_USER" bash -c "gh ssh-key add \"$pub\" --title \"$title-auth\" 2>/dev/null"; then
                ok "SSH authentication key uploaded to GitHub (for git push/pull)"
            else
                # gh ssh-key add may fail if title exists; try with unique title
                if run_user "$TARGET_USER" bash -c "gh ssh-key add \"$pub\" --title \"$title-auth-\$(date +%s)\" 2>/dev/null"; then
                    ok "SSH authentication key uploaded to GitHub"
                else
                    warn "couldn't upload authentication key to GitHub (may already exist or need 'gh auth refresh -h github.com -s write:public_key')"
                fi
            fi
        fi

        # Check signing key exists
        if run_user "$TARGET_USER" bash -c "gh api user/ssh_signing_keys --paginate 2>/dev/null | grep -qF \"$key_material\"" 2>/dev/null; then
            already_sign=1
            info "GitHub SSH signing key already present (commits will show Verified)"
        else
            # need admin:public_key or write:public_key scope; try refresh then upload via api
            run_user "$TARGET_USER" bash -c "gh auth refresh -h github.com -s write:public_key 2>/dev/null" || true
            # Use gh api to create ssh_signing_key (gh ssh-key add does NOT create signing keys)
            if run_user "$TARGET_USER" bash -c "gh api --method POST user/ssh_signing_keys -f title=\"$title-sign\" -f key=\"\$(cat \"$pub\")\" >/dev/null 2>&1"; then
                ok "SSH signing key uploaded to GitHub (commits will show Verified)"
            else
                # Fallback: try with full pubkey line quoted
                if run_user "$TARGET_USER" bash -c "cat \"$pub\" | xargs -I{} gh api --method POST user/ssh_signing_keys -f title=\"$title-sign-\$(date +%s)\" -f key=\"{}\" >/dev/null 2>&1"; then
                    ok "SSH signing key uploaded to GitHub (fallback)"
                else
                    warn "couldn't upload SSH signing key to GitHub; add manually:"
                    warn "  gh api --method POST user/ssh_signing_keys -f title=\"$title-sign\" -f key=\"\$(cat $pub)\""
                    warn "  or add at https://github.com/settings/keys (SSH signing keys -> New SSH signing key)"
                fi
            fi
        fi

        if [[ $already_auth -eq 1 && $already_sign -eq 1 ]]; then
            ok "GitHub keys already up to date"
        fi
    else
        warn "gh not authenticated yet; add keys manually after 'gh auth login':"
        warn "  gh ssh-key add $pub --title \"\$(hostname)-auth\""
        warn "  gh api --method POST user/ssh_signing_keys -f title=\"\$(hostname)-sign\" -f key=\"\$(cat $pub)\""
    fi
    return 0
}

# One-time check that SSH commit signing actually works: create a scratch repo
# as the target user, make a signed commit, and verify the signature is Good.
_validate_git_signing() {
    local repo sig email pub signing_key allowed
    repo="$(new_tmpdir)"
    asroot chown -R "$TARGET_USER:" "$repo" 2>/dev/null || true

    # Use the actual configured email/signingkey/allowedSigners so the test
    # matches the real repo config (previous version used a fake test email
    # that never matched allowed_signers, so it always reported failure).
    email="$(run_user "$TARGET_USER" git config --global user.email 2>/dev/null)"
    email="${email:-${TARGET_USER}@$(hostname)}"
    signing_key="$(run_user "$TARGET_USER" git config --global user.signingkey 2>/dev/null)"
    allowed="$(run_user "$TARGET_USER" git config --global gpg.ssh.allowedSignersFile 2>/dev/null)"
    # Fall back to detected key if git config not yet set
    if [[ -z "$signing_key" ]]; then
        local _detected
        _detected="$(_find_existing_ssh_key 2>/dev/null || true)"
        if [[ -n "$_detected" ]]; then
            signing_key="${_detected}.pub"
        else
            signing_key="$TARGET_HOME/.ssh/id_ed25519.pub"
        fi
    fi
    if [[ -z "$allowed" ]]; then
        allowed="$TARGET_HOME/.ssh/allowed_signers"
    fi
    pub="$signing_key"

    if ! run_user "$TARGET_USER" bash -c "
        cd '$repo' && git init -q &&
        git config user.name \"\$(git config --global user.name 2>/dev/null || echo 'Bootstrap Test')\" &&
        git config user.email '$email' &&
        git config gpg.format ssh &&
        git config user.signingkey '$pub' &&
        git config gpg.ssh.allowedSignersFile '$allowed' &&
        git config commit.gpgsign true &&
        echo 'signing test' > test.txt && git add test.txt &&
        git commit -q -m 'bootstrap signing test'
    "; then
        err "test commit for signing verification failed"
        info "hint: check that $pub exists, $allowed contains '$email \$(cat $pub 2>/dev/null | cut -c1-60)...', and that git >= 2.34 is installed"
        return 1
    fi
    sig="$(run_user "$TARGET_USER" bash -c "cd '$repo' && git log -1 --format='%G? %GP %H' 2>/dev/null")"
    if [[ "$sig" == G* ]]; then
        ok "commit signing verified (Good signature): $sig"
        return 0
    fi
    err "commit signature not verified ($sig) - expected 'G ...' (Good)"
    info "allowed_signers ($allowed):"
    run_user "$TARGET_USER" bash -c "cat \"$allowed\" 2>/dev/null | sed 's/^/  /'" || true
    info "signing key ($pub):"
    run_user "$TARGET_USER" bash -c "cat \"$pub\" 2>/dev/null | sed 's/^/  /'" || true
    # Also show git verify output for deeper debugging
    run_user "$TARGET_USER" bash -c "cd '$repo' && git verify-commit HEAD 2>&1 | sed 's/^/  /'" || true
    return 1
}

# Offer to set up key-based (passwordless) SSH login to one or more remote
# hosts via ssh-copy-id (or manual fallback). This is INDEPENDENT from
# git/GitHub: it copies your PUBLIC key to the remote's ~/.ssh/authorized_keys
# so `ssh user@host` needs no password. GitHub uses two *different* objects
# for the same key: an "authentication key" for push/pull and a "signing key"
# for Verified commits — this function touches neither.
_setup_passwordless_ssh() {
    local ssh_dir="$TARGET_HOME/.ssh"
    local key pub

    printf '\n%sCurrent SSH key status for %s:%s\n' "$C_BOLD" "$TARGET_USER" "$C_RESET"
    _report_ssh_key_status || true
    printf '\n'

    key="$(_find_existing_ssh_key 2>/dev/null || echo "$ssh_dir/id_ed25519")"
    pub="${key}.pub"

    # If no key exists yet, offer to create one (reuses _setup_ssh_signing logic lightly)
    if ! run_user "$TARGET_USER" bash -c "test -f \"$key\" && test -f \"$pub\"" 2>/dev/null; then
        if ! confirm "No SSH key found at $key - generate one now for passwordless login?" y; then
            info "skipping passwordless SSH setup (no key)"
            return 0
        fi
        local email
        email="$(run_user "$TARGET_USER" git config --global user.email 2>/dev/null)"
        email="${email:-${TARGET_USER}@$(hostname)}"
        asroot install -d -m 700 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$ssh_dir"
        if [[ $EUID -eq 0 ]]; then
            run_user "$TARGET_USER" bash -c "ssh-keygen -t ed25519 -N '' -C '$email' -f '$key'" || { warn "ssh-keygen failed"; return 1; }
        else
            ssh-keygen -t ed25519 -N "" -C "$email" -f "$key" || { warn "ssh-keygen failed"; return 1; }
        fi
        asroot chmod 600 "$key" 2>/dev/null || true
        asroot chmod 644 "$pub" 2>/dev/null || true
        ok "generated $key"
        SSH_KEY_CREATED=1
        SSH_KEY_PATH="$key"
    fi

    if ! confirm "Set up passwordless SSH login to a remote host (copy your public key so 'ssh user@host' needs no password)?" n; then
        return 0
    fi

    # Ensure ssh-copy-id / ssh are available
    if ! command -v ssh >/dev/null 2>&1 && ! run_user "$TARGET_USER" bash -c "command -v ssh >/dev/null 2>&1"; then
        info "installing openssh-client..."
        _pm_install openssh-client 2>/dev/null || warn "could not install openssh-client"
    fi

    info "using public key: $pub"
    run_user "$TARGET_USER" bash -c "cat \"$pub\" 2>/dev/null | sed 's/^/  /'" || true

    while true; do
        read_line "Remote for passwordless SSH (e.g. user@host or host, leave empty to finish): "
        local dest="${REPLY:-}"
        dest="${dest#ssh }"
        [[ -z "$dest" ]] && break

        info "copying $pub to $dest ..."

        local copy_ok=0
        # Prefer ssh-copy-id when available (handles authorized_keys creation + perms)
        if run_user "$TARGET_USER" bash -c "command -v ssh-copy-id >/dev/null 2>&1"; then
            if run_user "$TARGET_USER" bash -c "ssh-copy-id -i \"$pub\" \"$dest\" 2>&1 | sed 's/^/  /'"; then
                copy_ok=1
            else
                warn "ssh-copy-id failed for $dest"
            fi
        else
            warn "ssh-copy-id not found, using manual 'cat >> authorized_keys' fallback"
            if run_user "$TARGET_USER" bash -c "cat \"$pub\" | ssh -o StrictHostKeyChecking=accept-new \"$dest\" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo ok' 2>&1 | grep -q ok"; then
                copy_ok=1
            else
                warn "manual copy failed for $dest"
            fi
        fi

        if [[ $copy_ok -eq 1 ]]; then
            ok "key copied to $dest"
            info "testing passwordless login to $dest (BatchMode)..."
            if run_user "$TARGET_USER" bash -c "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \"$dest\" 'echo ok' 2>&1 | grep -q ok"; then
                ok "passwordless SSH to $dest verified (no password needed)"
            else
                warn "still requires password or host unreachable"
                info "  test manually: ssh -o BatchMode=yes $dest 'echo ok'"
                info "  retry: ssh-copy-id -i $pub $dest"
            fi
        else
            warn "copy failed; you can retry manually: ssh-copy-id -i $pub $dest"
        fi

        if ! confirm "Set up another host?" n; then
            break
        fi
    done

    info "tip: if you generated a key with a passphrase you will still be prompted;"
    info "     run 'ssh-add $key' or ensure Host * AddKeysToAgent yes is in $ssh_dir/config (already added above)"
    return 0
}

step_configs() {
    ensure_user_dirs
    if ! confirm "Install dotfiles (git, ghostty, claude code, opencode, tmux)?" y; then return 0; fi
    local home="$TARGET_HOME"

    # Show existing git identity/signing config before asking to overwrite
    printf '\n%sExisting git config for %s:%s\n' "$C_BOLD" "$TARGET_USER" "$C_RESET"
    _report_git_signing_status || true
    if [[ -f "$home/.gitconfig" ]]; then
        info "  ~/.gitconfig file: exists at $home/.gitconfig"
        printf '%s\n' "  ${C_DIM}--- $home/.gitconfig ---${C_RESET}"
        run_user "$TARGET_USER" bash -c "cat \"$home/.gitconfig\" 2>/dev/null | sed 's/^/    /'" 2>/dev/null \
            || cat "$home/.gitconfig" 2>/dev/null | sed 's/^/    /' || true
        printf '%s\n' "  ${C_DIM}--- end ---${C_RESET}"
    else
        info "  ~/.gitconfig file: (not present)"
    fi
    printf '\n'

    local gitconfig_prompt="Set up ~/.gitconfig (asks for your name/email)?"
    local gitconfig_default="y"
    if [[ -f "$home/.gitconfig" ]]; then
        gitconfig_prompt="~/.gitconfig already exists — overwrite with new name/email?"
        gitconfig_default="n"
    fi
    if confirm "$gitconfig_prompt" "$gitconfig_default"; then
        _write_file "$home/.gitconfig" _gitconfig_content
    else
        if [[ -f "$home/.gitconfig" ]]; then
            ok "kept existing ~/.gitconfig"
        else
            info "skipped ~/.gitconfig"
        fi
    fi

    if command -v ghostty >/dev/null 2>&1 && confirm "Write ghostty config?" y; then
        _write_file "$home/.config/ghostty/config" _ghostty_config_content
    fi

    if confirm "Write Claude Code config (~/.claude/settings.json)?" y; then
        _install_statusline_script "$home"
        _merge_claude_settings "$home"
    fi

    if confirm "Write opencode config (~/.config/opencode/opencode.jsonc)?" y; then
        _write_file "$home/.config/opencode/opencode.jsonc" _opencode_config_content
    fi

    if confirm "Write tmux config (~/.tmux.conf)?" y; then
        _write_file "$home/.tmux.conf" _tmux_content
    fi

    # Report current signing state before prompting — so re-running the script
    # clearly shows if signing is already set up or not.
    local signing_already=1
    if _report_git_signing_status >/dev/null 2>&1; then
        signing_already=0
    fi
    # Re-report verbosely for the user before the prompt
    printf '\n%sSSH commit signing status:%s\n' "$C_BOLD" "$C_RESET"
    _report_git_signing_status || true
    _report_ssh_key_status || true
    printf '\n'

    local signing_prompt="Set up SSH key-based commit signing for git & GitHub?"
    local signing_default="y"
    if [[ $signing_already -eq 0 ]]; then
        signing_prompt="SSH commit signing already configured — reconfigure / re-upload to GitHub?"
        signing_default="n"
    fi
    if confirm "$signing_prompt" "$signing_default"; then
        if _setup_ssh_signing; then
            _validate_git_signing || warn "commit signing validation failed; see messages above"
        fi
    else
        if [[ $signing_already -eq 0 ]]; then
            ok "kept existing commit signing config"
        else
            info "skipped commit signing setup"
        fi
    fi

    # Passwordless SSH is fully separate from git/GitHub. It reuses the same
    # local key pair (so you only manage one) but only touches the remote's
    # authorized_keys — it does NOT upload to GitHub. GitHub auth vs signing
    # are also distinct (see _setup_ssh_signing comments).
    # _setup_passwordless_ssh reports its own existing-key status and then
    # prompts, so no extra pre-report is needed here.
    _setup_passwordless_ssh || warn "passwordless SSH setup incomplete"

    return 0
}

# ----------------------------------------------------------------------------
#  Step: extras (ffmpeg, microsoft edge)
# ----------------------------------------------------------------------------
_ffmpeg_apt_repo() {
    local keyring=/etc/apt/keyrings/ffmpeg.gpg
    asroot install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4A7F0DDDBEB5A8B4" \
        | asroot gpg --dearmor --yes -o "$keyring" || return 1
    printf 'deb [signed-by=%s] https://ppa.launchpadcontent.net/ffmpeg/ffmpeg/ubuntu %s main\n' \
        "$keyring" "${CODENAME:-$VERSION_ID}" | asroot tee /etc/apt/sources.list.d/ffmpeg-ffmpeg.list >/dev/null || return 1
    apt_get update -qq || true
    apt_get install -y ffmpeg
}

install_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1; then
        ok "ffmpeg already installed: $(ffmpeg -version 2>/dev/null | head -1)"
        return 0
    fi
    if ! confirm "Install ffmpeg (distro package)?" y; then return 0; fi

    case "$PM" in
        apt)
            _pm_install ffmpeg || { warn "distro ffmpeg install failed"; return 1; }
            if confirm "Use the ffmpeg.org PPA for a more recent ffmpeg build?" y; then
                if _ffmpeg_apt_repo; then
                    ok "ffmpeg upgraded from the ffmpeg.org PPA: $(ffmpeg -version 2>/dev/null | head -1)"
                else
                    warn "ffmpeg PPA failed; keeping the distro package"
                fi
            fi
            ;;
        dnf|yum|pacman|zypper|apk)
            _pm_install ffmpeg || { warn "ffmpeg install failed"; return 1; }
            ;;
        *)
            warn "no packaged ffmpeg for '$PM'; installing static build"
            local ver tmp
            ver="$(curl -fsSL https://api.github.com/repos/eugeneware/ffmpeg-static/releases/latest \
                | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"
            if [[ -n "$ver" ]]; then
                tmp="$(new_tmp)"
                printf '%s\n' "downloading ffmpeg-static v${ver}..."
                curl -fSL --retry 2 -# -o "$tmp" "https://github.com/eugeneware/ffmpeg-static/releases/download/v${ver}/ffmpeg-${ARCH}" || return 1
                chmod +x "$tmp"
                asroot mv "$tmp" /usr/local/bin/ffmpeg
                register_managed "ffmpeg" "tarball" "/usr/local/bin/ffmpeg"
                ok "ffmpeg static build installed: $(ffmpeg -version 2>/dev/null | head -1)"
            else
                warn "couldn't determine latest ffmpeg-static release"
                return 1
            fi
            ;;
    esac
    command -v ffmpeg >/dev/null 2>&1
}

install_edge() {
    if command -v microsoft-edge-stable >/dev/null 2>&1; then
        ok "edge already installed: $(microsoft-edge-stable --version 2>/dev/null || echo '?')"
        return 0
    fi
    if ! confirm "Install Microsoft Edge?" y; then return 0; fi

    case "$PM" in
        apt)
            if [[ "$ARCH" != amd64 ]]; then
                warn "edge only publishes amd64 packages; skipping"
                return 0
            fi
            local keyring=/etc/apt/keyrings/microsoft-edge.gpg
            asroot install -m 0755 -d /etc/apt/keyrings || return 1
            curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | asroot gpg --dearmor --yes -o "$keyring" || return 1
            printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/edge\nSuites: stable\nComponents: main\nSigned-By: %s\nArchitectures: amd64\n' \
                "$keyring" | asroot tee /etc/apt/sources.list.d/microsoft-edge.sources >/dev/null || return 1
            apt_get update -qq || true
            apt_get install -y microsoft-edge-stable || return 1
            ;;
        dnf|yum)
            curl -fsSL https://packages.microsoft.com/yumrepos/edge/config.repo | asroot tee /etc/yum.repos.d/microsoft-edge.repo >/dev/null || return 1
            _pm_install microsoft-edge-stable || return 1
            ;;
        *)
            warn "no packaged edge for '$PM'; download the .deb/.rpm manually from https://www.microsoft.com/edge"
            return 0
            ;;
    esac
    command -v microsoft-edge-stable >/dev/null 2>&1
}

step_extras() {
    install_ffmpeg
    install_edge
    return 0
}

# ----------------------------------------------------------------------------
#  Step: scpt (tmux SSH helper + file transfer)
# ----------------------------------------------------------------------------
_install_scpt() {
    local src="" found="" tmpdir
    local candidates=(
        "$SCRIPT_DIR/tools/scpt/scpt.sh"
        "$SCRIPT_DIR/../tools/scpt/scpt.sh"
        "$FILES_DIR/../tools/scpt/scpt.sh"
        "./tools/scpt/scpt.sh"
        "$HOME/bootstrap/tools/scpt/scpt.sh"
    )
    for src in "${candidates[@]}"; do
        if [[ -f "$src" ]]; then found="$src"; break; fi
    done
    # Remote/curl mode fallback: clone from GitHub
    if [[ -z "$found" ]]; then
        info "scpt source not found locally, cloning from GitHub..."
        tmpdir="$(new_tmpdir)"
        if command -v git >/dev/null 2>&1 && git clone --depth 1 https://github.com/davidnoronha1/scpt.git "$tmpdir/scpt" 2>/dev/null; then
            found="$tmpdir/scpt/scpt.sh"
        else
            # last resort: fetch single file via curl
            if command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/davidnoronha1/scpt/main/scpt.sh -o "$tmpdir/scpt.sh" 2>/dev/null; then
                found="$tmpdir/scpt.sh"
            else
                err "could not obtain scpt.sh (no local file, git/curl fallback failed)"
                return 1
            fi
        fi
    else
        # source found locally — if we haven't set tmpdir, set it for sft fallback logic
        tmpdir="${tmpdir:-$(new_tmpdir)}"
        # if local source is from a git checkout, tmpdir/scpt may not exist; that's fine
        # we will resolve sft relative to found's directory below
        :
    fi
    ensure_user_dirs
    local g
    g="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    local dest="$TARGET_HOME/.local/bin/scpt"
    if asroot install -D -o "$TARGET_USER" -g "$g" -m 0755 "$found" "$dest"; then
        ok "scpt installed to $dest"
        asroot ln -sf "$dest" /usr/local/bin/scpt 2>/dev/null || true
        # keep sht/sht.sh aliases for backward compat (old name)
        asroot ln -sf "$dest" /usr/local/bin/sht 2>/dev/null || true
        asroot ln -sf "$dest" "$TARGET_HOME/.local/bin/sht" 2>/dev/null || true
        run_user "$TARGET_USER" bash -c "ln -sf '$dest' '$TARGET_HOME/.local/bin/sht'" 2>/dev/null || true
        register_managed "scpt" "tarball" "$dest"
    else
        err "failed to install scpt to $dest"
        return 1
    fi

    # companion: sft (file transfer, lives alongside scpt in tools/scpt/sft/sft.py)
    local sft_src="" sft_found="" sft_dest="$TARGET_HOME/.local/bin/sft"
    local sft_candidates=(
        "$(dirname "$found")/sft/sft.py"
        "$SCRIPT_DIR/tools/scpt/sft/sft.py"
        "$SCRIPT_DIR/../tools/scpt/sft/sft.py"
        "$FILES_DIR/../tools/scpt/sft/sft.py"
        "./tools/scpt/sft/sft.py"
        "$HOME/bootstrap/tools/scpt/sft/sft.py"
        "${tmpdir}/scpt/sft/sft.py"
    )
    for sft_src in "${sft_candidates[@]}"; do
        if [[ -f "$sft_src" ]]; then sft_found="$sft_src"; break; fi
    done
    if [[ -z "$sft_found" ]]; then
        # try fetching sft.py via curl if scpt was fetched standalone
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL https://raw.githubusercontent.com/davidnoronha1/scpt/main/sft/sft.py -o "$tmpdir/sft.py" 2>/dev/null; then
                sft_found="$tmpdir/sft.py"
            fi
        fi
    fi
    if [[ -n "$sft_found" ]]; then
        if asroot install -D -o "$TARGET_USER" -g "$g" -m 0755 "$sft_found" "$sft_dest"; then
            ok "sft installed to $sft_dest (companion to scpt)"
            asroot ln -sf "$sft_dest" /usr/local/bin/sft 2>/dev/null || true
            register_managed "sft" "tarball" "$sft_dest"
        else
            warn "failed to install sft to $sft_dest"
        fi
    else
        warn "sft source not found; scpt file transfer (prefix+T) will be limited"
        warn "  sft lives at tools/scpt/sft/sft.py in the scpt repo"
    fi
    return 0
}

step_scpt() {
    ensure_user_dirs
    # tmux is required for scpt; install if missing
    if ! command -v tmux >/dev/null 2>&1; then
        info "tmux not found (required for scpt), installing..."
        if ! _pm_install tmux; then
            warn "tmux install failed; scpt will be installed but needs tmux to run"
        fi
    else
        ok "tmux already installed: $(tmux -V 2>/dev/null | head -1)"
    fi
    if ! command -v ssh >/dev/null 2>&1; then
        info "openssh-client not found (required for scpt), installing..."
        _pm_install openssh-client 2>/dev/null || _pm_install openssh 2>/dev/null || warn "openssh-client install failed"
    fi
    # optional: nmap for scan feature
    if ! command -v nmap >/dev/null 2>&1; then
        info "nmap not found (optional for 'scpt --scan'), skipping auto-install"
    fi
    if ! confirm "Install scpt (tmux SSH helper + file transfer)?" y; then return 0; fi
    if user_cmd_exists scpt || [[ -x "$TARGET_HOME/.local/bin/scpt" ]]; then
        ok "scpt already installed at $TARGET_HOME/.local/bin/scpt"
        if confirm "Reinstall/overwrite scpt?" n; then
            spinner "installing scpt" _install_scpt || warn "scpt install failed"
        fi
    else
        if spinner "installing scpt" _install_scpt; then
            ok "scpt installed: $(run_user "$TARGET_USER" scpt --help 2>/dev/null | head -1 || echo 'scpt --help for usage')"
        else
            warn "scpt install failed"
            return 1
        fi
    fi
    # Offer to bind prefix+c if inside tmux, but don't force
    if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" ]]; then
        if confirm "Bind prefix+c to scpt menu in this tmux server now?" y; then
            if run_user "$TARGET_USER" bash -c "'$TARGET_HOME/.local/bin/scpt' --bind" 2>/dev/null || bash "$TARGET_HOME/.local/bin/scpt" --bind 2>/dev/null; then
                ok "scpt binding installed (prefix+c)"
            else
                warn "scpt --bind failed; try 'scpt --bind' manually inside tmux"
            fi
        fi
    else
        info "run 'scpt --bind' inside tmux to bind prefix+c, or just run 'scpt' for the menu"
    fi
    return 0
}

# ----------------------------------------------------------------------------
#  Summary
# ----------------------------------------------------------------------------
summary() {
    printf '\n%s\n' "${C_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    printf '%s Bootstrap complete %s\n' "${C_BOLD}" "${C_RESET}"
    for r in "${RESULTS[@]}"; do
        printf '   %s\n' "$r"
    done
    printf '%s\n' "${C_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    printf '\n%sNext steps:%s\n' "${C_BOLD}" "${C_RESET}"
    if [[ -n "$WRITTEN_RC" ]]; then
        printf '     source ~%s   # reload shell config (zoxide, aliases, PATH)\n' "$WRITTEN_RC"
    fi
    printf '     gh auth login           # GitHub CLI\n'
    printf '     claude                  # log in to Claude Code\n'
    printf '     opencode                # log in / configure providers\n'
    printf '     restart opencode        # new opencode config loads on restart\n'
    printf '     log out & back in       # pick up docker/sudo group changes\n'
    printf '\n%sDone. Happy hacking!%s\n' "${C_GREEN}" "${C_RESET}"
}

# ----------------------------------------------------------------------------
#  CLI
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
bootstrap.sh $VERSION - distro-agnostic dev-machine setup (TUI)

Usage:
  bash bootstrap.sh [options]          # run setup
  bash bootstrap.sh manage [command]   # manage installed tools

Setup options:
  -y, --yes              run everything without prompting
  --remote               assume this IS the target machine (used when the
                         script has been copied to another host over ssh)
  --user NAME            target user for dotfiles/configs
  --files-dir DIR        dir with config files (default: ./files next to script, or \$BOOTSTRAP_FILES_DIR)
  --skip-user            skip user creation step
  --skip-network         skip network status / static IP step
  --skip-docker          skip docker step
  --skip-nvidia          skip nvidia container toolkit step
  --skip-ghostty         skip ghostty step
  --skip-tools           skip dev tools step
  --skip-nvim            skip neovim + lazyvim step
  --skip-toolchains      skip language toolchains step
  --skip-vscode          skip VS Code + extensions step
  --skip-configs         skip dotfiles step
  --skip-extras          skip extra apps (ffmpeg, microsoft edge)
  --skip-scpt            skip scpt (tmux SSH helper + file transfer) step
  --tui-off              plain output, no colors/spinners

Manage commands:
  manage                 interactive TUI: pick installed tools to remove
  manage list            list tools installed by bootstrap
  manage remove TOOL     remove a managed tool (snap/tarball/distro pkg)

Note: if bootstrap.sh has already run on this machine, running it again
(without -y) will offer the manage TUI before starting setup.

Examples:
  bash bootstrap.sh                    # interactive setup (or manage TUI, if re-run)
  bash bootstrap.sh -y                 # everything, no prompts
  bash bootstrap.sh -y --user bob      # everything for user 'bob'
  bash bootstrap.sh manage             # interactive removal TUI
  bash bootstrap.sh manage list        # list managed tools
  bash bootstrap.sh manage remove nvim # remove neovim
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --remote) REMOTE_MODE=1 ;;
            --user) USER_FLAG="${2:-}"; shift ;;
            --files-dir) FILES_DIR="${2:-}"; shift ;;
            manage) shift; MANAGE_MODE="${1:-tui}"; MANAGE_ARG="${2:-}"; return 0 ;;
            --skip-user) SKIP_USER=1 ;;
            --skip-network) SKIP_NETWORK=1 ;;
            --skip-docker) SKIP_DOCKER=1 ;;
            --skip-nvidia) SKIP_NVIDIA=1 ;;
            --skip-ghostty) SKIP_GHOSTTY=1 ;;
            --skip-tools) SKIP_TOOLS=1 ;;
            --skip-nvim) SKIP_NVIM=1 ;;
            --skip-toolchains) SKIP_TOOLCHAINS=1 ;;
            --skip-vscode) SKIP_VSCODE=1 ;;
            --skip-configs) SKIP_CONFIGS=1 ;;
            --skip-extras) SKIP_EXTRAS=1 ;;
            --skip-scpt) SKIP_SCPT=1 ;;
            --skip-sht) SKIP_SCPT=1 ;; # backward compat: old name
            --skip-sft) SKIP_SCPT=1 ;; # backward compat: sft now part of scpt
            --tui-off) TUI_OFF=1 ;;
            -h|--help) usage; exit 0 ;;
            *) err "unknown option: $1"; usage; return 1 ;;
        esac
        shift
    done
    return 0
}

# ----------------------------------------------------------------------------
#  Remote bootstrap: if this machine isn't the target, copy the script (and
#  config files) to another host over ssh and run it there.
# ----------------------------------------------------------------------------
remote_bootstrap() {
    command -v ssh >/dev/null 2>&1 || { err "ssh not found; can't reach another machine"; return 1; }
    command -v tar >/dev/null 2>&1 || { err "tar not found; can't package the config files"; return 1; }

    read_line "SSH destination for the target computer (e.g. user@host, or with a keyfile: -i ~/.ssh/key.pem user@host): "
    local destline="${REPLY:-}"
    destline="${destline#ssh }"
    destline="${destline#ssh}"
    if [[ -z "$destline" ]]; then
        warn "no ssh destination given; aborting remote bootstrap"
        return 1
    fi

    info "target: ssh $destline"
    if ! confirm "Connect to '$destline' and run bootstrap there?" y; then
        info "cancelled"
        return 1
    fi

    local remote_dir="/tmp/bootstrap-remote-$$"
    info "preparing $remote_dir on the target..."
    # shellcheck disable=SC2086
    ssh $destline "rm -rf '$remote_dir' && mkdir -p '$remote_dir'" \
        || { err "could not reach $destline over ssh"; return 1; }

    # Stream everything over ssh itself (no scp), so any ssh flags the user
    # gives - keyfiles (-i), ports (-p), ProxyJump, -o options - apply to all
    # transfers and the remote run alike.
    info "copying bootstrap.sh..."
    cat "$0" | ssh $destline "cat > '$remote_dir/bootstrap.sh'" \
        || { err "could not copy bootstrap.sh to $destline"; return 1; }

    if [[ -d "$FILES_DIR" ]]; then
        info "copying config files..."
        local parent base
        parent="$(cd -- "$(dirname -- "$FILES_DIR")" 2>/dev/null && pwd -P)"
        base="$(basename "$FILES_DIR")"
        tar -C "$parent" -cf - "$base" | ssh $destline "tar -xf - -C '$remote_dir'" \
            || { err "could not copy config files to $destline"; return 1; }
    else
        warn "no local config files dir; dotfile/config steps will be skipped on the target"
    fi

    # Also copy tools/scpt if present (so scpt step works remotely)
    local tools_scpt="$SCRIPT_DIR/tools/scpt"
    if [[ -d "$tools_scpt" ]]; then
        info "copying scpt tool..."
        tar -C "$SCRIPT_DIR" -cf - "tools/scpt" | ssh $destline "tar -xf - -C '$remote_dir'" \
            || warn "could not copy scpt tool to $destline (scpt step will fallback to git clone)"
    fi

    # Forward the original flags but drop --files-dir (the copied files/ dir is
    # used instead) and mark the remote run so it doesn't re-ask this question.
    local FWD_ARGS=() skip=0 a
    for a in "${ORIGINAL_ARGS[@]:-}"; do
        if [[ $skip -eq 1 ]]; then skip=0; continue; fi
        if [[ "$a" == "--files-dir" ]]; then skip=1; continue; fi
        FWD_ARGS+=("$a")
    done
    FWD_ARGS+=("--remote")
    local qargs
    qargs="$(printf '%q ' "${FWD_ARGS[@]}")"

    info "starting bootstrap on the target (launched from $(hostname))..."
    # shellcheck disable=SC2086
    ssh $destline "cd '$remote_dir' && bash bootstrap.sh $qargs"
    local rc=$?
    ssh $destline "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
    return "$rc"
}

# ----------------------------------------------------------------------------
#  Interrupt handling
# ----------------------------------------------------------------------------
on_signal() {
    local sig="$1"
    trap - INT TERM
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
    fi
    printf '\r\e[K\n%sinterrupted%s\n' "$C_RED" "$C_RESET"
    [[ "$sig" == "INT" ]] && offer_rollback
    exit 130
}

# ----------------------------------------------------------------------------
#  main
# ----------------------------------------------------------------------------
main() {
    ORIGINAL_ARGS=("$@")
    parse_args "$@" || exit 1
    init_colors
    trap cleanup_tmp EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM

    # Locate the config files directory: --files-dir > BOOTSTRAP_FILES_DIR >
    # ./files next to this script.
    if [[ -z "$FILES_DIR" ]]; then
        SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
        FILES_DIR="${BOOTSTRAP_FILES_DIR:-$SCRIPT_DIR/files}"
    fi
    if [[ ! -d "$FILES_DIR" ]]; then
        warn "config files directory not found: $FILES_DIR (dotfile/config steps will be skipped)"
    fi

    # Ask whether this machine is the intended target. If not, deploy the
    # script (and config files) to another host over ssh and run it there.
    if [[ $REMOTE_MODE -eq 0 ]] && ! confirm "Is this the target computer?" y; then
        remote_bootstrap
        exit $?
    fi

    # Handle manage mode early
    if [[ -n "$MANAGE_MODE" ]]; then
        case "$MANAGE_MODE" in
            list) manage_list; exit 0 ;;
            remove) manage_remove "$MANAGE_ARG"; exit $? ;;
            tui) manage_tui; exit 0 ;;
            *) err "unknown manage command: $MANAGE_MODE"; usage; exit 1 ;;
        esac
    fi

    # Bootstrap has already run on this machine (there's a managed-tools log).
    # Offer the manage TUI instead of barreling into setup again.
    if [[ $ASSUME_YES -eq 0 && -s "$INSTALLED_LOG" ]]; then
        local n_managed
        n_managed="$(grep -c . "$INSTALLED_LOG" 2>/dev/null || echo 0)"
        printf '\n%s%s tool(s) previously installed by this bootstrap script were found.%s\n' "$C_DIM" "$n_managed" "$C_RESET"
        if confirm "Manage installed packages instead of running setup?" n; then
            manage_tui
            exit 0
        fi
        printf '\n'
    fi

    printf '%s\n' "${C_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    printf '%s Dev Machine Bootstrap %s (v%s)%s\n' "${C_BOLD}${C_ORANGE}" "$C_RESET" "$VERSION" "$C_RESET"
    printf '%s distro-agnostic · optional steps · TUI%s\n' "$C_DIM" "$C_RESET"
    printf '%s\n' "${C_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"

    if [[ $EUID -eq 0 ]]; then
        DEFAULT_USER="${SUDO_USER:-root}"
    else
        DEFAULT_USER="${USER:-$(id -un)}"
    fi
    TARGET_USER="${USER_FLAG:-$DEFAULT_USER}"
    # Resolve TARGET_HOME here (not only inside step_user) so it's always set
    # even with --skip-user; later steps (e.g. step_docker) reference it
    # directly and would hit an unbound-variable abort under 'set -u' otherwise.
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        err "target user '$TARGET_USER' has no valid home directory"
        exit 1
    fi

    if ! run_step "Preflight (distro detection)" step_preflight; then
        err "preflight failed; aborting"
        exit 1
    fi

    if [[ $SKIP_USER -eq 1 ]]; then skip_step "User setup"; else run_step "User setup" step_user; fi
    if [[ $SKIP_NETWORK -eq 1 ]]; then skip_step "Network"; else run_step "Network" step_network; fi
    if [[ $SKIP_DOCKER -eq 1 ]]; then skip_step "Docker + Compose"; else run_step "Docker + Compose" step_docker; fi
    if [[ $SKIP_NVIDIA -eq 1 ]]; then skip_step "NVIDIA container toolkit"; else run_step "NVIDIA container toolkit" step_nvidia; fi
    if [[ $SKIP_GHOSTTY -eq 1 ]]; then skip_step "Ghostty + terminfo"; else run_step "Ghostty + terminfo" step_ghostty; fi
    if [[ $SKIP_TOOLS -eq 1 ]]; then skip_step "Dev tools"; else run_step "Dev tools" step_tools; fi
    if [[ $SKIP_NVIM -eq 1 ]]; then skip_step "Neovim + LazyVim"; else run_step "Neovim + LazyVim" step_neovim; fi
    if [[ $SKIP_TOOLCHAINS -eq 1 ]]; then skip_step "Language toolchains"; else run_step "Language toolchains" step_toolchains; fi
    if [[ $SKIP_VSCODE -eq 1 ]]; then skip_step "VS Code + extensions"; else run_step "VS Code + extensions" step_vscode; fi
    if [[ $SKIP_CONFIGS -eq 1 ]]; then skip_step "Dotfiles / configs"; else run_step "Dotfiles / configs" step_configs; fi
    if [[ $SKIP_EXTRAS -eq 1 ]]; then skip_step "Extra apps (ffmpeg, edge)"; else run_step "Extra apps (ffmpeg, edge)" step_extras; fi
    if [[ $SKIP_SCPT -eq 1 ]]; then skip_step "scpt (tmux SSH helper + file transfer)"; else run_step "scpt (tmux SSH helper + file transfer)" step_scpt; fi

    ensure_home_ownership
    summary
}

main "$@"
