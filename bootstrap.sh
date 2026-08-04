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
VERSION="1.4.0"
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
SKIP_CONFIGS=0
SKIP_EXTRAS=0
USER_FLAG=""
RESULTS=()
STEPS_TOTAL=11
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
SPINNER_PID=""

ID="" ID_LIKE="" VERSION_ID="" CODENAME="" PRETTY_NAME=""
ARCH="$(uname -m)"
PM="none"
SCRIPT_DIR=""
FILES_DIR=""

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
    asroot usermod -aG sudo,docker "$TARGET_USER" 2>/dev/null \
        || asroot usermod -aG wheel,docker "$TARGET_USER" 2>/dev/null || true
    ok "target user: $TARGET_USER ($TARGET_HOME) [sudo, docker]"
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

step_docker() {
    if command -v docker >/dev/null 2>&1; then
        ok "docker already installed: $(docker --version 2>/dev/null | head -1)"
        return 0
    fi
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

write_zshrc() {
    local home="$1" tmp
    tmp="$(new_tmp)"
    if ! read_file "zshrc" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [[ -f "$home/.zshrc" ]]; then
        asroot cp "$home/.zshrc" "$home/.zshrc.bak" 2>/dev/null || true
        BACKED_UP_FILES+=("$home/.zshrc:$home/.zshrc.bak")
        info "existing .zshrc backed up to .zshrc.bak"
    else
        CREATED_FILES+=("$home/.zshrc")
    fi
    asroot install -o "$1" -g "$(id -gn "$1" 2>/dev/null || echo "$1")" -m 0644 "$tmp" "$home/.zshrc"
    rm -f "$tmp"
    ok "wrote $home/.zshrc"
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

    if [[ $want_zsh -eq 1 ]] && confirm "Write ~/.zshrc and set default shell to zsh?" y; then
        write_zshrc "$TARGET_HOME"
        if [[ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" != "$(command -v zsh)" ]]; then
            if asroot chsh -s "$(command -v zsh)" "$TARGET_USER" 2>/dev/null; then
                ok "default shell -> zsh for $TARGET_USER (new shells only)"
            else
                warn "chsh failed; set shell manually with: chsh -s $(command -v zsh)"
            fi
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
            info "launch 'nvim' once to let LazyVim install its plugins"
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

_setup_ssh_signing() {
    local ssh_dir="$TARGET_HOME/.ssh" key="$TARGET_HOME/.ssh/id_ed25519" pub="$TARGET_HOME/.ssh/id_ed25519.pub"
    local email
    email="$(run_user "$TARGET_USER" git config --global user.email 2>/dev/null)"
    email="${email:-${TARGET_USER}@$(hostname)}"

    asroot install -d -m 700 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$ssh_dir"

    if [[ ! -f "$key" ]]; then
        info "generating a fresh ed25519 SSH key (new per machine)"
        if [[ $EUID -eq 0 ]]; then
            run_user "$TARGET_USER" bash -c "ssh-keygen -t ed25519 -N '' -C '$email' -f '$key'" || { warn "ssh-keygen failed"; return 1; }
        else
            ssh-keygen -t ed25519 -N "" -C "$email" -f "$key" || { warn "ssh-keygen failed"; return 1; }
        fi
        ok "generated $key"
        SSH_KEY_CREATED=1
        SSH_KEY_PATH="$key"
    else
        info "reusing existing ssh key at $key"
    fi

    local pubkey
    pubkey="$(cat "$pub")"

    if [[ -f "$ssh_dir/config" ]] && grep -q 'Host github.com' "$ssh_dir/config" 2>/dev/null; then
        :
    else
        {
            printf '\nHost github.com\n'
            printf '    HostName github.com\n'
            printf '    User git\n'
            printf '    IdentityFile %s\n' "$key"
            printf '    IdentitiesOnly yes\n'
            printf '    AddKeysToAgent yes\n'
        } | asroot tee -a "$ssh_dir/config" >/dev/null
        asroot chmod 600 "$ssh_dir/config" 2>/dev/null || true
        asroot chown "$TARGET_USER:" "$ssh_dir/config" 2>/dev/null || true
        ok "github.com entry added to $ssh_dir/config"
    fi

    local tmp
    tmp="$(new_tmp)"
    printf '%s %s %s\n' "$email" "$pubkey" "$email" > "$tmp"
    asroot install -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" -m 600 "$tmp" "$ssh_dir/allowed_signers"
    rm -f "$tmp"

    run_git_config gpg.format ssh
    run_git_config user.signingkey "$pub"
    run_git_config commit.gpgsign true
    run_git_config tag.gpgsign true
    run_git_config gpg.ssh.allowedSignersFile "$ssh_dir/allowed_signers"
    ok "git commit signing (ssh) configured with $pub"

    if command -v gh >/dev/null 2>&1 && run_user "$TARGET_USER" bash -c 'gh auth status >/dev/null 2>&1'; then
        if run_user "$TARGET_USER" bash -c "gh auth refresh -h github.com -s write:public_key && gh ssh-key add '$pub' -t 'bootstrap-$(hostname)'"; then
            ok "ssh public key uploaded to GitHub"
        else
            warn "couldn't upload key to GitHub (may already exist)"
        fi
    else
        warn "gh not authenticated yet; add the key manually:  gh ssh-key add $pub"
    fi
    return 0
}

step_configs() {
    ensure_user_dirs
    if ! confirm "Install dotfiles (git, ghostty, claude code, opencode, tmux)?" y; then return 0; fi
    local home="$TARGET_HOME"

    if confirm "Set up ~/.gitconfig (asks for your name/email)?" y; then
        _write_file "$home/.gitconfig" _gitconfig_content
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

    if confirm "Set up SSH key-based commit signing for git & GitHub?" y; then
        _setup_ssh_signing
    fi
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
    printf '     source ~/.zshrc         # reload shell config (zoxide, aliases, PATH)\n'
    printf '     gh auth login           # GitHub CLI\n'
    printf '     claude                  # log in to Claude Code\n'
    printf '     opencode                # log in / configure providers\n'
    printf '     restart opencode        # new opencode config loads on restart\n'
    printf '     nvim                    # let LazyVim finish installing plugins (if installed)\n'
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
  --skip-configs         skip dotfiles step
  --skip-extras          skip extra apps (ffmpeg, microsoft edge)
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
            --skip-configs) SKIP_CONFIGS=1 ;;
            --skip-extras) SKIP_EXTRAS=1 ;;
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
    TARGET_USER="$DEFAULT_USER"

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
    if [[ $SKIP_CONFIGS -eq 1 ]]; then skip_step "Dotfiles / configs"; else run_step "Dotfiles / configs" step_configs; fi
    if [[ $SKIP_EXTRAS -eq 1 ]]; then skip_step "Extra apps (ffmpeg, edge)"; else run_step "Extra apps (ffmpeg, edge)" step_extras; fi

    ensure_home_ownership
    summary
}

main "$@"
