#!/bin/bash
# DMG Watch Installer - fixed-screen Terminal UI with persistent completion screen
# Version 1.0.0
#
# Scans a folder for DMG and ISO files, mounts them without opening Finder, and:
#   - copies new drag-and-drop .app bundles into the configured application
#     directory, which defaults to /Applications;
#   - updates an already-installed app at the exact path found by Spotlight,
#     including an Applications folder on an external volume;
#   - installs only .pkg/.mpkg files located at the root of a mounted image;
#   - recursively opens nested DMG and ISO files, including images in subfolders;
#   - deliberately ignores packages found inside ordinary subfolders.
#
# The interactive terminal UI uses the alternate screen buffer and absolute
# cursor positioning so it redraws in place without filling Terminal scrollback.
# It falls back to line-by-line output when stderr is redirected or the terminal
# is too small.
#
# Usage:
#   Double-click this file, or run:
#     ./DMG_Watch_Installer.command [--dry-run] [--plain] [--no-wait] [watch-folder]
#
# The default watch folder is: ~/Downloads/DMG Watch
# Generic defaults can be overridden through the environment variables described
# by --help. No user name, host name, or machine-specific path is embedded here.

# Re-execute under Apple's bundled Bash when somebody invokes the file through
# `sh script.command`. The script intentionally targets Bash 3.2 syntax so it
# works with the Bash version included with macOS as well as newer Bash builds.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

set -u
set -o pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"

if [ -z "${HOME:-}" ]; then
    printf 'DMG Watch Installer requires HOME to be set.\n' >&2
    exit 1
fi

###############################################################################
# Configuration
###############################################################################

DEFAULT_WATCH_FOLDER="$HOME/Downloads/DMG Watch"
DEFAULT_APP_DIRECTORY="${DMG_DEFAULT_APP_DIRECTORY:-/Applications}"
MAX_IMAGE_DEPTH="${DMG_MAX_IMAGE_DEPTH:-8}"
LOG_FILE="${DMG_LOG_FILE:-$HOME/Library/Logs/DMG Watch Installer.log}"
MIN_TUI_COLUMNS=68
MIN_TUI_ROWS=19
MAX_TUI_COLUMNS=116
RECENT_EVENT_COUNT=5

###############################################################################
# Arguments
###############################################################################

DRY_RUN=0
WATCH_FOLDER="${DMG_WATCH_FOLDER:-$DEFAULT_WATCH_FOLDER}"
POSITIONAL_SEEN=0
UI_REQUEST="auto"
NO_COLOR_REQUESTED=0
WAIT_AT_END=1

usage() {
    cat <<USAGE
Usage:
  $(basename "$0") [--dry-run] [--plain|--tui] [--no-color] [--no-wait] [watch-folder]

Options:
  --dry-run    Mount and inspect images, but do not copy apps or run packages.
  --plain      Disable the full-screen terminal UI and print one event per line.
  --tui        Request the full-screen UI when an interactive terminal is present.
  --no-color   Disable ANSI colors in both TUI and plain output.
  --no-wait    Close the TUI immediately after completion instead of waiting.
  --version    Print the program version and exit.
  -h, --help   Show this help.

The watch folder defaults to:
  $DEFAULT_WATCH_FOLDER

Pass a watch-folder path from Terminal to override the default.

Environment variables:
  DMG_WATCH_FOLDER           Default watch folder when no path is supplied.
  DMG_DEFAULT_APP_DIRECTORY  Destination for newly discovered apps.
                             Default: /Applications
  DMG_MAX_IMAGE_DEPTH        Maximum nested DMG/ISO depth. Default: 8
  DMG_LOG_FILE               Absolute log-file path.
  NO_COLOR                   Disable ANSI colors when set to any value.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --plain|--no-tui)
            UI_REQUEST="off"
            ;;
        --tui)
            UI_REQUEST="on"
            ;;
        --no-color)
            NO_COLOR_REQUESTED=1
            ;;
        --no-wait)
            WAIT_AT_END=0
            ;;
        --version)
            printf 'DMG Watch Installer %s\n' "$SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if [ "$#" -gt 1 ] || { [ "$#" -gt 0 ] && [ "$POSITIONAL_SEEN" -eq 1 ]; }; then
                printf 'Only one watch folder may be supplied.\n' >&2
                exit 2
            fi
            if [ "$#" -eq 1 ]; then
                WATCH_FOLDER="$1"
                POSITIONAL_SEEN=1
            fi
            break
            ;;
        -*)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ "$POSITIONAL_SEEN" -eq 1 ]; then
                printf 'Only one watch folder may be supplied.\n' >&2
                exit 2
            fi
            WATCH_FOLDER="$1"
            POSITIONAL_SEEN=1
            ;;
    esac
    shift
done

###############################################################################
# Platform and configuration preflight
###############################################################################

if [ "$(/usr/bin/uname -s 2>/dev/null || true)" != "Darwin" ]; then
    printf 'DMG Watch Installer runs only on macOS.\n' >&2
    exit 69
fi

if [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
    printf 'DMG Watch Installer requires Bash 3.2 or newer.\n' >&2
    exit 69
fi

case "$MAX_IMAGE_DEPTH" in
    ''|*[!0-9]*)
        printf 'DMG_MAX_IMAGE_DEPTH must be a whole number from 0 through 64.\n' >&2
        exit 2
        ;;
esac
if [ "$MAX_IMAGE_DEPTH" -gt 64 ]; then
    printf 'DMG_MAX_IMAGE_DEPTH must not exceed 64.\n' >&2
    exit 2
fi

case "$DEFAULT_APP_DIRECTORY" in
    /*) ;;
    *)
        printf 'DMG_DEFAULT_APP_DIRECTORY must be an absolute path.\n' >&2
        exit 2
        ;;
esac

while [ "$DEFAULT_APP_DIRECTORY" != "/" ] && [ "${DEFAULT_APP_DIRECTORY%/}" != "$DEFAULT_APP_DIRECTORY" ]; do
    DEFAULT_APP_DIRECTORY="${DEFAULT_APP_DIRECTORY%/}"
done
if [ "$DEFAULT_APP_DIRECTORY" = "/" ]; then
    printf 'DMG_DEFAULT_APP_DIRECTORY must name an application directory, not the filesystem root.\n' >&2
    exit 2
fi

case "$LOG_FILE" in
    /*) ;;
    *)
        printf 'DMG_LOG_FILE must be an absolute path.\n' >&2
        exit 2
        ;;
esac
case "$LOG_FILE" in
    */)
        printf 'DMG_LOG_FILE must name a file, not a directory path.\n' >&2
        exit 2
        ;;
esac

MISSING_TOOL=""
for REQUIRED_TOOL in \
    /bin/cp \
    /bin/date \
    /bin/mkdir \
    /bin/mv \
    /bin/rm \
    /usr/bin/awk \
    /usr/bin/basename \
    /usr/bin/dirname \
    /usr/bin/ditto \
    /usr/bin/find \
    /usr/bin/grep \
    /usr/bin/head \
    /usr/bin/hdiutil \
    /usr/bin/id \
    /usr/bin/mktemp \
    /usr/bin/sed \
    /usr/bin/sort \
    /usr/bin/stat \
    /usr/bin/sudo \
    /usr/bin/tr \
    /usr/libexec/PlistBuddy \
    /usr/sbin/installer \
    /usr/sbin/pkgutil
do
    if [ ! -x "$REQUIRED_TOOL" ]; then
        MISSING_TOOL="$REQUIRED_TOOL"
        break
    fi
done
if [ -n "$MISSING_TOOL" ]; then
    printf 'Required macOS tool is unavailable: %s\n' "$MISSING_TOOL" >&2
    exit 69
fi

###############################################################################
# Terminal UI and logging
###############################################################################

UI_ACTIVE=0
UI_COLOR=0
UI_WIDTH=80
UI_HEIGHT=24
UI_EVENT_ROWS=5
UI_RENDER_ROW=1
UI_CURSOR_HIDDEN=0
UI_ALT_SCREEN_ACTIVE=0
RUN_FINISHED=0
UI_FINAL_SCREEN=0
RUN_START_EPOCH="$(/bin/date '+%s')"
CURRENT_IMAGE="Waiting to scan"
CURRENT_DEPTH=0
CURRENT_PHASE="Preparing"
CURRENT_DETAIL=""

# Fixed-size arrays are initialized explicitly for compatibility with the
# macOS-supplied Bash 3.2 while set -u is enabled.
UI_EVENT_TEXT=("" "" "" "" "")
UI_EVENT_LEVEL=("INFO" "INFO" "INFO" "INFO" "INFO")

C_RESET=""
C_BOLD=""
C_DIM=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_MAGENTA=""
C_CYAN=""
C_BORDER=""

# Counters are initialized before the first UI render.
IMAGE_COUNT=0
IMAGE_TOTAL_KNOWN=0
IMAGE_COMPLETED_COUNT=0
APP_FOUND_COUNT=0
APP_PLANNED_COUNT=0
APP_INSTALLED_COUNT=0
PKG_FOUND_COUNT=0
PKG_PLANNED_COUNT=0
PKG_INSTALLED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

repeat_char() {
    local character="$1"
    local count="$2"
    local output=""
    local i

    for ((i=0; i<count; i++)); do
        output="${output}${character}"
    done
    printf '%s' "$output"
}

truncate_text() {
    local text="$1"
    local maximum="$2"
    local length

    [ "$maximum" -gt 0 ] || return 0
    length=${#text}
    if [ "$length" -le "$maximum" ]; then
        printf '%s' "$text"
    elif [ "$maximum" -le 3 ]; then
        printf '%s' "${text:0:$maximum}"
    else
        printf '%s...' "${text:0:$((maximum - 3))}"
    fi
}

sanitize_text() {
    # Prevent file names or metadata containing terminal control characters
    # from injecting escape sequences into the TUI, plain output, or our own
    # structured log messages. macOS paths cannot contain NUL, but the full
    # control range is mapped for completeness.
    printf '%s' "$1" | LC_ALL=C /usr/bin/tr '\000-\037\177' '?'
}

compact_path() {
    local path="$1"
    case "$path" in
        "$HOME") printf '~\n' ;;
        "$HOME"/*) printf '~/%s\n' "${path#"$HOME"/}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

format_elapsed() {
    local now elapsed hours minutes seconds
    now="$(/bin/date '+%s')"
    elapsed=$((now - RUN_START_EPOCH))
    [ "$elapsed" -ge 0 ] || elapsed=0
    hours=$((elapsed / 3600))
    minutes=$(((elapsed % 3600) / 60))
    seconds=$((elapsed % 60))

    if [ "$hours" -gt 0 ]; then
        printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
    else
        printf '%02d:%02d' "$minutes" "$seconds"
    fi
}

ui_init_colors() {
    local color_allowed=1

    [ "$NO_COLOR_REQUESTED" -eq 0 ] || color_allowed=0
    [ -z "${NO_COLOR+x}" ] || color_allowed=0
    [ -t 2 ] || color_allowed=0
    [ "${TERM:-dumb}" != "dumb" ] || color_allowed=0

    if [ "$color_allowed" -eq 1 ]; then
        UI_COLOR=1
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'
        C_MAGENTA=$'\033[35m'
        C_CYAN=$'\033[36m'
        C_BORDER=$'\033[90m'
    fi
}

ui_enter_screen() {
    [ "$UI_ACTIVE" -eq 1 ] || return 0

    if [ "$UI_ALT_SCREEN_ACTIVE" -eq 0 ]; then
        # The alternate screen keeps redraws out of the normal Terminal
        # scrollback buffer. Absolute row addressing below performs the actual
        # in-place repainting.
        printf '\033[?1049h\033[H\033[2J' >&2
        UI_ALT_SCREEN_ACTIVE=1
    fi

    printf '\033[?25l' >&2
    UI_CURSOR_HIDDEN=1
}

ui_init() {
    local columns=""
    local rows=""
    local usable_columns

    ui_init_colors

    [ "$UI_REQUEST" != "off" ] || return 0
    [ -t 2 ] || return 0
    [ "${TERM:-dumb}" != "dumb" ] || return 0

    columns="$(/usr/bin/tput cols 2>/dev/null || true)"
    rows="$(/usr/bin/tput lines 2>/dev/null || true)"
    case "$columns" in
        ''|*[!0-9]*) columns=80 ;;
    esac
    case "$rows" in
        ''|*[!0-9]*) rows=24 ;;
    esac

    # Never draw in the terminal's final column. Printing into that column sets
    # the terminal's pending-wrap state and can make the next repaint scroll.
    usable_columns=$((columns - 1))
    if [ "$usable_columns" -lt "$MIN_TUI_COLUMNS" ] || [ "$rows" -lt "$MIN_TUI_ROWS" ]; then
        return 0
    fi
    if [ "$usable_columns" -gt "$MAX_TUI_COLUMNS" ]; then
        usable_columns="$MAX_TUI_COLUMNS"
    fi

    UI_WIDTH="$usable_columns"
    UI_HEIGHT="$rows"

    # The non-event portion of the dashboard occupies 18 rows. Reduce the
    # recent-activity area on short terminals so the frame always fits without
    # touching an extra row.
    UI_EVENT_ROWS=$((rows - 18))
    [ "$UI_EVENT_ROWS" -ge 1 ] || UI_EVENT_ROWS=1
    [ "$UI_EVENT_ROWS" -le "$RECENT_EVENT_COUNT" ] || UI_EVENT_ROWS="$RECENT_EVENT_COUNT"

    UI_ACTIVE=1
    ui_enter_screen
}

ui_restore_terminal() {
    if [ "$UI_ALT_SCREEN_ACTIVE" -eq 1 ]; then
        printf '\033[0m\033[?25h\033[?1049l' >&2
        UI_ALT_SCREEN_ACTIVE=0
        UI_CURSOR_HIDDEN=0
    elif [ "$UI_CURSOR_HIDDEN" -eq 1 ]; then
        printf '\033[0m\033[?25h' >&2
        UI_CURSOR_HIDDEN=0
    fi
}

ui_level_color() {
    case "$1" in
        OK) printf '%s' "$C_GREEN" ;;
        WARN) printf '%s' "$C_YELLOW" ;;
        ERROR) printf '%s' "$C_RED" ;;
        ACTION) printf '%s' "$C_BLUE" ;;
        PLAN) printf '%s' "$C_MAGENTA" ;;
        *) printf '%s' "$C_CYAN" ;;
    esac
}

ui_level_tag() {
    case "$1" in
        OK) printf ' OK ' ;;
        WARN) printf 'WARN' ;;
        ERROR) printf 'FAIL' ;;
        ACTION) printf 'STEP' ;;
        PLAN) printf 'PLAN' ;;
        *) printf 'INFO' ;;
    esac
}

ui_add_event() {
    local level="$1"
    local message="$2"

    UI_EVENT_TEXT[0]="${UI_EVENT_TEXT[1]}"
    UI_EVENT_LEVEL[0]="${UI_EVENT_LEVEL[1]}"
    UI_EVENT_TEXT[1]="${UI_EVENT_TEXT[2]}"
    UI_EVENT_LEVEL[1]="${UI_EVENT_LEVEL[2]}"
    UI_EVENT_TEXT[2]="${UI_EVENT_TEXT[3]}"
    UI_EVENT_LEVEL[2]="${UI_EVENT_LEVEL[3]}"
    UI_EVENT_TEXT[3]="${UI_EVENT_TEXT[4]}"
    UI_EVENT_LEVEL[3]="${UI_EVENT_LEVEL[4]}"
    UI_EVENT_TEXT[4]="$message"
    UI_EVENT_LEVEL[4]="$level"
}

ui_emit_line() {
    local line="$1"

    # Address each row directly and never emit a newline. This prevents the
    # bottom row from advancing the terminal and eliminates waterfall scrolling.
    printf '\033[%d;1H\033[2K%s' "$UI_RENDER_ROW" "$line" >&2
    UI_RENDER_ROW=$((UI_RENDER_ROW + 1))
}

ui_box_line() {
    local text="$1"
    local color="${2-}"
    local inner padded rendered

    inner=$((UI_WIDTH - 4))
    text="$(sanitize_text "$text")"
    text="$(truncate_text "$text" "$inner")"
    printf -v padded '%-*s' "$inner" "$text"
    printf -v rendered '%s|%s %s%s%s %s|%s' \
        "$C_BORDER" "$C_RESET" "$color" "$padded" "$C_RESET" "$C_BORDER" "$C_RESET"
    ui_emit_line "$rendered"
}

ui_horizontal_line() {
    local line rendered
    line="$(repeat_char '-' $((UI_WIDTH - 2)))"
    printf -v rendered '%s+%s+%s' "$C_BORDER" "$line" "$C_RESET"
    ui_emit_line "$rendered"
}

ui_progress_bar() {
    local width="$1"
    local completed="$2"
    local total="$3"
    local filled empty

    if [ "$total" -gt 0 ]; then
        filled=$((completed * width / total))
    else
        filled=0
    fi
    [ "$filled" -le "$width" ] || filled="$width"
    empty=$((width - filled))
    printf '%s%s' "$(repeat_char '=' "$filled")" "$(repeat_char '-' "$empty")"
}

ui_render() {
    local inner mode mode_color header spaces watch_display image_display detail_display
    local percentage bar_width bar progress_text elapsed index event_start event_text event_level event_color event_tag
    local apps_word packages_word

    [ "$UI_ACTIVE" -eq 1 ] || return 0

    inner=$((UI_WIDTH - 4))
    if [ "$DRY_RUN" -eq 1 ]; then
        mode="DRY RUN - NO CHANGES"
        mode_color="$C_YELLOW"
        apps_word="planned"
        packages_word="planned"
    else
        mode="LIVE INSTALL"
        mode_color="$C_RED"
        apps_word="installed"
        packages_word="installed"
    fi

    spaces=$((inner - ${#mode} - 19))
    if [ "$spaces" -lt 1 ]; then
        header="DMG WATCH INSTALLER - $mode"
    else
        header="DMG WATCH INSTALLER$(printf '%*s' "$spaces" '')$mode"
    fi

    if [ "$IMAGE_TOTAL_KNOWN" -gt 0 ]; then
        percentage=$((IMAGE_COMPLETED_COUNT * 100 / IMAGE_TOTAL_KNOWN))
    else
        percentage=0
    fi
    [ "$percentage" -le 100 ] || percentage=100

    bar_width=$((inner - 31))
    [ "$bar_width" -ge 16 ] || bar_width=16
    [ "$bar_width" -le 44 ] || bar_width=44
    bar="$(ui_progress_bar "$bar_width" "$IMAGE_COMPLETED_COUNT" "$IMAGE_TOTAL_KNOWN")"
    progress_text="Progress     [$bar] $IMAGE_COMPLETED_COUNT/$IMAGE_TOTAL_KNOWN (${percentage}%)"

    watch_display="$(compact_path "$WATCH_FOLDER")"
    image_display="$CURRENT_IMAGE"
    if [ "$CURRENT_DEPTH" -gt 0 ]; then
        image_display="$image_display  [nested depth $CURRENT_DEPTH]"
    fi
    detail_display="$CURRENT_DETAIL"
    elapsed="$(format_elapsed)"

    ui_enter_screen
    UI_RENDER_ROW=1
    ui_horizontal_line
    ui_box_line "$header" "$mode_color$C_BOLD"
    ui_horizontal_line
    ui_box_line "Watch folder  $watch_display" "$C_CYAN"
    ui_box_line "Current       $image_display" "$C_BOLD"
    ui_box_line "Phase         $CURRENT_PHASE" "$C_BLUE"
    if [ -n "$detail_display" ]; then
        ui_box_line "Detail        $detail_display" "$C_DIM"
    else
        ui_box_line "Detail        -" "$C_DIM"
    fi
    ui_box_line "$progress_text" "$C_GREEN"
    ui_box_line "Elapsed       $elapsed" "$C_DIM"
    ui_horizontal_line
    ui_box_line "Applications  found $APP_FOUND_COUNT | planned $APP_PLANNED_COUNT | installed $APP_INSTALLED_COUNT" "$C_CYAN"
    ui_box_line "Packages      found $PKG_FOUND_COUNT | planned $PKG_PLANNED_COUNT | installed $PKG_INSTALLED_COUNT" "$C_CYAN"
    ui_box_line "Images        seen $IMAGE_COUNT | skipped $SKIPPED_COUNT | failures $FAILED_COUNT" "$C_CYAN"
    ui_horizontal_line
    ui_box_line "Recent activity" "$C_BOLD"

    event_start=$((RECENT_EVENT_COUNT - UI_EVENT_ROWS))
    for ((index=event_start; index<RECENT_EVENT_COUNT; index++)); do
        event_text="${UI_EVENT_TEXT[$index]}"
        event_level="${UI_EVENT_LEVEL[$index]}"
        if [ -n "$event_text" ]; then
            event_color="$(ui_level_color "$event_level")"
            event_tag="$(ui_level_tag "$event_level")"
            ui_box_line "[$event_tag] $event_text" "$event_color"
        else
            ui_box_line " " "$C_DIM"
        fi
    done

    ui_horizontal_line
    if [ "$UI_FINAL_SCREEN" -eq 1 ] && [ "$WAIT_AT_END" -eq 1 ]; then
        ui_box_line "Finished. Press Enter, q, or Esc to close. Full details are in the log." "$C_BOLD$C_GREEN"
    elif [ "$UI_FINAL_SCREEN" -eq 1 ]; then
        ui_box_line "Finished. Full details are in the log." "$C_BOLD$C_GREEN"
    else
        ui_box_line "Ctrl-C safely detaches images. Full details are always written to the log." "$C_DIM"
    fi
    ui_horizontal_line

    # Clear anything below the frame without moving through it line by line.
    if [ "$UI_RENDER_ROW" -le "$UI_HEIGHT" ]; then
        printf '\033[%d;1H\033[J' "$UI_RENDER_ROW" >&2
    fi
}

ui_print_plain() {
    local level="$1"
    local message="$2"
    local color tag

    color="$(ui_level_color "$level")"
    tag="$(ui_level_tag "$level")"
    printf '[%s] %s[%s]%s %s\n' "$(timestamp)" "$color" "$tag" "$C_RESET" "$message" >&2
}

ui_set_current() {
    CURRENT_IMAGE="$1"
    CURRENT_DEPTH="$2"
    ui_render
}

ui_set_status() {
    CURRENT_PHASE="$1"
    CURRENT_DETAIL="${2-}"
    ui_render
}

ui_before_authorization_prompt() {
    [ "$UI_ACTIVE" -eq 1 ] || return 0
    ui_restore_terminal
    printf '\n%sAdministrator authorization may be requested by macOS.%s\n\n' "$C_YELLOW$C_BOLD" "$C_RESET" >&2
}

ui_after_authorization_prompt() {
    [ "$UI_ACTIVE" -eq 1 ] || return 0
    ui_enter_screen
    ui_render
}

ui_wait_for_exit() {
    local key=""

    [ "$UI_ACTIVE" -eq 1 ] || return 0
    [ "$WAIT_AT_END" -eq 1 ] || return 0
    [ -r /dev/tty ] || return 0

    while :; do
        key=""
        if ! IFS= read -r -s -n 1 key < /dev/tty; then
            break
        fi
        case "$key" in
            ''|q|Q|x|X|$'\033') break ;;
        esac
    done
}

ui_finish() {
    local result_message result_level

    if [ "$FAILED_COUNT" -gt 0 ]; then
        result_message="Completed with $FAILED_COUNT failure(s)"
        result_level="ERROR"
        CURRENT_PHASE="Completed with failures"
    elif [ "$DRY_RUN" -eq 1 ]; then
        result_message="Dry run completed; no changes were made"
        result_level="OK"
        CURRENT_PHASE="Dry run complete"
    else
        result_message="Installation run completed successfully"
        result_level="OK"
        CURRENT_PHASE="Installation complete"
    fi

    RUN_FINISHED=1
    UI_FINAL_SCREEN=1
    CURRENT_DETAIL="Log: $(compact_path "$LOG_FILE")"
    ui_add_event "$result_level" "$result_message"
    ui_render
    ui_wait_for_exit
    ui_restore_terminal

    if [ "$UI_ACTIVE" -eq 1 ]; then
        printf '\n%s%s%s\n' "$(ui_level_color "$result_level")" "$result_message" "$C_RESET" >&2
        printf 'Log: %s\n' "$LOG_FILE" >&2
    fi
}

mkdir -p "$(dirname "$LOG_FILE")" || {
    printf 'Cannot create log directory: %s\n' "$(dirname "$LOG_FILE")" >&2
    exit 1
}

ui_init

# Protect the alternate screen during early validation failures, before the
# full disk-image cleanup trap is installed later in the script.
early_terminal_cleanup() {
    ui_restore_terminal
}
trap early_terminal_cleanup EXIT
trap 'ui_restore_terminal; exit 129' HUP
trap 'ui_restore_terminal; exit 130' INT
trap 'ui_restore_terminal; exit 143' TERM

timestamp() {
    /bin/date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local level="INFO"
    local message=""
    local line

    case "${1-}" in
        INFO|ACTION|OK|WARN|ERROR|PLAN)
            level="$1"
            shift
            ;;
    esac

    if [ "$#" -gt 0 ]; then
        message="$1"
        shift
    fi
    while [ "$#" -gt 0 ]; do
        message="$message $1"
        shift
    done

    message="$(sanitize_text "$message")"

    line="[$(timestamp)] [$level] $message"
    printf '%s\n' "$line" >> "$LOG_FILE"

    if [ "$UI_ACTIVE" -eq 1 ]; then
        ui_add_event "$level" "$message"
        ui_render
    else
        ui_print_plain "$level" "$message"
    fi
}

log_detail() {
    local message
    message="$(sanitize_text "$*")"
    printf '[%s] [DETAIL] %s\n' "$(timestamp)" "$message" >> "$LOG_FILE"
}

if [ ! -d "$WATCH_FOLDER" ]; then
    if [ "$POSITIONAL_SEEN" -eq 0 ] && /bin/mkdir -p "$WATCH_FOLDER" 2>/dev/null; then
        log OK "Created the default watch folder: $WATCH_FOLDER"
        log INFO "Place DMG or ISO files there and run the script again."
        ui_finish
        RUN_FINISHED=1
        exit 0
    fi

    log ERROR "Watch folder does not exist: $WATCH_FOLDER"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    ui_finish
    RUN_FINISHED=1
    exit 1
fi

# Resolve the watch folder physically so prefix checks are reliable.
WATCH_FOLDER="$(cd "$WATCH_FOLDER" 2>/dev/null && pwd -P)" || {
    log ERROR "Cannot access watch folder."
    FAILED_COUNT=$((FAILED_COUNT + 1))
    ui_finish
    RUN_FINISHED=1
    exit 1
}

WORK_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dmg-watch-installer.XXXXXX")" || {
    log ERROR "Could not create a temporary working directory."
    FAILED_COUNT=$((FAILED_COUNT + 1))
    ui_finish
    RUN_FINISHED=1
    exit 1
}
MOUNT_ROOT="$WORK_ROOT/mounts"
SEEN_IMAGE_FILE="$WORK_ROOT/seen-images.txt"
TOP_LEVEL_IMAGES_FILE="$WORK_ROOT/top-level-images.bin"
/bin/mkdir -p "$MOUNT_ROOT"
: > "$SEEN_IMAGE_FILE"
: > "$TOP_LEVEL_IMAGES_FILE"

# A non-empty sentinel avoids Bash 3.2 + set -u treating an empty array as unbound.
MOUNTED_POINTS=("")
SUDO_VALIDATED=0
ACTIVE_APP_STAGE=""
ACTIVE_APP_BACKUP=""
ACTIVE_APP_DESTINATION=""
ACTIVE_APP_USE_SUDO=0

canonical_path() {
    local input="$1"
    local parent base physical_parent
    parent="$(/usr/bin/dirname "$input")"
    base="$(/usr/bin/basename "$input")"
    if physical_parent="$(cd "$parent" 2>/dev/null && pwd -P)"; then
        printf '%s/%s\n' "$physical_parent" "$base"
    else
        printf '%s\n' "$input"
    fi
}

remove_mounted_point_from_list() {
    local target="$1"
    local i
    for ((i=1; i<${#MOUNTED_POINTS[@]}; i++)); do
        if [ "${MOUNTED_POINTS[$i]}" = "$target" ]; then
            # Keep the slot but clear it. Repacking an empty array triggers an
            # "unbound variable" error in Apple's Bash 3.2 when set -u is active.
            MOUNTED_POINTS[$i]=""
            return 0
        fi
    done
    return 0
}

clear_active_app_transaction() {
    ACTIVE_APP_STAGE=""
    ACTIVE_APP_BACKUP=""
    ACTIVE_APP_DESTINATION=""
    ACTIVE_APP_USE_SUDO=0
}

run_recovery_command() {
    if [ "$ACTIVE_APP_USE_SUDO" -eq 1 ] && [ "$(/usr/bin/id -u)" -ne 0 ]; then
        /usr/bin/sudo -n "$@"
    else
        "$@"
    fi
}

recover_active_app_transaction() {
    if [ -z "$ACTIVE_APP_STAGE" ] && [ -z "$ACTIVE_APP_BACKUP" ]; then
        return 0
    fi

    if [ -n "$ACTIVE_APP_BACKUP" ] && { [ -e "$ACTIVE_APP_BACKUP" ] || [ -L "$ACTIVE_APP_BACKUP" ]; }; then
        if [ -n "$ACTIVE_APP_DESTINATION" ] && [ ! -e "$ACTIVE_APP_DESTINATION" ] && [ ! -L "$ACTIVE_APP_DESTINATION" ]; then
            run_recovery_command /bin/mv "$ACTIVE_APP_BACKUP" "$ACTIVE_APP_DESTINATION" \
                >> "$LOG_FILE" 2>&1 || \
                log_detail "Could not restore interrupted application transaction: $ACTIVE_APP_DESTINATION"
        else
            run_recovery_command /bin/rm -rf "$ACTIVE_APP_BACKUP" \
                >> "$LOG_FILE" 2>&1 || \
                log_detail "Could not remove interrupted application backup: $ACTIVE_APP_BACKUP"
        fi
    fi

    if [ -n "$ACTIVE_APP_STAGE" ] && { [ -e "$ACTIVE_APP_STAGE" ] || [ -L "$ACTIVE_APP_STAGE" ]; }; then
        run_recovery_command /bin/rm -rf "$ACTIVE_APP_STAGE" \
            >> "$LOG_FILE" 2>&1 || \
            log_detail "Could not remove interrupted application stage: $ACTIVE_APP_STAGE"
    fi

    clear_active_app_transaction
}

cleanup() {
    local i mount_point
    trap - EXIT HUP INT TERM

    if [ "$RUN_FINISHED" -eq 0 ]; then
        CURRENT_PHASE="Cleaning up"
        CURRENT_DETAIL="Detaching any mounted disk images"
        ui_render
    fi

    recover_active_app_transaction

    for ((i=${#MOUNTED_POINTS[@]}-1; i>=0; i--)); do
        mount_point="${MOUNTED_POINTS[$i]}"
        [ -n "$mount_point" ] || continue
        /usr/bin/hdiutil detach -quiet "$mount_point" >> "$LOG_FILE" 2>&1 || \
            /usr/bin/hdiutil detach -force -quiet "$mount_point" >> "$LOG_FILE" 2>&1 || true
    done

    [ -n "${WORK_ROOT-}" ] && /bin/rm -rf "$WORK_ROOT"
    ui_restore_terminal
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_sudo() {
    if [ "$(/usr/bin/id -u)" -eq 0 ]; then
        return 0
    fi

    if [ "$SUDO_VALIDATED" -eq 1 ]; then
        /usr/bin/sudo -n true >/dev/null 2>&1 && return 0
        SUDO_VALIDATED=0
    fi

    ui_set_status "Waiting for authorization" "macOS administrator credentials may be required"
    log ACTION "Administrator authorization is required for this operation."
    ui_before_authorization_prompt
    if /usr/bin/sudo -v; then
        SUDO_VALIDATED=1
        ui_after_authorization_prompt
        log OK "Administrator authorization granted."
        return 0
    fi

    ui_after_authorization_prompt
    log ERROR "Administrator authorization was not granted."
    return 1
}

###############################################################################
# Application discovery and destination selection
###############################################################################

bundle_identifier() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    local value=""

    [ -f "$plist" ] || return 0
    [ ! -L "$plist" ] || return 0
    value="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    case "$value" in
        ''|'Does Not Exist') return 0 ;;
    esac
    printf '%s\n' "$value"
}

mdquery_escape() {
    # Escape text embedded inside a double-quoted Spotlight query literal.
    printf '%s' "$1" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g'
}

path_is_excluded_install_match() {
    local path="$1"
    local lower_path lower_parent lower_home
    lower_path="$(printf '%s' "$path" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    lower_parent="$(/usr/bin/dirname "$lower_path")"
    lower_home="$(printf '%s' "$HOME" | /usr/bin/tr '[:upper:]' '[:lower:]')"

    # Do not update helper applications nested inside another application bundle.
    case "$lower_parent" in
        *.app|*.app/*)
            return 0
            ;;
    esac

    case "$path" in
        "$WORK_ROOT"/*|"$MOUNT_ROOT"/*)
            return 0
            ;;
        /System/*|/private/var/folders/*|/private/tmp/*|/tmp/*)
            return 0
            ;;
        */.Trash/*|*/.Trashes/*|*/Backups.backupdb/*|*/.timemachine/*|*/MobileBackups/*)
            return 0
            ;;
    esac

    # Spotlight can also return archived or downloaded copies. Only accept
    # conventional local or external application-folder paths as installations.
    case "$lower_path" in
        /applications/*|"$lower_home"/applications/*|/volumes/*/applications/*|/volumes/*/apps/*|/volumes/*/*applications*/*|/volumes/*/*apps*/*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

candidate_score() {
    local candidate="$1"
    local wanted_name="$2"
    local score=0
    local mtime=0

    if [ "$(/usr/bin/basename "$candidate")" = "$wanted_name" ]; then
        score=$((score + 4000000000000))
    fi

    case "$candidate" in
        /Applications/*|"$HOME"/Applications/*|/Volumes/*/Applications/*)
            score=$((score + 2000000000000))
            ;;
        /Volumes/*/Apps/*)
            score=$((score + 1500000000000))
            ;;
    esac

    mtime="$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null || printf '0')"
    case "$mtime" in
        ''|*[!0-9]*) mtime=0 ;;
    esac
    score=$((score + mtime))
    printf '%s\n' "$score"
}

append_spotlight_results() {
    local output_file="$1"
    local bundle_id="$2"
    local app_name="$3"
    local escaped query

    if ! command -v /usr/bin/mdfind >/dev/null 2>&1; then
        return 0
    fi

    # Always perform a Spotlight query. Prefer bundle ID, then query by filename.
    if [ -n "$bundle_id" ]; then
        escaped="$(mdquery_escape "$bundle_id")"
        query="kMDItemCFBundleIdentifier == \"$escaped\"c"
        log_detail "Spotlight query: $query"
        /usr/bin/mdfind "$query" >> "$output_file" 2>> "$LOG_FILE" || true
    fi

    escaped="$(mdquery_escape "$app_name")"
    query="kMDItemFSName == \"$escaped\"c && kMDItemContentType == \"com.apple.application-bundle\""
    log_detail "Spotlight query: $query"
    /usr/bin/mdfind "$query" >> "$output_file" 2>> "$LOG_FILE" || true
}

append_fallback_application_results() {
    local output_file="$1"
    local app_name="$2"
    local root volume applications_dir

    # This fallback covers volumes where Spotlight indexing is disabled. It is
    # intentionally limited to conventional Applications/Apps folders.
    for root in "/Applications" "$HOME/Applications"; do
        [ -d "$root" ] || continue
        /usr/bin/find "$root" -maxdepth 4 -type d -iname '*.app' -prune -iname "$app_name" -print \
            >> "$output_file" 2>> "$LOG_FILE" || true
    done

    for volume in /Volumes/*; do
        [ -d "$volume" ] || continue
        for applications_dir in "$volume/Applications" "$volume/Apps"; do
            [ -d "$applications_dir" ] || continue
            /usr/bin/find "$applications_dir" -maxdepth 4 -type d -iname '*.app' -prune -iname "$app_name" -print \
                >> "$output_file" 2>> "$LOG_FILE" || true
        done
    done
}

find_best_installed_app() {
    local source_app="$1"
    local wanted_id wanted_name wanted_name_lower results_file sorted_file
    local candidate candidate_id score best_score=-1 best_path="" match_count=0

    wanted_id="$(bundle_identifier "$source_app")"
    wanted_name="$(/usr/bin/basename "$source_app")"
    wanted_name_lower="$(printf '%s' "$wanted_name" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    results_file="$(/usr/bin/mktemp "$WORK_ROOT/app-results.XXXXXX")"
    sorted_file="$(/usr/bin/mktemp "$WORK_ROOT/app-results-sorted.XXXXXX")"

    append_spotlight_results "$results_file" "$wanted_id" "$wanted_name"
    append_fallback_application_results "$results_file" "$wanted_name"

    LC_ALL=C /usr/bin/sort -u "$results_file" > "$sorted_file" 2>/dev/null || \
        /bin/cp "$results_file" "$sorted_file"

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        [ -d "$candidate" ] || continue
        [ ! -L "$candidate" ] || continue
        case "$(/usr/bin/basename "$candidate" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
            *.app) ;;
            *) continue ;;
        esac
        path_is_excluded_install_match "$candidate" && continue

        if [ -n "$wanted_id" ]; then
            candidate_id="$(bundle_identifier "$candidate")"
            [ "$candidate_id" = "$wanted_id" ] || continue
        elif [ "$(/usr/bin/basename "$candidate" | /usr/bin/tr '[:upper:]' '[:lower:]')" != "$wanted_name_lower" ]; then
            continue
        fi

        score="$(candidate_score "$candidate" "$wanted_name")"
        log_detail "Installed-app candidate: $candidate; source: $wanted_name; bundle-id: ${wanted_id:-unavailable}; score: $score"
        match_count=$((match_count + 1))
        if [ "$score" -gt "$best_score" ]; then
            best_score="$score"
            best_path="$candidate"
        fi
    done < "$sorted_file"

    /bin/rm -f "$results_file" "$sorted_file"

    if [ "$match_count" -gt 1 ] && [ -n "$best_path" ]; then
        log WARN "Found $match_count installed matches for $wanted_name; selected: $best_path"
    fi

    [ -n "$best_path" ] && printf '%s\n' "$best_path"
}

is_probable_installer_wrapper_app() {
    local app="$1"
    local lower_name embedded
    lower_name="$(/usr/bin/basename "$app" | /usr/bin/tr '[:upper:]' '[:lower:]')"

    case "$lower_name" in
        install\ *.app|installer.app|*\ installer.app|setup.app|setup\ *.app)
            return 0
            ;;
    esac

    if [ -d "$app/Contents" ]; then
        embedded="$(/usr/bin/find "$app/Contents" \
            \( -type d -iname '*.app' -prune \) -o \
            \( \( -type f -o -type d \) \( -iname '*.pkg' -o -iname '*.mpkg' \) -print -prune \) \
            2>/dev/null | /usr/bin/head -n 1 || true)"
        [ -n "$embedded" ] && return 0
    fi

    return 1
}

install_app_bundle() {
    local source_app="$1"
    local source_name source_id existing_app destination parent destination_name destination_display
    local stage backup use_sudo=0 copied_id destination_id

    source_name="$(/usr/bin/basename "$source_app")"
    source_id="$(bundle_identifier "$source_app")"
    APP_FOUND_COUNT=$((APP_FOUND_COUNT + 1))
    ui_set_status "Checking application destination" "$source_name"

    # A valid macOS application bundle must contain Contents/Info.plist. This
    # avoids copying an arbitrary directory that merely ends in ".app".
    if [ ! -f "$source_app/Contents/Info.plist" ] || [ -L "$source_app/Contents/Info.plist" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        log WARN "Skipped malformed application bundle: $source_name"
        log_detail "Missing or symbolic-link Contents/Info.plist: $source_app"
        return 0
    fi

    if is_probable_installer_wrapper_app "$source_app"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        log WARN "Skipped installer-wrapper app with no universal silent interface: $source_name"
        log_detail "Installer-wrapper path: $source_app"
        return 0
    fi

    existing_app="$(find_best_installed_app "$source_app")"
    if [ -n "$existing_app" ]; then
        destination="$existing_app"
        log INFO "Existing $source_name found; preserving location: $destination"
    else
        destination="$DEFAULT_APP_DIRECTORY/$source_name"
        log INFO "New application destination: $destination"
    fi

    parent="$(/usr/bin/dirname "$destination")"
    destination_name="$(/usr/bin/basename "$destination")"
    destination_display="$(compact_path "$destination")"

    # Never replace an unrelated item merely because it has the same filename.
    if [ -L "$destination" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        log WARN "Destination is a symbolic link; skipped: $destination"
        return 0
    fi
    if [ -e "$destination" ] && [ ! -d "$destination" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        log WARN "Destination exists but is not an application directory; skipped: $destination"
        return 0
    fi
    if [ -z "$existing_app" ] && [ -d "$destination" ]; then
        destination_id="$(bundle_identifier "$destination")"
        if [ -z "$source_id" ] || [ -z "$destination_id" ] || [ "$destination_id" != "$source_id" ]; then
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            log WARN "A different or unverifiable app uses the default destination; skipped: $destination"
            return 0
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        APP_PLANNED_COUNT=$((APP_PLANNED_COUNT + 1))
        ui_set_status "Application planned" "$source_name -> $destination_display"
        log PLAN "$source_name -> $destination"
        log_detail "DRY RUN source: $source_app"
        return 0
    fi

    ui_set_status "Preparing application install" "$source_name -> $destination_display"

    if [ ! -d "$parent" ]; then
        if [ -w "$(/usr/bin/dirname "$parent")" ]; then
            /bin/mkdir -p "$parent" >> "$LOG_FILE" 2>&1 || {
                FAILED_COUNT=$((FAILED_COUNT + 1))
                log ERROR "Could not create destination directory: $parent"
                return 1
            }
        else
            ensure_sudo || {
                FAILED_COUNT=$((FAILED_COUNT + 1))
                ui_render
                return 1
            }
            /usr/bin/sudo /bin/mkdir -p "$parent" >> "$LOG_FILE" 2>&1 || {
                FAILED_COUNT=$((FAILED_COUNT + 1))
                log ERROR "Could not create destination directory: $parent"
                return 1
            }
        fi
    fi

    if [ ! -w "$parent" ]; then
        ensure_sudo || {
            FAILED_COUNT=$((FAILED_COUNT + 1))
            ui_render
            return 1
        }
        use_sudo=1
    fi

    stage="$parent/.dmg-watch-stage.$$.$RANDOM"
    backup="$parent/.dmg-watch-backup.$$.$RANDOM"
    ACTIVE_APP_STAGE="$stage"
    ACTIVE_APP_BACKUP="$backup"
    ACTIVE_APP_DESTINATION="$destination"
    ACTIVE_APP_USE_SUDO="$use_sudo"

    ui_set_status "Copying application" "$source_name -> temporary staging area"
    if [ "$use_sudo" -eq 1 ]; then
        /usr/bin/sudo /bin/rm -rf "$stage" "$backup" >> "$LOG_FILE" 2>&1 || true
        if ! /usr/bin/sudo /usr/bin/ditto "$source_app" "$stage" >> "$LOG_FILE" 2>&1; then
            /usr/bin/sudo /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
            clear_active_app_transaction
            FAILED_COUNT=$((FAILED_COUNT + 1))
            log ERROR "Failed to stage application: $source_name"
            return 1
        fi
    else
        /bin/rm -rf "$stage" "$backup" >> "$LOG_FILE" 2>&1 || true
        if ! /usr/bin/ditto "$source_app" "$stage" >> "$LOG_FILE" 2>&1; then
            /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
            clear_active_app_transaction
            FAILED_COUNT=$((FAILED_COUNT + 1))
            log ERROR "Failed to stage application: $source_name"
            return 1
        fi
    fi

    ui_set_status "Verifying staged application" "$source_name"
    copied_id="$(bundle_identifier "$stage")"
    if [ -n "$source_id" ] && [ "$copied_id" != "$source_id" ]; then
        if [ "$use_sudo" -eq 1 ]; then
            /usr/bin/sudo /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
        else
            /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
        fi
        clear_active_app_transaction
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log ERROR "Staged application failed bundle-ID verification: $source_name"
        return 1
    fi

    ui_set_status "Replacing application" "$destination_display"
    if [ "$use_sudo" -eq 1 ]; then
        if [ -e "$destination" ]; then
            if ! /usr/bin/sudo /bin/mv "$destination" "$backup" >> "$LOG_FILE" 2>&1; then
                /usr/bin/sudo /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
                clear_active_app_transaction
                FAILED_COUNT=$((FAILED_COUNT + 1))
                log ERROR "Could not move the existing app aside: $destination"
                return 1
            fi
        fi

        if ! /usr/bin/sudo /bin/mv "$stage" "$destination" >> "$LOG_FILE" 2>&1; then
            [ -e "$backup" ] && /usr/bin/sudo /bin/mv "$backup" "$destination" >> "$LOG_FILE" 2>&1 || true
            /usr/bin/sudo /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
            clear_active_app_transaction
            FAILED_COUNT=$((FAILED_COUNT + 1))
            log ERROR "Could not place the new app at: $destination"
            return 1
        fi
        /usr/bin/sudo /bin/rm -rf "$backup" >> "$LOG_FILE" 2>&1 || true
    else
        if [ -e "$destination" ]; then
            if ! /bin/mv "$destination" "$backup" >> "$LOG_FILE" 2>&1; then
                /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
                clear_active_app_transaction
                FAILED_COUNT=$((FAILED_COUNT + 1))
                log ERROR "Could not move the existing app aside: $destination"
                return 1
            fi
        fi

        if ! /bin/mv "$stage" "$destination" >> "$LOG_FILE" 2>&1; then
            [ -e "$backup" ] && /bin/mv "$backup" "$destination" >> "$LOG_FILE" 2>&1 || true
            /bin/rm -rf "$stage" >> "$LOG_FILE" 2>&1 || true
            clear_active_app_transaction
            FAILED_COUNT=$((FAILED_COUNT + 1))
            log ERROR "Could not place the new app at: $destination"
            return 1
        fi
        /bin/rm -rf "$backup" >> "$LOG_FILE" 2>&1 || true
    fi

    clear_active_app_transaction
    APP_INSTALLED_COUNT=$((APP_INSTALLED_COUNT + 1))
    log OK "Installed $source_name -> $destination"
    return 0
}

###############################################################################
# Package handling
###############################################################################

normalize_installer_target_for_app_path() {
    local app_path="$1"
    local volume_relative volume_name

    case "$app_path" in
        /Volumes/*/*)
            # A mounted external volume is always rooted at /Volumes/<volume-name>.
            # Volume names cannot contain a slash, so extracting the first path
            # component preserves spaces without parsing df output.
            volume_relative="${app_path#/Volumes/}"
            volume_name="${volume_relative%%/*}"
            [ -n "$volume_name" ] && printf '/Volumes/%s\n' "$volume_name" || printf '/\n'
            ;;
        *)
            printf '/\n'
            ;;
    esac
}

determine_package_target() {
    local package="$1"
    local expand_dir targets_file preferred_targets_file selected_targets_file
    local app match target unique_file target_count
    local component_dir package_info install_location

    expand_dir="$WORK_ROOT/pkg-expand.$$.$RANDOM"
    targets_file="$WORK_ROOT/pkg-targets.$$.$RANDOM.txt"
    preferred_targets_file="$WORK_ROOT/pkg-targets-preferred.$$.$RANDOM.txt"
    unique_file="$WORK_ROOT/pkg-targets-unique.$$.$RANDOM.txt"
    : > "$targets_file"
    : > "$preferred_targets_file"

    if /usr/sbin/pkgutil --expand-full "$package" "$expand_dir" >> "$LOG_FILE" 2>&1; then
        while IFS= read -r -d '' app; do
            match="$(find_best_installed_app "$app")"
            [ -n "$match" ] || continue
            target="$(normalize_installer_target_for_app_path "$match")"
            printf '%s\n' "$target" >> "$targets_file"
            install_location=""
            case "$app" in
                */Payload/*)
                    component_dir="${app%%/Payload/*}"
                    package_info="$component_dir/PackageInfo"
                    if [ -f "$package_info" ]; then
                        install_location="$(/usr/bin/sed -n 's/.*install-location="\([^"]*\)".*/\1/p' "$package_info" | /usr/bin/head -1)"
                    fi
                    ;;
            esac

            case "$app:$install_location" in
                */Payload/Applications/*:*|*/Payload/Applications.localized/*:*|*:/Applications|*:/Applications/*)
                    printf '%s\n' "$target" >> "$preferred_targets_file"
                    ;;
            esac
            log_detail "Package app match: $app -> $match; installer target: $target; install-location: ${install_location:-unknown}"
        done < <(/usr/bin/find "$expand_dir" -type d -iname '*.app' -prune -print0 2>/dev/null)
    else
        log_detail "Could not expand package for destination discovery: $package"
    fi

    /bin/rm -rf "$expand_dir" >> "$LOG_FILE" 2>&1 || true
    if /usr/bin/awk 'NF { found=1 } END { exit(found ? 0 : 1) }' "$preferred_targets_file"; then
        selected_targets_file="$preferred_targets_file"
    else
        selected_targets_file="$targets_file"
    fi
    LC_ALL=C /usr/bin/sort -u "$selected_targets_file" > "$unique_file" 2>/dev/null || true
    target_count="$(/usr/bin/awk 'NF { count++ } END { print count+0 }' "$unique_file")"

    if [ "$target_count" -eq 1 ]; then
        target="$(/usr/bin/awk 'NF { print; exit }' "$unique_file")"
    elif [ "$target_count" -gt 1 ]; then
        log WARN "Package payload matched apps on multiple volumes; using the system target: $package"
        target="/"
    else
        target="/"
    fi

    /bin/rm -f "$targets_file" "$preferred_targets_file" "$unique_file"
    printf '%s\n' "$target"
}

install_root_package() {
    local package="$1"
    local package_name target target_display

    package_name="$(/usr/bin/basename "$package")"
    PKG_FOUND_COUNT=$((PKG_FOUND_COUNT + 1))
    ui_set_status "Inspecting installer package" "$package_name"

    # Never follow a package symlink from a mounted image. Flat packages are
    # regular files and bundle packages are directories, so a symlink is not
    # required for legitimate installation media.
    if [ -L "$package" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        log WARN "Skipped symbolic-link package: $package_name"
        log_detail "Symbolic-link package path: $package"
        return 0
    fi

    target="$(determine_package_target "$package")"
    [ -n "$target" ] || target="/"
    target_display="$(compact_path "$target")"

    if [ "$target" != "/" ] && [ ! -d "$target" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        log WARN "Package target volume is unavailable; skipped: $package_name"
        log_detail "Unavailable package target: $target; package: $package"
        return 0
    fi

    log_detail "Package signature report for: $package"
    /usr/sbin/pkgutil --check-signature "$package" >> "$LOG_FILE" 2>&1 || \
        log_detail "Package is unsigned or its signature could not be verified: $package"

    if [ "$DRY_RUN" -eq 1 ]; then
        PKG_PLANNED_COUNT=$((PKG_PLANNED_COUNT + 1))
        ui_set_status "Package planned" "$package_name -> target $target_display"
        log PLAN "$package_name -> installer target '$target'"
        return 0
    fi

    ensure_sudo || {
        FAILED_COUNT=$((FAILED_COUNT + 1))
        ui_render
        return 1
    }

    ui_set_status "Installing package" "$package_name -> target $target_display"
    log ACTION "Installing package $package_name to target '$target'"
    if /usr/bin/sudo /usr/sbin/installer -pkg "$package" -target "$target" -verboseR \
        >> "$LOG_FILE" 2>&1; then
        PKG_INSTALLED_COUNT=$((PKG_INSTALLED_COUNT + 1))
        log OK "Installed package: $package_name"
        return 0
    fi

    FAILED_COUNT=$((FAILED_COUNT + 1))
    log ERROR "Package installation failed: $package_name"
    return 1
}

report_ignored_nested_packages() {
    local mount_point="$1"
    local child base package package_relative

    while IFS= read -r -d '' child; do
        base="$(/usr/bin/basename "$child")"
        case "$(printf '%s' "$base" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
            *.app|*.pkg|*.mpkg)
                continue
                ;;
        esac
        [ -d "$child" ] || continue

        while IFS= read -r -d '' package; do
            package_relative="${package#"$mount_point"/}"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            log WARN "Ignored package in a subfolder: $package_relative"
            log_detail "Ignored nested package path: $package"
        done < <(/usr/bin/find "$child" \
            \( -type d -iname '*.app' -prune \) -o \
            \( \( -type f -o -type d \) \( -iname '*.pkg' -o -iname '*.mpkg' \) -print0 -prune \) \
            2>/dev/null)
    done < <(/usr/bin/find "$mount_point" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

###############################################################################
# Disk-image mounting and recursion
###############################################################################

process_mounted_volume() {
    local mount_point="$1"
    local depth="$2"
    local app package nested_image

    ui_set_status "Inspecting mounted volume" "$mount_point"
    log INFO "Mounted volume ready: $CURRENT_IMAGE"
    log_detail "Mounted volume path: $mount_point"

    # Explicitly report and ignore packages below the root of the mounted image.
    report_ignored_nested_packages "$mount_point"

    # Install app bundles found in the image. The find expression prunes each app
    # after finding it, so helper apps inside another app are not treated as
    # separate applications.
    while IFS= read -r -d '' app; do
        install_app_bundle "$app" || true
    done < <(/usr/bin/find "$mount_point" -xdev \
        \( -type d \( -name '.Trashes' -o -name '.Spotlight-V100' -o -name '.fseventsd' -o -name '.background' -o -iname '*.pkg' -o -iname '*.mpkg' \) -prune \) -o \
        \( -type d -iname '*.app' -print0 -prune \) \
        2>/dev/null)

    # Only root-level packages are eligible. Package bundles in ordinary
    # subfolders were intentionally ignored above.
    while IFS= read -r -d '' package; do
        install_root_package "$package" || true
    done < <(/usr/bin/find "$mount_point" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) \
        \( -iname '*.pkg' -o -iname '*.mpkg' \) -print0 2>/dev/null)

    # Recursively process nested disk images, but do not search inside app or
    # package bundles for hidden payloads. The progress total grows when a nested
    # image is discovered, so the denominator remains honest during recursion.
    while IFS= read -r -d '' nested_image; do
        process_disk_image "$nested_image" $((depth + 1)) 0 || true
    done < <(/usr/bin/find "$mount_point" -xdev \
        \( -type d \( -iname '*.app' -o -iname '*.pkg' -o -iname '*.mpkg' \) -prune \) -o \
        \( -type f \( -iname '*.dmg' -o -iname '*.iso' \) -print0 \) \
        2>/dev/null)
}

restore_parent_ui_context() {
    local previous_image="$1"
    local previous_depth="$2"
    local previous_phase="$3"
    local previous_detail="$4"
    local current_depth="$5"

    if [ "$current_depth" -gt 0 ]; then
        CURRENT_IMAGE="$previous_image"
        CURRENT_DEPTH="$previous_depth"
        CURRENT_PHASE="$previous_phase"
        CURRENT_DETAIL="$previous_detail"
        ui_render
    fi
}

complete_image_progress() {
    IMAGE_COMPLETED_COUNT=$((IMAGE_COMPLETED_COUNT + 1))
    [ "$IMAGE_COMPLETED_COUNT" -le "$IMAGE_TOTAL_KNOWN" ] || \
        IMAGE_TOTAL_KNOWN="$IMAGE_COMPLETED_COUNT"
    ui_render
}

process_disk_image() {
    local image="$1"
    local depth="$2"
    local precounted="${3-0}"
    local canonical plist_file i entity mount_point image_name dev_entry attach_device=""
    local previous_image="$CURRENT_IMAGE"
    local previous_depth="$CURRENT_DEPTH"
    local previous_phase="$CURRENT_PHASE"
    local previous_detail="$CURRENT_DETAIL"
    # A sentinel keeps this array bound under the macOS-supplied Bash 3.2.
    local mount_points=("")
    local mount_count=0

    image_name="$(/usr/bin/basename "$image")"
    if [ "$precounted" -eq 0 ]; then
        IMAGE_TOTAL_KNOWN=$((IMAGE_TOTAL_KNOWN + 1))
    fi
    ui_set_current "$image_name" "$depth"

    if [ "$depth" -gt "$MAX_IMAGE_DEPTH" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        ui_set_status "Skipping disk image" "Maximum nested depth is $MAX_IMAGE_DEPTH"
        log WARN "Maximum nested-image depth reached; skipped: $image"
        complete_image_progress
        restore_parent_ui_context "$previous_image" "$previous_depth" "$previous_phase" "$previous_detail" "$depth"
        return 0
    fi

    if [ ! -f "$image" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        ui_set_status "Skipping disk image" "File is no longer available"
        log WARN "Disk image no longer exists; skipped: $image"
        complete_image_progress
        restore_parent_ui_context "$previous_image" "$previous_depth" "$previous_phase" "$previous_detail" "$depth"
        return 0
    fi

    canonical="$(canonical_path "$image")"
    if /usr/bin/grep -Fqx "$canonical" "$SEEN_IMAGE_FILE" 2>/dev/null; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        ui_set_status "Skipping duplicate image" "$canonical"
        log INFO "Already processed this disk image during the current run: $canonical"
        complete_image_progress
        restore_parent_ui_context "$previous_image" "$previous_depth" "$previous_phase" "$previous_detail" "$depth"
        return 0
    fi
    printf '%s\n' "$canonical" >> "$SEEN_IMAGE_FILE"

    IMAGE_COUNT=$((IMAGE_COUNT + 1))
    ui_set_status "Mounting disk image" "$canonical"
    log ACTION "Mounting image $IMAGE_COUNT/$IMAGE_TOTAL_KNOWN (depth $depth): $image_name"
    log_detail "Disk image path: $canonical"

    plist_file="$(/usr/bin/mktemp "$WORK_ROOT/hdiutil.plist.XXXXXX")"
    if ! /usr/bin/hdiutil attach -readonly -nobrowse -noautoopen \
        -mountrandom "$MOUNT_ROOT" -plist "$canonical" \
        < /dev/null > "$plist_file" 2>> "$LOG_FILE"; then
        /bin/rm -f "$plist_file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        ui_set_status "Mount failed" "$canonical"
        log ERROR "Could not mount disk image: $image_name"
        complete_image_progress
        restore_parent_ui_context "$previous_image" "$previous_depth" "$previous_phase" "$previous_detail" "$depth"
        return 1
    fi

    for ((i=0; i<64; i++)); do
        if ! entity="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$i" "$plist_file" 2>/dev/null)"; then
            break
        fi
        dev_entry="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$i:dev-entry" "$plist_file" 2>/dev/null || true)"
        if [ -z "$attach_device" ] && [ -n "$dev_entry" ]; then
            attach_device="$dev_entry"
        fi
        mount_point="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$i:mount-point" "$plist_file" 2>/dev/null || true)"
        if [ -n "$mount_point" ] && [ -d "$mount_point" ]; then
            mount_points+=("$mount_point")
            mount_count=$((mount_count + 1))
            MOUNTED_POINTS+=("$mount_point")
        fi
    done
    /bin/rm -f "$plist_file"

    if [ "$mount_count" -eq 0 ]; then
        if [ -n "$attach_device" ]; then
            /usr/bin/hdiutil detach -quiet "$attach_device" >> "$LOG_FILE" 2>&1 || \
                /usr/bin/hdiutil detach -force -quiet "$attach_device" >> "$LOG_FILE" 2>&1 || true
        fi
        FAILED_COUNT=$((FAILED_COUNT + 1))
        ui_set_status "Mount produced no volume" "$image_name"
        log ERROR "Disk image mounted but exposed no filesystem volume: $image_name"
        complete_image_progress
        restore_parent_ui_context "$previous_image" "$previous_depth" "$previous_phase" "$previous_detail" "$depth"
        return 1
    fi

    for mount_point in "${mount_points[@]}"; do
        [ -n "$mount_point" ] || continue
        process_mounted_volume "$mount_point" "$depth"
    done

    # A nested image temporarily replaces the current UI context. Restore this
    # image before showing the detach phase.
    ui_set_current "$image_name" "$depth"
    ui_set_status "Detaching disk image" "$image_name"
    for ((i=${#mount_points[@]}-1; i>=1; i--)); do
        mount_point="${mount_points[$i]}"
        [ -n "$mount_point" ] || continue
        if /usr/bin/hdiutil detach -quiet "$mount_point" >> "$LOG_FILE" 2>&1; then
            remove_mounted_point_from_list "$mount_point"
        elif /usr/bin/hdiutil detach -force -quiet "$mount_point" >> "$LOG_FILE" 2>&1; then
            remove_mounted_point_from_list "$mount_point"
        else
            log WARN "Could not detach mounted volume; cleanup will retry: $mount_point"
        fi
    done

    complete_image_progress
    ui_set_status "Disk image complete" "$image_name"
    log OK "Completed image: $image_name"
    restore_parent_ui_context "$previous_image" "$previous_depth" "$previous_phase" "$previous_detail" "$depth"
    return 0
}

###############################################################################
# Main scan
###############################################################################

ui_set_status "Scanning watch folder" "$WATCH_FOLDER"
log ACTION "Scanning for DMG and ISO files in: $WATCH_FOLDER"
if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "Dry-run mode is enabled; no installations will be performed."
else
    log WARN "Live mode is enabled; eligible applications and packages will be installed."
fi

# Capture the initial work list once. Nested images discovered inside mounted
# images are added dynamically by process_disk_image.
if ! /usr/bin/find "$WATCH_FOLDER" \
    \( -type d \( -name '.Trashes' -o -name '.Spotlight-V100' -o -name '.fseventsd' -o -iname '*.app' -o -iname '*.pkg' -o -iname '*.mpkg' \) -prune \) -o \
    \( -type f \( -iname '*.dmg' -o -iname '*.iso' \) -print0 \) \
    > "$TOP_LEVEL_IMAGES_FILE" 2>> "$LOG_FILE"; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    log ERROR "The watch folder could not be scanned completely."
fi

while IFS= read -r -d '' image; do
    IMAGE_TOTAL_KNOWN=$((IMAGE_TOTAL_KNOWN + 1))
done < "$TOP_LEVEL_IMAGES_FILE"
ui_render

if [ "$IMAGE_TOTAL_KNOWN" -eq 0 ]; then
    CURRENT_IMAGE="No disk images found"
    CURRENT_PHASE="Nothing to process"
    CURRENT_DETAIL="$WATCH_FOLDER"
    log WARN "No DMG or ISO files were found."
else
    log INFO "Initial queue: $IMAGE_TOTAL_KNOWN disk image(s). Nested images will be added automatically."

    while IFS= read -r -d '' image; do
        process_disk_image "$image" 0 1 || true
    done < "$TOP_LEVEL_IMAGES_FILE"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log OK "Dry-run summary: images $IMAGE_COMPLETED_COUNT/$IMAGE_TOTAL_KNOWN; apps planned $APP_PLANNED_COUNT; packages planned $PKG_PLANNED_COUNT; skipped $SKIPPED_COUNT; failures $FAILED_COUNT"
else
    log OK "Install summary: images $IMAGE_COMPLETED_COUNT/$IMAGE_TOTAL_KNOWN; apps installed $APP_INSTALLED_COUNT; packages installed $PKG_INSTALLED_COUNT; skipped $SKIPPED_COUNT; failures $FAILED_COUNT"
fi
log INFO "Full log: $LOG_FILE"

ui_finish
RUN_FINISHED=1

if [ "$FAILED_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
