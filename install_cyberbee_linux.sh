#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Cyberbee Interface — Linux installer
#
# This single file is all a user needs. It:
#   1. installs every system package the app needs (Qt/X11 libraries, git,
#      ssh, rsync, sshpass, jq, net-tools, …),
#   2. installs Docker Engine + the Compose plugin (needed for
#      "Calibrate on Computer") and adds the user to the docker group,
#   3. downloads the newest Linux release from GitHub, verifies its checksum,
#      and installs it to ~/CyberbeeInterface (keeping old calibration results),
#   4. creates the app-menu entry and a link to the app folder on the Desktop,
#   5. checks every library the app needs is present and test-starts it,
#   6. opens the app folder and starts the app.
#
# Usage (as your normal user — NOT with sudo; it asks for your password itself).
# Paste into a Terminal:
#     wget -qO- https://raw.githubusercontent.com/CyberBeeOfficial/Cyberbee_Interface_Releases/main/install_cyberbee_linux.sh | bash
# or, with the file downloaded:
#     bash ~/Downloads/install_cyberbee_linux.sh
#
# Options (after "bash -s --" when piping, e.g. "| bash -s -- --no-docker"):
#     --dir DIR        install into DIR/CyberbeeInterface   (default: $HOME)
#     --version TAG    install a specific release, e.g. v3.0.4 (default: newest)
#     --no-docker      skip Docker (on-computer calibration will not work)
#     --force          reinstall even if that version is already installed
#     -h, --help       show this help
#
# Safe to re-run: anything already installed is skipped.
#
# Output is one line per step with a green OK; command output goes to a log,
# which is only shown (and saved to ~/cyberbee-install-log.txt) on failure.
# Everything runs inside main(), so bash has read the whole file before the
# first command runs — required when the script is piped into bash.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

GH_OWNER="CyberBeeOfficial"
GH_REPO="Cyberbee_Interface_Releases"
APP_NAME="CyberbeeInterface"
DESKTOP_ID="cyberbee-interface"          # must match _DESKTOP_APP_ID in main.py
SAVED_LOG="$HOME/cyberbee-install-log.txt"

INSTALL_PARENT="$HOME"
WANT_TAG=""
WITH_DOCKER=1
FORCE=0

# ── output ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    IS_TTY=1
    C_OK=$'\033[1;32m'; C_W=$'\033[1;33m'; C_E=$'\033[1;31m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    IS_TTY=0
    C_OK=""; C_W=""; C_E=""; C_B=""; C_D=""; C_0=""
fi
STEP=""            # label of the step on the current line
SPIN_PID=""
SUDO_KEEPALIVE=""
TMP_DIR=""
LOG=/dev/null      # real log file once TMP_DIR exists
HINT=/dev/null     # optional "(waiting for …)" text shown after the spinner
LOG_MARK=0         # log line count when the current step began
NOTES=()           # things the user should know, shown at the end
PROBLEMS=()        # steps that failed without stopping the install
NEED_RELOGIN=0

# "Label ........" padded to a fixed width so the results line up.
pad() {
    local s="$1 "
    while [ "${#s}" -lt 46 ]; do s+="."; done
    printf '%s' "$s"
}

# Background spinner for the current step; with a file and a size it shows
# download progress instead.
spin() {
    trap - ERR EXIT INT TERM
    set +e
    local label="$1" file="${2:-}" total="${3:-0}" frames='|/-\' i=0 extra size
    while :; do
        extra=""
        if [ -n "$file" ] && [ "$total" -gt 0 ]; then
            size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
            extra=" $(( size * 100 / total ))%"
        elif [ -s "$HINT" ]; then
            extra=" ($(cat "$HINT"))"
        fi
        printf '\r\033[K  %s %s%s' "$(pad "$label")" "${frames:i++%4:1}" "$extra"
        sleep 0.2
    done
}

begin() {
    STEP="$1"
    : >"$HINT" 2>/dev/null || true
    printf '\n=== %s\n' "$1" >>"$LOG"
    LOG_MARK="$(wc -l <"$LOG" 2>/dev/null || echo 0)"
    if [ "$IS_TTY" -eq 1 ]; then
        spin "$@" &
        SPIN_PID=$!
    else
        printf '  %s ' "$(pad "$1")"
    fi
}

hint() { printf '%s' "$*" >"$HINT" 2>/dev/null || true; }

stop_spin() {
    if [ -n "$SPIN_PID" ]; then
        kill "$SPIN_PID" 2>/dev/null || true
        wait "$SPIN_PID" 2>/dev/null || true
        SPIN_PID=""
    fi
}

end_line() {
    stop_spin
    [ -n "$STEP" ] || return 0
    if [ "$IS_TTY" -eq 1 ]; then printf '\r\033[K  %s ' "$(pad "$STEP")"; fi
    printf '%s\n' "$1"
    STEP=""
}

ok()   { end_line "${C_OK}OK${C_0}"; }
note() { NOTES+=("$*"); printf 'NOTE: %s\n' "$*" >>"$LOG"; }
# A step failed but the install can carry on.
bad()  { end_line "${C_E}FAILED${C_0}"; PROBLEMS+=("$*"); printf 'PROBLEM: %s\n' "$*" >>"$LOG"; }

save_log() { [ -f "$LOG" ] && cp "$LOG" "$SAVED_LOG" 2>/dev/null; }

# A step failed and the install cannot go on: explain, keep the log, stop.
fail() {
    trap - ERR
    local msg="$1" step_out=""
    if [ -f "$LOG" ]; then step_out="$(tail -n +"$(( LOG_MARK + 1 ))" "$LOG" | grep -v '^\s*$' | tail -n 8)"; fi
    end_line "${C_E}FAILED${C_0}"
    printf 'FAILED: %s\n' "$msg" >>"$LOG"
    printf '\n%s  The installation could not finish.%s\n\n' "$C_E" "$C_0" >&2
    printf '%s\n' "$msg" | sed 's/^/  /' >&2
    if [ -n "$step_out" ]; then
        printf '\n%s  Last messages:%s\n' "$C_D" "$C_0" >&2
        printf '%s\n' "$step_out" | sed "s/^/    /; s/^/$C_D/; s/\$/$C_0/" >&2
    fi
    if save_log; then
        printf '\n  Details were saved to %s\n' "$SAVED_LOG" >&2
        printf '  If this keeps happening, send that file to Cyberbee support.\n' >&2
    fi
    printf '\n' >&2
    exit 1
}

cleanup() {
    stop_spin
    if [ -n "$SUDO_KEEPALIVE" ]; then kill "$SUDO_KEEPALIVE" 2>/dev/null || true; fi
    if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
    rm -rf "$INSTALL_PARENT/.cyberbee_install_tmp" 2>/dev/null || true
}

usage() { sed -n '/^# Usage/,/^# Safe to re-run/s/^# \{0,1\}//p' "$0" 2>/dev/null; exit 0; }

# ── apt helpers ──────────────────────────────────────────────────────────────
apt_install() {
    # Lock::Timeout: on a freshly installed Ubuntu, automatic updates often
    # hold the package lock for several minutes — wait instead of failing.
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=900 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        install "$@" >>"$LOG" 2>&1 </dev/null
}

# apt-get update ignores Lock::Timeout, so retry it while another apt holds
# the lock (up to 15 minutes). Returns apt-get's status otherwise.
apt_update() {
    local i out rc
    for i in $(seq 1 90); do
        rc=0
        out="$(sudo apt-get update -q 2>&1 </dev/null)" || rc=$?
        printf '%s\n' "$out" >>"$LOG"
        # Here-string, not a pipe: with pipefail, "grep -q" closing a pipe early
        # can turn a match into a failure.
        if [ "$rc" -ne 0 ] && grep -qiE "could not get lock|unable to lock" <<<"$out"; then
            hint "waiting for Ubuntu's automatic updates to finish"
            sleep 10
            continue
        fi
        hint ""
        return "$rc"
    done
    return 1
}

# Echo the installable name for a package: itself, its Ubuntu 24.04 "t64"
# rename, or nothing when this release has neither.
resolve_pkg() {
    local p="$1" cand
    for cand in "$p" "${p}t64"; do
        if [ -n "$(apt-cache policy "$cand" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]; then
            echo "$cand"; return 0
        fi
    done
    # A virtual package that something provides is still installable.
    if [ -n "$(apt-cache showpkg "$p" 2>/dev/null | awk '/^Reverse Provides:/ {f=1; next} f && NF')" ]; then
        echo "$p"; return 0
    fi
    return 1
}

docker_repo_present() {
    grep -rqs "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
}

add_docker_repo() {
    docker_repo_present && return 0
    [ -n "$DOCKER_DISTRO" ] && [ -n "$DIST_CODENAME" ] \
        || fail "Docker could not be installed automatically on ${PRETTY_NAME:-this system}.
Install Docker yourself (https://docs.docker.com/engine/install/) and run the
installer again, or run it with --no-docker to skip Docker."
    printf 'Adding Docker apt repository (%s %s)\n' "$DOCKER_DISTRO" "$DIST_CODENAME" >>"$LOG"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc >>"$LOG" 2>&1 \
        || fail "Could not reach download.docker.com. Check your internet connection and run the installer again."
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DOCKER_DISTRO
Suites: $DIST_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt_update || fail "Updating the package lists failed after adding Docker's repository.
Check your internet connection and run the installer again."
}

# Matches what main.py writes on first launch, so the two never fight.
write_desktop_file() {
    cat > "$1" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Cyberbee Interface
Comment=Cyberbee drone ground-station interface
Exec="$EXE"
Path=$INSTALL_DIR
Icon=$ICON_VALUE
Terminal=false
Categories=Utility;
StartupNotify=true
StartupWMClass=$APP_NAME
EOF
    chmod +x "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
main() {
    if [ "$(id -u)" -eq 0 ]; then
        # Started with "sudo bash install...": restart as the person who typed
        # it, so the app lands in their home, not root's. sudo has just cached
        # their password, so they are not asked again.
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -f "$0" ]; then
            exec sudo -u "$SUDO_USER" -H bash "$(readlink -f "$0")" "$@"
        fi
        fail "Please run the installer as your normal user, without \"sudo\".
It asks for your password by itself when it needs it."
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)       INSTALL_PARENT="${2:?--dir needs a folder}"; shift 2 ;;
            --version)   WANT_TAG="${2:?--version needs a tag}"; shift 2 ;;
            --no-docker) WITH_DOCKER=0; shift ;;
            --force)     FORCE=1; shift ;;
            -h|--help)   usage ;;
            *)           fail "Unknown option: $1 (try --help)" ;;
        esac
    done

    USER="${USER:-$(id -un)}"
    INSTALL_PARENT="$(mkdir -p "$INSTALL_PARENT" && cd "$INSTALL_PARENT" && pwd)"
    INSTALL_DIR="$INSTALL_PARENT/$APP_NAME"
    EXE="$INSTALL_DIR/$APP_NAME"

    TMP_DIR="$(mktemp -d -t cyberbee-install.XXXXXX)"
    LOG="$TMP_DIR/install.log"
    HINT="$TMP_DIR/hint"
    : >"$LOG"
    trap cleanup EXIT
    trap 'printf "\n"; exit 130' INT TERM
    trap 'fail "Something unexpected went wrong (installer line $LINENO).
Run the installer again; it continues where it stopped."' ERR

    printf '\n  %sCyberbee Interface installer%s\n\n' "$C_B" "$C_0"

    # ── 0. Pre-flight ────────────────────────────────────────────────────────
    begin "Checking this computer"
    [ -r /etc/os-release ] || fail "This Linux system could not be identified (/etc/os-release is missing)."
    # shellcheck source=/dev/null
    . /etc/os-release
    printf 'System: %s, %s\n' "${PRETTY_NAME:-unknown}" "$(uname -m)" >>"$LOG"
    command -v apt-get >/dev/null 2>&1 || fail "This installer works on Ubuntu and Debian based systems.
This computer runs ${PRETTY_NAME:-an unknown system}."
    [ "$(uname -m)" = "x86_64" ] || fail "Cyberbee Interface runs on 64-bit Intel/AMD computers (x86_64).
This computer is $(uname -m)."
    case " ${ID:-} ${ID_LIKE:-} " in
        *" ubuntu "*) DOCKER_DISTRO="ubuntu"; DIST_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
        *" debian "*) DOCKER_DISTRO="debian"; DIST_CODENAME="${VERSION_CODENAME:-}" ;;
        *)            DOCKER_DISTRO="";       DIST_CODENAME="" ;;
    esac
    ok

    if ! sudo -n true 2>/dev/null; then
        printf '\n  Your password is needed to install system software.\n'
        printf '  %s(Nothing appears on screen while you type it. Press Enter when done.)%s\n' "$C_D" "$C_0"
        sudo -v || fail "The password was not accepted, or this account is not allowed to
install software. Run the installer again and type the password you use
to log in. On a work computer, ask your IT department for help."
        printf '\n'
    fi
    # Keep sudo alive for the duration of the install.
    ( trap - ERR; while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE=$!

    # ── 1. System packages ───────────────────────────────────────────────────
    begin "Installing system packages"
    # Tools the app (and the device install script it runs) call by name.
    local TOOL_PKGS=(
        ca-certificates curl unzip    # this installer + HTTPS from the app
        git                           # Setup & Deploy clones SLAM_config
        openssh-client                # ssh / scp used by the deploy script
        rsync                         # deploy script copies files to the device
        sshpass jq                    # deploy script (the app also bundles both; system copies are a fallback)
        net-tools                     # 'arp' — USB-cable discovery in releases up to 3.0.x
        iproute2 iputils-ping         # 'ip', 'ping' — cable connect + scanner
        xdg-utils                     # opens the tutorial videos / PDFs, and the app folder
        libglib2.0-bin                # 'gio' — trusted desktop icon
        desktop-file-utils            # update-desktop-database
        acl                           # 'setfacl' — Docker access without logging out
    )
    # Qt 6 libraries. Releases up to 3.0.x do not bundle libxcb-cursor0 or
    # libatomic1 and fail to start without them (newer builds bundle both); the
    # rest are normally on a desktop already but are listed so minimal installs work.
    local QT_PKGS=(
        libxcb-cursor0 libxcb-xinerama0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1
        libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-xfixes0 libxcb-xkb1
        libxkbcommon0 libxkbcommon-x11-0 libx11-xcb1
        libgl1 libegl1 libopengl0 libfontconfig1 libfreetype6 libdbus-1-3 libglib2.0-0
        libatomic1                    # libQt6Pdf — the app crashes at start without it
        libwayland-client0 libwayland-cursor0 libwayland-egl1
    )
    # A broken third-party repository makes "update" fail but usually leaves
    # Ubuntu's own lists usable, so carry on and let the install decide.
    apt_update || printf 'apt-get update reported errors; continuing.\n' >>"$LOG"
    local TO_INSTALL=() p r
    for p in "${TOOL_PKGS[@]}" "${QT_PKGS[@]}"; do
        if r="$(resolve_pkg "$p")"; then
            TO_INSTALL+=("$r")
        else
            printf "Package '%s' is not available on this system - skipped.\n" "$p" >>"$LOG"
        fi
    done
    apt_install --no-install-recommends "${TO_INSTALL[@]}" \
        || fail "Installing system packages failed.
Check that this computer is connected to the internet, then run the
installer again. If it still fails, open a Terminal and run:
    sudo apt-get update
and look for error messages."
    if ! command -v nmcli >/dev/null 2>&1; then
        # Not installed automatically: it can change how this computer's network is managed.
        note "NetworkManager (nmcli) is missing, so 'Connect by cable' will not work. It is part of a standard Ubuntu Desktop."
    fi
    ok

    # ── 2. Docker ────────────────────────────────────────────────────────────
    # Docker variants we must not "repair" with apt: replacing them would break
    # the user's existing setup, so leave them alone and explain instead.
    if [ "$WITH_DOCKER" -eq 1 ] && command -v docker >/dev/null 2>&1; then
        if docker --version 2>&1 | grep -qi podman; then
            note "'docker' on this computer is Podman, which 'Calibrate on Computer' cannot use. Remove the podman-docker package and run the installer again to get Docker."
            WITH_DOCKER=2   # skip Docker setup; already explained above
        elif readlink -f "$(command -v docker)" | grep -q '^/snap/'; then
            note "Docker is installed as a Snap. If calibration has problems, run 'sudo snap remove docker' and run the installer again."
        fi
        if [ "$(docker context show 2>/dev/null)" = "desktop-linux" ]; then
            note "Docker Desktop is active; calibration may not reach the drone. If that happens, run: docker context use default"
        fi
    fi

    if [ "$WITH_DOCKER" -eq 1 ]; then
        begin "Installing Docker"
        if ! command -v docker >/dev/null 2>&1; then
            add_docker_repo
            apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
                || fail "Installing Docker failed.
Check your internet connection and run the installer again."
        fi
        if ! sudo docker compose version >/dev/null 2>&1; then
            local compose_pkg=docker-compose-plugin
            # dpkg-query, not "dpkg -s": a removed docker.io with leftover config
            # files still passes "dpkg -s", and installing docker-compose-v2 then
            # would pull docker.io back in and remove the user's docker-ce.
            if dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q "install ok installed" \
               && r="$(resolve_pkg docker-compose-v2)"; then
                # Ubuntu's own docker.io pairs with Ubuntu's own compose package.
                compose_pkg="$r"
            else
                add_docker_repo
            fi
            apt_install "$compose_pkg" || fail "Installing Docker Compose ($compose_pkg) failed.
Check your internet connection and run the installer again."
        fi
        sudo docker compose version >>"$LOG" 2>&1 || fail "Docker was installed, but 'docker compose' does not work.
Restart the computer and run the installer again."

        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            sudo systemctl enable --now docker >>"$LOG" 2>&1 || true
        fi

        # Let this user talk to Docker without sudo (the app runs docker directly).
        getent group docker >/dev/null || sudo groupadd docker
        if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
            sudo usermod -aG docker "$USER"
            NEED_RELOGIN=1
        elif ! id -nG | tr ' ' '\n' | grep -qx docker; then
            # In the group already, but this login session predates it.
            NEED_RELOGIN=1
        fi
        # A new group only reaches sessions started after the next login, so the
        # app would still be refused by Docker until the user logs out. Grant this
        # user access to the Docker socket directly as well: that applies at once,
        # even to an app that is already open. A reboot recreates the socket and
        # drops it, by which time the group membership has taken over.
        if [ "$NEED_RELOGIN" -eq 1 ]; then
            # (setfacl and -S follow the /var/run -> /run symlink themselves.)
            if [ -S /var/run/docker.sock ] && sudo setfacl -m "u:$USER:rw" /var/run/docker.sock 2>/dev/null \
               && docker info >/dev/null 2>&1; then
                NEED_RELOGIN=0
            fi
        fi

        # Calibration pulls two images on first use: data-handler (~0.4 GB) and
        # the solver (~4.4 GB), plus room for recordings and results.
        local DOCKER_ROOT FREE_GB
        DOCKER_ROOT="$(sudo docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
        [ -d "$DOCKER_ROOT" ] || DOCKER_ROOT="/var/lib"
        FREE_GB="$(df -P -BG "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {gsub("G", "", $4); print $4}')" || true
        if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt 20 ]; then
            note "Only ${FREE_GB} GB of disk space is free. The first 'Calibrate on Computer' downloads about 5 GB, plus room for recordings - free up space before then."
        fi
        if ! sudo docker info >/dev/null 2>&1; then
            note "The Docker service is not running. Restart the computer, or run: sudo systemctl start docker"
        fi
        ok
    elif [ "$WITH_DOCKER" -eq 0 ]; then
        note "Docker was skipped (--no-docker), so 'Calibrate on Computer' will not work."
    fi

    # ── 3. Find the release ──────────────────────────────────────────────────
    begin "Looking for the newest version"
    local API="https://api.github.com/repos/$GH_OWNER/$GH_REPO/releases" RELEASES_JSON
    if [ -n "$WANT_TAG" ]; then
        case "$WANT_TAG" in v*|TEST-*) ;; *) WANT_TAG="v$WANT_TAG" ;; esac
        RELEASES_JSON="[$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API/tags/$WANT_TAG" 2>>"$LOG")]" \
            || fail "Version $WANT_TAG was not found on GitHub."
    else
        RELEASES_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API?per_page=50" 2>>"$LOG")" \
            || fail "Could not reach GitHub to find the newest version.
Check your internet connection and run the installer again."
    fi

    # Same rule as the in-app updater: newest published (non-draft, non-pre)
    # release that actually carries a Linux zip. Not every release has both OSes.
    local TAG="" ASSET_URL="" ASSET_SIZE=0 ASSET_DIGEST=""
    read -r TAG ASSET_URL ASSET_SIZE ASSET_DIGEST < <(
        printf '%s' "$RELEASES_JSON" | jq -r --arg want "$WANT_TAG" '
            [ .[]
              | select(.draft | not)
              | select($want != "" or (.prerelease | not))
              | { tag: .tag_name,
                  a: [ .assets[] | select(.name | test("linux"; "i")) | select(.name | endswith(".zip")) ] }
              | select(.a | length > 0) ]
            | first
            | if . == null then "" else
                "\(.tag) \(.a[0].browser_download_url) \(.a[0].size) \(.a[0].digest // "none")" end'
    ) || true
    [ -n "${TAG:-}" ] || fail "No Linux version of Cyberbee Interface was found on GitHub${WANT_TAG:+ for $WANT_TAG}."
    local NEW_VERSION="${TAG#v}" OLD_VERSION=""
    printf 'Release %s: %s (%s bytes)\n' "$TAG" "$ASSET_URL" "$ASSET_SIZE" >>"$LOG"
    if [ -f "$INSTALL_DIR/_internal/calibration_automation/version.txt" ]; then
        OLD_VERSION="$(tr -d '[:space:]' < "$INSTALL_DIR/_internal/calibration_automation/version.txt")"
    fi
    ok

    local SKIP_APP=0
    if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" = "$NEW_VERSION" ] && [ "$FORCE" -eq 0 ]; then
        SKIP_APP=1
        begin "Cyberbee Interface $NEW_VERSION already installed"
        ok
    fi

    # ── 4. Download + install the app ────────────────────────────────────────
    if [ "$SKIP_APP" -eq 0 ]; then
        if pgrep -f "^$INSTALL_DIR/$APP_NAME" >/dev/null 2>&1; then
            fail "Cyberbee Interface is open. Close it and run the installer again."
        fi

        local ZIP="$TMP_DIR/$APP_NAME.zip"
        begin "Downloading Cyberbee Interface $NEW_VERSION" "$ZIP" "$ASSET_SIZE"
        curl -fsSL --retry 3 --retry-delay 3 -o "$ZIP" "$ASSET_URL" >>"$LOG" 2>&1 \
            || fail "The download did not finish.
Check your internet connection and run the installer again."
        if [ "${ASSET_DIGEST%%:*}" = "sha256" ]; then
            echo "${ASSET_DIGEST#sha256:}  $ZIP" | sha256sum -c --quiet -
        else
            unzip -tq "$ZIP"
        fi >>"$LOG" 2>&1 || fail "The download is damaged. Run the installer again to download it again."
        ok

        begin "Installing Cyberbee Interface $NEW_VERSION"
        local STAGE="$INSTALL_PARENT/.cyberbee_install_tmp"   # same filesystem → atomic move
        rm -rf "$STAGE"; mkdir -p "$STAGE"
        unzip -q "$ZIP" -d "$STAGE" >>"$LOG" 2>&1 \
            || fail "The download could not be unpacked. Check that there is at least 1 GB of free disk space and run the installer again."
        local NEW_DIR="$STAGE/$APP_NAME" helper
        [ -f "$NEW_DIR/$APP_NAME" ] || fail "The download does not contain the $APP_NAME program. Please tell Cyberbee support."
        chmod +x "$NEW_DIR/$APP_NAME"
        for helper in jq sshpass rsync; do
            if [ -f "$NEW_DIR/_internal/$helper" ]; then chmod +x "$NEW_DIR/_internal/$helper"; fi
        done

        local BACKUP="" CALIB_REL keep src
        if [ -e "$INSTALL_DIR" ]; then
            # The user's own data lives INSIDE the install folder: calibration
            # results and bags, plus any boards/profiles/intrinsics they added.
            # Carry it across before the old copy goes away. --ignore-existing:
            # files shipped with the new version win over old copies of them.
            CALIB_REL="_internal/calibration_automation"
            for keep in results bags config/boards config/profiles config/intrinsics; do
                src="$INSTALL_DIR/$CALIB_REL/$keep"
                [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ] || continue
                mkdir -p "$NEW_DIR/$CALIB_REL/$keep"
                rsync -a --ignore-existing "$src/" "$NEW_DIR/$CALIB_REL/$keep/" >>"$LOG" 2>&1 \
                    || fail "Your previous calibration files ($keep) could not be copied to the new version, so nothing was changed.
Free some disk space and run the installer again."
                printf 'Kept previous %s\n' "$keep" >>"$LOG"
            done
            # Same "<name>.old-<stamp>" pattern as the in-app updater, so the app
            # deletes this backup by itself on its next start.
            BACKUP="$INSTALL_DIR.old-$(date +%Y%m%d%H%M%S)"
            mv "$INSTALL_DIR" "$BACKUP"
            printf 'Previous version %s moved to %s\n' "${OLD_VERSION:-?}" "$BACKUP" >>"$LOG"
        fi
        if ! mv "$NEW_DIR" "$INSTALL_DIR"; then
            if [ -n "$BACKUP" ]; then mv "$BACKUP" "$INSTALL_DIR"; fi
            fail "The new version could not be put in place; your previous version was restored."
        fi
        rm -rf "$STAGE"

        # Releases up to 3.0.4 bundle an sshpass replacement that needs OpenSSH 8.4+;
        # with older OpenSSH (Ubuntu 20.04) "Setup & Deploy" hangs at the password
        # prompt. Point the bundled name at the real sshpass, which works everywhere.
        local SSH_VER
        SSH_VER="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1\2/p')"
        if [ -n "$SSH_VER" ] && [ "$SSH_VER" -lt 84 ] && command -v sshpass >/dev/null 2>&1 \
           && [ -e "$INSTALL_DIR/_internal/sshpass" ]; then
            ln -sf "$(command -v sshpass)" "$INSTALL_DIR/_internal/sshpass"
        fi
        ok
    fi

    # ── 5. Menu entry + Desktop folder link ──────────────────────────────────
    begin "Adding Cyberbee Interface to your computer"
    local ICON_SRC="$INSTALL_DIR/_internal/assets/logos/cyberbee_logo.png"
    local ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
    local APPS_DIR="$HOME/.local/share/applications"
    mkdir -p "$ICON_DIR" "$APPS_DIR"
    ICON_VALUE="$ICON_SRC"
    if [ -f "$ICON_SRC" ]; then
        cp "$ICON_SRC" "$ICON_DIR/$DESKTOP_ID.png"
        ICON_VALUE="$DESKTOP_ID"
    fi
    write_desktop_file "$APPS_DIR/$DESKTOP_ID.desktop"

    local DESKTOP_DIR LINK
    DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
    if [ -d "$DESKTOP_DIR" ] && [ "$DESKTOP_DIR" != "$HOME" ]; then
        # The folder link replaces the launcher icon older installers put there.
        rm -f "$DESKTOP_DIR/$DESKTOP_ID.desktop"
        LINK="$DESKTOP_DIR/$APP_NAME"
        if [ "$DESKTOP_DIR" = "$INSTALL_PARENT" ]; then
            :   # --dir put the app folder itself on the Desktop
        elif [ -L "$LINK" ] || [ ! -e "$LINK" ]; then
            ln -sfn "$INSTALL_DIR" "$LINK"
        else
            printf 'Not linking: %s already exists and is not a link\n' "$LINK" >>"$LOG"
        fi
    fi
    if [ -f "$ICON_SRC" ]; then
        gio set -t string "$EXE" metadata::custom-icon "file://$ICON_SRC" >>"$LOG" 2>&1 || true
    fi
    update-desktop-database "$APPS_DIR" >>"$LOG" 2>&1 || true
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >>"$LOG" 2>&1 || true
    ok

    # ── 6. Verify the GUI will start ─────────────────────────────────────────
    local APP_RUNNING=0 APP_OK=1
    if pgrep -f "^$EXE" >/dev/null 2>&1; then APP_RUNNING=1; fi

    begin "Checking that the app starts"
    local BUNDLE="$INSTALL_DIR/_internal"
    local QT_DIR="$BUNDLE/PyQt6/Qt6" MISSING
    # ldd every bundled library, resolving the way the app does (bundle first).
    # Qt plugins are optional (Qt skips one it cannot load) except the X11 one.
    MISSING="$(
        { find "$BUNDLE" -type f -name '*.so*' -not -path "$QT_DIR/plugins/*"
          echo "$QT_DIR/plugins/platforms/libqxcb.so"; } |
        while read -r so; do
            if [ -f "$so" ]; then LD_LIBRARY_PATH="$BUNDLE:$QT_DIR/lib" ldd "$so" 2>/dev/null || true; fi
        done | awk '/not found/ {print $1}' | sort -u
    )" || true
    if [ -n "$MISSING" ]; then
        APP_OK=0
        bad "These system libraries the app needs are missing: $(echo "$MISSING" | tr '\n' ' ')"
    elif [ "$APP_RUNNING" -eq 0 ]; then
        # Start the real program headless for a few seconds: catches anything ldd
        # cannot (a missing library loaded at import time, a broken bundle, ...).
        local SMOKE_RC=0 SMOKE_LOG="$TMP_DIR/smoke.log"
        ( cd "$INSTALL_DIR" && QT_QPA_PLATFORM=offscreen timeout -s TERM 15 "$EXE" ) >"$SMOKE_LOG" 2>&1 </dev/null || SMOKE_RC=$?
        cat "$SMOKE_LOG" >>"$LOG"
        if [ "$SMOKE_RC" -eq 124 ] && ! grep -qE "Traceback|Failed to execute script" "$SMOKE_LOG"; then
            ok
        else
            APP_OK=0
            bad "The app did not start in the test (exit code $SMOKE_RC)."
        fi
    else
        ok
    fi

    local t
    for t in git ssh scp rsync sshpass jq ip ping; do
        command -v "$t" >/dev/null 2>&1 || [ -x "$INSTALL_DIR/_internal/$t" ] \
            || note "The program '$t' is missing; some features may not work."
    done

    # ── Done ─────────────────────────────────────────────────────────────────
    trap - ERR
    if [ "${#PROBLEMS[@]}" -gt 0 ]; then
        save_log || true
        printf '\n%s  Cyberbee Interface %s is installed, but something is wrong:%s\n' "$C_E" "$NEW_VERSION" "$C_0"
        for p in "${PROBLEMS[@]}"; do printf '    - %s\n' "$p"; done
        printf '\n  Please send %s to Cyberbee support.\n' "$SAVED_LOG"
    else
        printf '\n%s  Done! Cyberbee Interface %s is installed.%s\n' "$C_OK" "$NEW_VERSION" "$C_0"
    fi

    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        # The folder first, then the app, so the app window ends up in front.
        # "setsid -f" detaches fully: closing the Terminal does not close them,
        # and bash never prints a message about them.
        setsid -f xdg-open "$INSTALL_DIR" </dev/null >/dev/null 2>&1 || true
        if [ "$APP_OK" -eq 1 ] && [ "$APP_RUNNING" -eq 0 ]; then
            sleep 1
            ( cd "$INSTALL_DIR" && setsid -f "$EXE" </dev/null >/dev/null 2>&1 ) || true
            printf '  Starting it now...\n'
        fi
    fi
    printf '\n  Next time, open the %s%s%s folder on your Desktop and\n' "$C_B" "$APP_NAME" "$C_0"
    printf '  double-click %s%s%s, or find "Cyberbee Interface" in your apps.\n' "$C_B" "$APP_NAME" "$C_0"

    if [ "$NEED_RELOGIN" -eq 1 ]; then
        printf '\n%s  Important: log out and log back in (or restart the computer)%s\n' "$C_W" "$C_0"
        printf '  before using "Calibrate on Computer".\n'
    fi
    if [ "${#NOTES[@]}" -gt 0 ]; then
        printf '\n%s  Please note:%s\n' "$C_W" "$C_0"
        for p in "${NOTES[@]}"; do printf '    - %s\n' "$p"; done
    fi
    printf '\n'
}

main "$@"
