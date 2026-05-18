#!/bin/sh
# =============================================================================
# Shader Installer Pak for NextUI
# Browses and installs single-pass GLSL shaders from:
#   - SkyWalker541/PT-SkyWalker541 (GitHub)
#   - libretro/glsl-shaders (GitHub)
# Converts .glslp -> .cfg for minarch/NextUI compatibility
# Cache format: name|glsl_url|glslp_url|source|category|last_commit_date
# =============================================================================

PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"

PLATFORM="${PLATFORM:-tg5040}"
SDCARD_PATH="${SDCARD_PATH:-/mnt/SDCARD}"
if [ "$PLATFORM" = "tg3040" ]; then PLATFORM="tg5040"; fi

SHADERS_DIR="$SDCARD_PATH/Shaders"
GLSL_DIR="$SHADERS_DIR/glsl"
USERDATA_DIR="$SDCARD_PATH/.userdata/shared/$PAK_NAME"
CACHE_DIR="$USERDATA_DIR/cache"
SHADER_LIST_FILE="$CACHE_DIR/shader_list.txt"
INSTALLED_DIR="$CACHE_DIR/installed"
TOKEN_FILE="$USERDATA_DIR/github_token.txt"
LOG_FILE="$SDCARD_PATH/Logs/$PAK_NAME.txt"
TMP_DIR="/tmp/$PAK_NAME"
MINUI_OUT="$TMP_DIR/minui-output"

LIBRETRO_TREE_API="https://api.github.com/repos/libretro/glsl-shaders/git/trees/master?recursive=1"
LIBRETRO_COMMITS_API="https://api.github.com/repos/libretro/glsl-shaders/commits?per_page=1&path="
LIBRETRO_RAW="https://raw.githubusercontent.com/libretro/glsl-shaders/master"
SKYWALKER_TREE_API="https://api.github.com/repos/SkyWalker541/PT-SkyWalker541/git/trees/main?recursive=1"
SKYWALKER_COMMITS_API="https://api.github.com/repos/SkyWalker541/PT-SkyWalker541/commits?per_page=1&path="
SKYWALKER_RAW="https://raw.githubusercontent.com/SkyWalker541/PT-SkyWalker541/main"

export PATH="$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"

mkdir -p "$CACHE_DIR" "$SHADERS_DIR" "$GLSL_DIR" "$TMP_DIR" "$INSTALLED_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
exec 2>>"$LOG_FILE"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# GitHub token — load on startup, use in all API calls
# Sets GITHUB_TOKEN if available, empty otherwise
# ---------------------------------------------------------------------------
GITHUB_TOKEN=""
if [ -f "$TOKEN_FILE" ]; then
    GITHUB_TOKEN="$(tr -d ' \t\n\r' < "$TOKEN_FILE")"
    if [ -n "$GITHUB_TOKEN" ]; then
        log "GitHub token loaded"
    else
        GITHUB_TOKEN=""
        log "Token file empty — using unauthenticated"
    fi
else
    log "No token file — using unauthenticated requests"
fi

# Single curl wrapper that adds auth header when token is available
# Usage: api_curl <url>
api_curl() {
    if [ -n "$GITHUB_TOKEN" ]; then
        curl --insecure -s --max-time 15 \
            -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
    else
        curl --insecure -s --max-time 15 "$1"
    fi
}

# Standard curl for raw file downloads (no auth needed for public raw content)
raw_curl() {
    curl --insecure -s --max-time 15 "$@"
}

log "=== Shader Installer started (platform: $PLATFORM) ==="

# ---------------------------------------------------------------------------
# URL-encode spaces in a path
# ---------------------------------------------------------------------------
urlencode_path() {
    echo "$1" | sed 's/ /%20/g'
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
show_message() {
    MSG="$(printf '%b' "$1")"; SECS="$2"
    if [ -z "$SECS" ]; then SECS="forever"; fi
    killall minui-presenter >/dev/null 2>&1 || true
    if [ "$SECS" = "forever" ]; then
        minui-presenter --message "$MSG" --timeout -1 &
    else
        minui-presenter --message "$MSG" --timeout "$SECS"
    fi
}

run_list() {
    TITLE="$1"; ITEMS="$2"
    rm -f "$MINUI_OUT"
    killall minui-presenter >/dev/null 2>&1 || true
    echo "$ITEMS" | minui-list \
        --disable-auto-sleep \
        --format text \
        --file - \
        --title "$TITLE" \
        --write-value state \
        --write-location "$MINUI_OUT" \
        >/dev/null 2>&1
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ] && [ -f "$MINUI_OUT" ]; then
        jq -r '.selected' "$MINUI_OUT" 2>/dev/null || echo "-1"
    else
        echo "-1"
    fi
    return $EXIT_CODE
}

# ---------------------------------------------------------------------------
# GitHub rate limit detection
# Returns 0 if response is a rate limit error, 1 if OK
# ---------------------------------------------------------------------------
is_rate_limited() {
    echo "$1" | grep -qi "rate limit\|api rate\|secondary rate\|403 forbidden" && return 0
    # Also check if message field exists but no path field (error response)
    if echo "$1" | grep -q '"message"' && ! echo "$1" | grep -q '"path"'; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Show token setup instructions
# ---------------------------------------------------------------------------
show_token_setup() {
    killall minui-presenter >/dev/null 2>&1 || true
    log "Showing token setup instructions"

    IDX="$(run_list "GitHub Rate Limit Hit" \
        "$(printf 'View Setup Instructions\nDismiss')")"

    if [ "$IDX" = "0" ]; then
        show_message "GitHub API limit reached.\nA free token fixes this.\n\n1. Go to github.com\n2. Profile > Settings\n3. Developer settings\n4. Personal access tokens\n5. Tokens (classic)\n6. Generate new token\n7. Name: Shader Installer\n8. No scopes needed\n9. Generate and copy token\n10. On SD card, create file:\n.userdata/shared/\n$PAK_NAME/github_token.txt\n11. Paste token in that file\n12. Relaunch Shader Installer"
        run_list "GitHub Token Setup" \
            "$(printf 'OK, I will set this up\nDismiss')" > /dev/null 2>&1
        killall minui-presenter >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Network check
# ---------------------------------------------------------------------------
check_network() {
    WLAN_STATE="$(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    if [ "$WLAN_STATE" != "up" ]; then
        show_message "WiFi is not connected.\nPlease connect to WiFi\nand try again." 3
        log "WiFi not up"; return 1
    fi
    IP_ADDR="$(ip addr show wlan0 2>/dev/null | grep 'inet ' | \
        awk '{print $2}' | cut -d'/' -f1)"
    if [ -z "$IP_ADDR" ]; then
        show_message "WiFi has no IP address.\nPlease check your connection." 3
        log "WiFi up but no IP"; return 1
    fi
    log "Network OK — IP: $IP_ADDR"
    return 0
}

# ---------------------------------------------------------------------------
# Resolve relative path
# ---------------------------------------------------------------------------
resolve_path() {
    BASE="$1"; REL="$2"
    case "$REL" in
        /*) echo "$REL"; return ;;
        ./*) REL="${REL#./}" ;;
    esac
    echo "$BASE/$REL" | awk '{
        n=split($0,a,"/"); out=""
        for(i=1;i<=n;i++){
            if(a[i]==".."){sub(/\/[^\/]*$/,"",out)}
            else if(a[i]!="."&&a[i]!=""){out=out"/"a[i]}
        }
        print substr(out,2)
    }'
}

# ---------------------------------------------------------------------------
# Get last commit date for a file
# $1=commits API base  $2=file path (not encoded)
# ---------------------------------------------------------------------------
get_commit_date() {
    COMMITS_API="$1"; FILE_PATH="$2"
    ENCODED="$(urlencode_path "$FILE_PATH")"
    RESPONSE="$(api_curl "${COMMITS_API}${ENCODED}")"
    if [ -z "$RESPONSE" ]; then echo ""; return; fi
    DATE="$(echo "$RESPONSE" | jq -r '.[0].commit.author.date' 2>/dev/null | cut -c1-10)"
    if [ -z "$DATE" ] || [ "$DATE" = "null" ]; then
        DATE="$(echo "$RESPONSE" | awk '
            /"date":/ {
                gsub(/^[^"]*"date"[^"]*"/, "")
                gsub(/T.*/, "")
                if (length($0) == 10) { print $0; exit }
            }
        ')"
    fi
    log "Commit date for $FILE_PATH: [$DATE]"
    echo "$DATE"
}

# ---------------------------------------------------------------------------
# Fetch and cache shaders from one repo
# $1=TREE_API  $2=COMMITS_API  $3=RAW_BASE  $4=SOURCE_LABEL
# ---------------------------------------------------------------------------
fetch_repo_tree() {
    TREE_API="$1"; COMMITS_API="$2"; RAW_BASE="$3"; SOURCE_LABEL="$4"

    log "Fetching tree: $TREE_API"
    TREE="$(api_curl "$TREE_API")"

    if [ -z "$TREE" ]; then
        log "Empty response for $SOURCE_LABEL tree"
        return 1
    fi

    if is_rate_limited "$TREE"; then
        log "Rate limited fetching tree for $SOURCE_LABEL"
        show_token_setup
        return 1
    fi

    GLSLP_PATHS="$(echo "$TREE" | awk '
        /"path":/ {
            gsub(/^[^"]*"path"[^"]*"/, "")
            gsub(/".*/, "")
            if ($0 ~ /\.glslp$/) print $0
        }
    ')"

    if [ -z "$GLSLP_PATHS" ]; then
        log "No .glslp files for $SOURCE_LABEL"
        return 1
    fi

    TOTAL="$(echo "$GLSLP_PATHS" | wc -l | tr -d ' ')"
    log "Found $TOTAL .glslp files in $SOURCE_LABEL — fetching single-pass only..."

    echo "$GLSLP_PATHS" | while IFS= read -r GLSLP_PATH; do
        FNAME="$(basename "$GLSLP_PATH")"
        ENCODED_PATH="$(urlencode_path "$GLSLP_PATH")"
        GLSLP_URL="$RAW_BASE/$ENCODED_PATH"

        GLSLP_CONTENT="$(raw_curl "$GLSLP_URL")"
        if [ -z "$GLSLP_CONTENT" ]; then
            log "Could not fetch: $GLSLP_URL"; continue
        fi

        SHADER_COUNT="$(echo "$GLSLP_CONTENT" | \
            grep -E '^shaders[ \t]*=' | \
            sed 's/.*=[ \t]*//' | tr -d ' \r\n')"

        if [ -z "$SHADER_COUNT" ]; then
            log "No shaders= line: $FNAME"; continue
        fi

        if [ "$SHADER_COUNT" != "1" ]; then
            log "Skip multipass: $FNAME"; continue
        fi

        GLSL_REL="$(echo "$GLSLP_CONTENT" | \
            grep -E '^shader0[ \t]*=' | \
            sed 's/.*=[ \t]*//' | tr -d ' \r\n')"
        if [ -z "$GLSL_REL" ]; then
            log "No shader0: $FNAME"; continue
        fi

        GLSLP_DIR="$(dirname "$GLSLP_PATH")"
        GLSL_ABS="$(resolve_path "$GLSLP_DIR" "$GLSL_REL")"
        GLSL_URL="$RAW_BASE/$(urlencode_path "$GLSL_ABS")"

        DEPTH="$(echo "$GLSLP_PATH" | awk -F'/' '{print NF}')"
        if [ "$DEPTH" -le 1 ]; then
            CATEGORY="misc"
        else
            CATEGORY="$(echo "$GLSLP_PATH" | cut -d'/' -f1)"
        fi

        DISPLAY_NAME="${FNAME%.glslp}"

        if grep -q "^${DISPLAY_NAME}|" "$SHADER_LIST_FILE" 2>/dev/null; then
            log "Duplicate: $DISPLAY_NAME"; continue
        fi

        # Fetch commit date via authenticated API
        COMMIT_DATE="$(get_commit_date "$COMMITS_API" "$GLSLP_PATH")"
        [ -z "$COMMIT_DATE" ] && COMMIT_DATE="unknown"

        printf '%s|%s|%s|%s|%s|%s\n' \
            "$DISPLAY_NAME" "$GLSL_URL" "$GLSLP_URL" \
            "$SOURCE_LABEL" "$CATEGORY" "$COMMIT_DATE" \
            >> "$SHADER_LIST_FILE"

        log "Added [$SOURCE_LABEL/$CATEGORY] $DISPLAY_NAME ($COMMIT_DATE)"
    done
}

# ---------------------------------------------------------------------------
# Build full shader list
# ---------------------------------------------------------------------------
build_shader_list() {
    if ! check_network; then return 1; fi
    : > "$SHADER_LIST_FILE"

    show_message "Building shader cache...\nFetching shaders and update info\nfrom libretro and SkyWalker541.\nThis may take 5-6 minutes.\nOnly required on first run."

    fetch_repo_tree \
        "$SKYWALKER_TREE_API" "$SKYWALKER_COMMITS_API" \
        "$SKYWALKER_RAW" "SkyWalker541"

    fetch_repo_tree \
        "$LIBRETRO_TREE_API" "$LIBRETRO_COMMITS_API" \
        "$LIBRETRO_RAW" "libretro shaders"

    killall minui-presenter >/dev/null 2>&1 || true

    COUNT="$(wc -l < "$SHADER_LIST_FILE" 2>/dev/null | tr -d ' ')"
    log "List complete: $COUNT single-pass shaders"

    if [ "${COUNT:-0}" -eq 0 ]; then
        show_message "No shaders found.\nCheck WiFi and try again." 3
        return 1
    fi
    show_message "Found $COUNT shaders!" 2
    return 0
}

# ---------------------------------------------------------------------------
# Convert .glslp -> minarch .cfg
# ---------------------------------------------------------------------------
convert_glslp_to_cfg() {
    GLSLP_CONTENT="$1"; GLSL_FILENAME="$2"
    FILTER_LINEAR="$(echo "$GLSLP_CONTENT" | \
        grep -E '^filter_linear0[ \t]*=' | \
        sed 's/.*=[ \t]*//' | tr -d ' \r\n' | tr '[:upper:]' '[:lower:]')"
    [ "$FILTER_LINEAR" = "true" ] && FILTER="LINEAR" || FILTER="NEAREST"
    cat <<EOF
minarch_nrofshaders = 1
minarch_shader1 = $GLSL_FILENAME
minarch_shader1_filter = $FILTER
minarch_shader1_srctype = source
minarch_shader1_scaletype = source
minarch_shader1_upscale = screen
EOF
}

# ---------------------------------------------------------------------------
# Save/load installed date
# ---------------------------------------------------------------------------
save_installed_date() {
    date '+%Y-%m-%d' > "$INSTALLED_DIR/$1.date"
}

get_installed_date() {
    [ -f "$INSTALLED_DIR/$1.date" ] && cat "$INSTALLED_DIR/$1.date" || echo "unknown"
}

# ---------------------------------------------------------------------------
# Install a shader
# $1=name  $2=glsl_url  $3=glslp_url
# ---------------------------------------------------------------------------
install_shader() {
    DISPLAY_NAME="$1"; GLSL_URL="$2"; GLSLP_URL="$3"

    GLSL_FILENAME="$DISPLAY_NAME.glsl"
    CFG_DEST="$SHADERS_DIR/$DISPLAY_NAME.cfg"
    GLSL_DEST="$GLSL_DIR/$GLSL_FILENAME"
    TMP_GLSL="$TMP_DIR/shader.glsl"
    TMP_GLSLP="$TMP_DIR/shader.glslp"

    show_message "Downloading\n$DISPLAY_NAME..."

    log "Downloading GLSLP: $GLSLP_URL"
    if ! raw_curl "$GLSLP_URL" -o "$TMP_GLSLP" 2>/dev/null; then
        show_message "Download failed.\nCheck Logs/$PAK_NAME.txt" 3
        log "FAILED: $GLSLP_URL"; return 1
    fi

    log "Downloading GLSL: $GLSL_URL"
    if ! raw_curl "$GLSL_URL" -o "$TMP_GLSL" 2>/dev/null; then
        show_message "Download failed.\nCheck Logs/$PAK_NAME.txt" 3
        log "FAILED: $GLSL_URL"
        rm -f "$TMP_GLSLP"; return 1
    fi

    show_message "Installing $DISPLAY_NAME..."
    GLSLP_CONTENT="$(cat "$TMP_GLSLP")"
    convert_glslp_to_cfg "$GLSLP_CONTENT" "$GLSL_FILENAME" > "$CFG_DEST"
    mv "$TMP_GLSL" "$GLSL_DEST"
    rm -f "$TMP_GLSLP"

    save_installed_date "$DISPLAY_NAME"
    killall minui-presenter >/dev/null 2>&1 || true
    log "Installed: $CFG_DEST + $GLSL_DEST"
    show_message "$DISPLAY_NAME\ninstalled successfully!" 2
    return 0
}

# ---------------------------------------------------------------------------
# Confirm and install flow
# ---------------------------------------------------------------------------
confirm_install() {
    DISPLAY_NAME="$1"; GLSL_URL="$2"; GLSLP_URL="$3"

    CFG_DEST="$SHADERS_DIR/$DISPLAY_NAME.cfg"
    GLSL_DEST="$GLSL_DIR/$DISPLAY_NAME.glsl"

    if [ -f "$CFG_DEST" ] || [ -f "$GLSL_DEST" ]; then
        IDX="$(run_list "$DISPLAY_NAME already installed?" \
            "$(printf 'Reinstall\nCancel')")"
        [ $? -ne 0 ] && return
        [ "$IDX" != "0" ] && return
    else
        IDX="$(run_list "Install $DISPLAY_NAME?" \
            "$(printf 'Install\nCancel')")"
        [ $? -ne 0 ] && return
        [ "$IDX" != "0" ] && return
    fi

    install_shader "$DISPLAY_NAME" "$GLSL_URL" "$GLSLP_URL"
}

# ---------------------------------------------------------------------------
# Browse: Source -> Category -> Shader list
# ---------------------------------------------------------------------------
browse_shader_list() {
    SOURCE="$1"; CATEGORY="$2"

    ENTRIES="$(grep "|${SOURCE}|${CATEGORY}|" \
        "$SHADER_LIST_FILE" 2>/dev/null | sort)"

    if [ -z "$ENTRIES" ]; then
        show_message "No shaders in this category." 2; return
    fi

    NAMES="$(echo "$ENTRIES" | cut -d'|' -f1)"

    while true; do
        IDX="$(run_list "$CATEGORY" "$NAMES")"
        [ $? -ne 0 ] && return
        [ "$IDX" = "-1" ] && return

        LINE=$((IDX + 1))
        ENTRY="$(echo "$ENTRIES" | sed -n "${LINE}p")"
        [ -z "$ENTRY" ] && return

        confirm_install \
            "$(echo "$ENTRY" | cut -d'|' -f1)" \
            "$(echo "$ENTRY" | cut -d'|' -f2)" \
            "$(echo "$ENTRY" | cut -d'|' -f3)"
    done
}

browse_categories() {
    SOURCE="$1"

    CATEGORIES="$(grep "|${SOURCE}|" "$SHADER_LIST_FILE" \
        2>/dev/null | cut -d'|' -f5 | sort -u)"

    if [ -z "$CATEGORIES" ]; then
        show_message "No shaders found for $SOURCE." 2; return
    fi

    DISPLAY_CATS="$(echo "$CATEGORIES" | while IFS= read -r CAT; do
        CNT="$(grep "|${SOURCE}|${CAT}|" \
            "$SHADER_LIST_FILE" | wc -l | tr -d ' ')"
        echo "$CAT ($CNT)"
    done)"

    while true; do
        IDX="$(run_list "$SOURCE" "$DISPLAY_CATS")"
        [ $? -ne 0 ] && return
        [ "$IDX" = "-1" ] && return

        LINE=$((IDX + 1))
        SELECTED="$(echo "$DISPLAY_CATS" | sed -n "${LINE}p")"
        CATEGORY="$(echo "$SELECTED" | sed 's/ ([0-9]*)$//')"
        browse_shader_list "$SOURCE" "$CATEGORY"
    done
}

browse_sources() {
    if ! ensure_shader_list; then return; fi

    SKYWALKER_CNT="$(grep "|SkyWalker541|" "$SHADER_LIST_FILE" \
        2>/dev/null | wc -l | tr -d ' ')"
    LIBRETRO_CNT="$(grep "|libretro shaders|" "$SHADER_LIST_FILE" \
        2>/dev/null | wc -l | tr -d ' ')"

    ITEMS=""
    [ "$SKYWALKER_CNT" -gt 0 ] && \
        ITEMS="SkyWalker541 ($SKYWALKER_CNT)"
    [ "$LIBRETRO_CNT"  -gt 0 ] && \
        ITEMS="$(printf '%s\nlibretro shaders (%s)' "$ITEMS" "$LIBRETRO_CNT")"
    ITEMS="$(echo "$ITEMS" | sed '/^$/d')"

    while true; do
        IDX="$(run_list "Browse Shaders" "$ITEMS")"
        [ $? -ne 0 ] && return
        [ "$IDX" = "-1" ] && return

        LINE=$((IDX + 1))
        SELECTED="$(echo "$ITEMS" | sed -n "${LINE}p")"
        case "$SELECTED" in
            SkyWalker541*)       browse_categories "SkyWalker541"     ;;
            "libretro shaders"*) browse_categories "libretro shaders" ;;
        esac
    done
}

ensure_shader_list() {
    if [ ! -s "$SHADER_LIST_FILE" ]; then
        if ! build_shader_list; then return 1; fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Check for update on a specific shader
# ---------------------------------------------------------------------------
check_for_update() {
    DISPLAY_NAME="$1"

    ENTRY="$(grep "^${DISPLAY_NAME}|" "$SHADER_LIST_FILE" | head -1)"
    if [ -z "$ENTRY" ]; then
        show_message "$DISPLAY_NAME not found\nin shader list.\nTry refreshing." 3
        return
    fi

    GLSLP_URL="$(echo "$ENTRY" | cut -d'|' -f3)"
    SOURCE="$(echo "$ENTRY"    | cut -d'|' -f4)"
    CACHED_DATE="$(echo "$ENTRY" | cut -d'|' -f6)"
    INSTALLED_DATE="$(get_installed_date "$DISPLAY_NAME")"

    case "$SOURCE" in
        SkyWalker541)       COMMITS_API="$SKYWALKER_COMMITS_API"
                            REPO_RAW="$SKYWALKER_RAW" ;;
        "libretro shaders") COMMITS_API="$LIBRETRO_COMMITS_API"
                            REPO_RAW="$LIBRETRO_RAW" ;;
        *)                  COMMITS_API="$LIBRETRO_COMMITS_API"
                            REPO_RAW="$LIBRETRO_RAW" ;;
    esac

    GLSLP_PATH="$(echo "$GLSLP_URL" | \
        sed "s|${REPO_RAW}/||" | sed 's/%20/ /g')"

    show_message "Checking for updates\nfor $DISPLAY_NAME..."
    CURRENT_DATE="$(get_commit_date "$COMMITS_API" "$GLSLP_PATH")"
    killall minui-presenter >/dev/null 2>&1 || true

    if [ -z "$CURRENT_DATE" ]; then
        show_message "Could not check for updates.\nCheck WiFi and try again." 3
        return
    fi

    log "Update check: $DISPLAY_NAME cached=$CACHED_DATE current=$CURRENT_DATE installed=$INSTALLED_DATE"

    if [ "$CURRENT_DATE" \<= "$INSTALLED_DATE" ] || \
       [ "$CURRENT_DATE" = "$CACHED_DATE" ] && \
       [ "$INSTALLED_DATE" != "unknown" ]; then
        show_message "$DISPLAY_NAME is up to date.\nLast updated: $CURRENT_DATE" 4
    else
        GLSL_URL="$(echo "$ENTRY" | cut -d'|' -f2)"
        IDX="$(run_list "Update available!" \
            "$(printf 'Install Update\nCancel')")"
        [ $? -ne 0 ] && return
        [ "$IDX" != "0" ] && return
        install_shader "$DISPLAY_NAME" "$GLSL_URL" "$GLSLP_URL"

        # Update cached date
        ESCAPED="$(echo "$DISPLAY_NAME" | sed 's/[[\.*^$()+?{|]/\\&/g')"
        sed -i "s/^${ESCAPED}|\(.*\)|${CACHED_DATE}$/${ESCAPED}|\1|${CURRENT_DATE}/" \
            "$SHADER_LIST_FILE" 2>/dev/null || true
        log "Updated cached date: $DISPLAY_NAME -> $CURRENT_DATE"
    fi
}

# ---------------------------------------------------------------------------
# Manage installed shaders
# ---------------------------------------------------------------------------
manage_shaders() {
    while true; do
        INSTALLED="$(ls "$SHADERS_DIR"/*.cfg 2>/dev/null)"
        if [ -z "$INSTALLED" ]; then
            show_message "No shaders installed yet." 2; return
        fi

        NAMES="$(echo "$INSTALLED" | while IFS= read -r CFG_PATH; do
            NAME="$(basename "$CFG_PATH" .cfg)"
            # Read the actual glsl path from the cfg file
            GLSL_REL="$(grep "^minarch_shader1 " "$CFG_PATH" 2>/dev/null |                 sed "s/.*=[ 	]*//" | tr -d " \r\n")"
            if [ -n "$GLSL_REL" ] && [ -f "$SHADERS_DIR/$GLSL_REL" ]; then
                echo "$NAME"
            elif [ -f "$GLSL_DIR/$NAME.glsl" ]; then
                echo "$NAME"
            else
                echo "$NAME (cfg only)"
            fi
        done)"

        IDX="$(run_list "Installed Shaders" "$NAMES")"
        [ $? -ne 0 ] && return
        [ "$IDX" = "-1" ] && return

        LINE=$((IDX + 1))
        SELECTED="$(echo "$NAMES" | sed -n "${LINE}p")"
        REAL_NAME="$(echo "$SELECTED" | sed 's/ (cfg only)$//')"

        while true; do
            ACT_IDX="$(run_list "$REAL_NAME" \
                "$(printf 'Check for Update\nDelete\nCancel')")"
            [ $? -ne 0 ] && break
            [ "$ACT_IDX" = "-1" ] && break

            case "$ACT_IDX" in
                0) check_for_update "$REAL_NAME" ;;
                1)
                    DEL_IDX="$(run_list "Delete $REAL_NAME?" \
                        "$(printf 'Delete\nCancel')")"
                    [ $? -ne 0 ] && continue
                    if [ "$DEL_IDX" = "0" ]; then
                        rm -f "$SHADERS_DIR/$REAL_NAME.cfg"
                        rm -f "$GLSL_DIR/$REAL_NAME.glsl"
                        rm -f "$INSTALLED_DIR/$REAL_NAME.date"
                        log "Deleted: $REAL_NAME"
                        show_message "$REAL_NAME deleted." 2
                        break
                    fi
                    ;;
                2) break ;;
            esac
        done
    done
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    if [ -s "$SHADER_LIST_FILE" ]; then
        COUNT="$(wc -l < "$SHADER_LIST_FILE" | tr -d ' ')"
        TITLE="Shader Installer ($COUNT cached)"
    else
        TITLE="Shader Installer"
    fi

    ITEMS="$(printf 'Browse & Install Shaders\nManage Installed Shaders\nRefresh Shader List\nExit')"

    IDX="$(run_list "$TITLE" "$ITEMS")"
    [ $? -ne 0 ] && return 1
    [ "$IDX" = "-1" ] && return 1

    case "$IDX" in
        0) browse_sources ;;
        1) manage_shaders ;;
        2) rm -f "$SHADER_LIST_FILE"; build_shader_list ;;
        3) return 1 ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    killall minui-presenter >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
    rm -f /tmp/stay_awake
}
trap cleanup EXIT INT TERM HUP QUIT
echo "1" > /tmp/stay_awake

while main_menu; do :; done

log "=== Shader Installer exited ==="
