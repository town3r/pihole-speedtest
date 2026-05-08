#!/usr/bin/env bash
#
# Pi-hole Speedtest installer/manager for this fork.
#

set -euo pipefail

readonly SCRIPT_VERSION="0.2.0-town3r"
readonly WEB_ROOT="/var/www/html/admin"
readonly MOD_DIR="/opt/pihole/speedtestmod"
readonly RUNNER_FILE="$MOD_DIR/speedtest.sh"
readonly WIDGET_FILE="$MOD_DIR/widget.php"
readonly V6_CONTENT="$WEB_ROOT/scripts/pi-hole/php/content.php"
readonly V6_PARTIAL="$WEB_ROOT/scripts/pi-hole/php/box_speedtest.php"
readonly LEGACY_INDEX="$WEB_ROOT/index.php"
readonly MARKER_BEGIN="PIHOLE-SPEEDTEST-BEGIN"
readonly MARKER_END="PIHOLE-SPEEDTEST-END"

help() {
    cat <<'USAGE'
Pi-hole Speedtest installer (town3r fork)

Usage:
  sudo bash mod [options]
  curl -sSL https://github.com/town3r/pihole-speedtest/raw/master/mod | sudo bash -s -- [options]

Options:
  -r, --reinstall     Reinstall/update Speedtest files and UI integration
  -u, --update        Alias of --reinstall
  -n, --uninstall     Remove Speedtest UI integration and installed scripts
  -v, --version       Print installer version
  -h, --help          Show this help
USAGE
}

log() {
    printf '[pihole-speedtest] %s\n' "$*"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run as root (for example: sudo bash mod ...)." >&2
        exit 1
    fi
}

strip_marker_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp=$(mktemp)
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        index($0, b) { skip=1; next }
        index($0, e) { skip=0; next }
        !skip { print }
    ' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

install_dependencies() {
    local installer=""
    local -a missing=()

    command -v apt-get >/dev/null 2>&1 && installer="apt"
    command -v dnf >/dev/null 2>&1 && installer="dnf"
    command -v yum >/dev/null 2>&1 && installer="yum"

    command -v sqlite3 >/dev/null 2>&1 || missing+=(sqlite3)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v curl >/dev/null 2>&1 || missing+=(curl)

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ -z "$installer" ]]; then
        log "Warning: missing dependencies (${missing[*]}) and no supported package manager found."
        return 0
    fi

    log "Installing missing dependencies: ${missing[*]}"
    case "$installer" in
        apt)
            apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
            ;;
        dnf) dnf install -y "${missing[@]}" >/dev/null 2>&1 || true ;;
        yum) yum install -y "${missing[@]}" >/dev/null 2>&1 || true ;;
    esac
}

ensure_speedtest_cli() {
    if [[ -x /usr/bin/speedtest ]]; then
        return 0
    fi

    log "No /usr/bin/speedtest found. Trying to install Ookla speedtest CLI..."
    if command -v apt-get >/dev/null 2>&1; then
        local deb_script
        deb_script=$(mktemp)
        curl -fsSL -o "$deb_script" https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh >/dev/null 2>&1 || true
        [[ -s "$deb_script" ]] && bash "$deb_script" >/dev/null 2>&1 || true
        rm -f "$deb_script"
        apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        local rpm_script
        rpm_script=$(mktemp)
        curl -fsSL -o "$rpm_script" https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh >/dev/null 2>&1 || true
        [[ -s "$rpm_script" ]] && bash "$rpm_script" >/dev/null 2>&1 || true
        rm -f "$rpm_script"
        dnf install -y speedtest >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        local rpm_script
        rpm_script=$(mktemp)
        curl -fsSL -o "$rpm_script" https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh >/dev/null 2>&1 || true
        [[ -s "$rpm_script" ]] && bash "$rpm_script" >/dev/null 2>&1 || true
        rm -f "$rpm_script"
        yum install -y speedtest >/dev/null 2>&1 || true
    fi

    if [[ ! -x /usr/bin/speedtest ]]; then
        log "Warning: speedtest CLI is not installed. Install one manually before running the test script."
    fi
}

install_runner_file() {
    mkdir -p "$MOD_DIR"
    cat >"$RUNNER_FILE" <<'RUNNER'
#!/usr/bin/env bash
# Pi-hole Speedtest runner (town3r fork)
set -euo pipefail

readonly CREATE_TABLE="create table if not exists speedtest (
id integer primary key autoincrement,
start_time text,
stop_time text,
from_server text,
from_ip text,
server text,
server_dist real,
server_ping real,
download real,
upload real,
share_url text
);"

database="/etc/pihole/speedtest.db"
attempts=3
server_id=""

help() {
    cat <<'USAGE'
Pi-hole Speedtest runner

Usage:
  sudo bash /opt/pihole/speedtestmod/speedtest.sh [options]
  curl -sSL https://github.com/town3r/pihole-speedtest/raw/master/test | sudo bash -s -- [options]

Options:
  -s, --server <id>       Speedtest server id
  -l, --list              List available servers
  -o, --output <file>     SQLite database path (default: /etc/pihole/speedtest.db)
  -a, --attempts <n>      Number of attempts (default: 3)
  -h, --help              Show this help
USAGE
}

run_speedtest() {
    if /usr/bin/speedtest --version 2>/dev/null | grep -qi official; then
        if [[ -n "$server_id" ]]; then
            /usr/bin/speedtest -s "$server_id" --accept-gdpr --accept-license -f json
        else
            /usr/bin/speedtest --accept-gdpr --accept-license -f json
        fi
    else
        if [[ -n "$server_id" ]]; then
            /usr/bin/speedtest --server "$server_id" --json --share --secure
        else
            /usr/bin/speedtest --json --share --secure
        fi
    fi
}

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

to_number() {
    local value="$1"
    local fallback="$2"
    if [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf "%s" "$value"
    else
        printf "%s" "$fallback"
    fi
}

parse_and_store() {
    local json_file="$1"
    local start="$2"
    local stop="$3"

    local isp from_ip server_name server_dist server_ping download upload share_url
    isp="No Internet"
    from_ip="-"
    server_name="-"
    server_dist="-1"
    server_ping="0"
    download="0"
    upload="0"
    share_url="#"

    if jq -e '.server' "$json_file" >/dev/null 2>&1; then
        if /usr/bin/speedtest --version 2>/dev/null | grep -qi official; then
            server_name=$(jq -r '.server.name // "-"' "$json_file")
            download=$(jq -r '.download.bandwidth // 0' "$json_file" | awk '{print ($1*8/1000/1000)}')
            upload=$(jq -r '.upload.bandwidth // 0' "$json_file" | awk '{print ($1*8/1000/1000)}')
            isp=$(jq -r '.isp // "No Internet"' "$json_file")
            from_ip=$(jq -r '.interface.externalIp // "-"' "$json_file")
            server_ping=$(jq -r '.ping.latency // 0' "$json_file")
            share_url=$(jq -r '.result.url // "#"' "$json_file")
            server_dist=$(jq -r '.server.distance // -1' "$json_file")
        else
            server_name=$(jq -r '.server.sponsor // "-"' "$json_file")
            download=$(jq -r '.download // 0' "$json_file" | awk '{print ($1/1000/1000)}')
            upload=$(jq -r '.upload // 0' "$json_file" | awk '{print ($1/1000/1000)}')
            isp=$(jq -r '.client.isp // "No Internet"' "$json_file")
            from_ip=$(jq -r '.client.ip // "-"' "$json_file")
            server_ping=$(jq -r '.ping // 0' "$json_file")
            share_url=$(jq -r '.share // "#"' "$json_file")
            server_dist=$(jq -r '.server.d // -1' "$json_file")
        fi
    elif jq -e '.[0].server' "$json_file" >/dev/null 2>&1; then
        server_name=$(jq -r '.[0].server.name // "-"' "$json_file")
        download=$(jq -r '.[0].download // 0' "$json_file")
        upload=$(jq -r '.[0].upload // 0' "$json_file")
        from_ip=$(jq -r '.[0].client.ip // "-"' "$json_file" 2>/dev/null || echo "-")
        server_ping=$(jq -r '.[0].ping // 0' "$json_file")
        share_url=$(jq -r '.[0].share // "#"' "$json_file")
        isp="Unknown"
        server_dist="-1"
    fi

    mkdir -p "$(dirname "$database")"
    local esc_isp esc_from_ip esc_server_name esc_share_url
    esc_isp=$(sql_escape "$isp")
    esc_from_ip=$(sql_escape "$from_ip")
    esc_server_name=$(sql_escape "$server_name")
    esc_share_url=$(sql_escape "$share_url")
    server_dist=$(to_number "$server_dist" "-1")
    server_ping=$(to_number "$server_ping" "0")
    download=$(to_number "$download" "0")
    upload=$(to_number "$upload" "0")

    sqlite3 "$database" "$CREATE_TABLE"
    sqlite3 "$database" "insert into speedtest values (NULL, '${start}', '${stop}', '${esc_isp}', '${esc_from_ip}', '${esc_server_name}', ${server_dist}, ${server_ping}, ${download}, ${upload}, '${esc_share_url}');"
    chmod 640 "$database" 2>/dev/null || true

    if [[ -d /var/log/pihole ]]; then
        cp -f "$json_file" /var/log/pihole/speedtest.log
        cp -f /var/log/pihole/speedtest.log /etc/pihole/speedtest.log 2>/dev/null || true
    fi

    [[ "$isp" != "No Internet" ]]
}

if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root (for example: sudo bash /opt/pihole/speedtestmod/speedtest.sh ...)." >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--server)
            server_id="$2"
            shift 2
            ;;
        -l|--list)
            if [[ ! -x /usr/bin/speedtest ]]; then
                echo "speedtest CLI not found at /usr/bin/speedtest"
                exit 1
            fi
            if /usr/bin/speedtest --version 2>/dev/null | grep -qi official; then
                /usr/bin/speedtest -L
            else
                /usr/bin/speedtest --secure --list
            fi
            exit 0
            ;;
        -o|--output)
            database="$2"
            shift 2
            ;;
        -a|--attempts)
            attempts="$2"
            shift 2
            ;;
        -h|--help)
            help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            help
            exit 1
            ;;
    esac
done

if [[ ! -x /usr/bin/speedtest ]]; then
    echo "speedtest CLI not found at /usr/bin/speedtest"
    echo "Install Ookla speedtest CLI, speedtest-cli, or librespeed-cli first."
    exit 1
fi

if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
    attempts=3
fi

start_time=$(date -u --rfc-3339=seconds)
json_out=$(mktemp)
status=1

for ((i=1; i<=attempts; i++)); do
    if run_speedtest >"$json_out" 2>/dev/null && [[ -s "$json_out" ]] && jq -e . "$json_out" >/dev/null 2>&1; then
        stop_time=$(date -u --rfc-3339=seconds)
        if parse_and_store "$json_out" "$start_time" "$stop_time"; then
            status=0
            break
        fi
    fi
    echo "Attempt $i failed"
    sleep 1
done

rm -f "$json_out"
exit "$status"
RUNNER
    chmod +x "$RUNNER_FILE"
}

install_widget_files() {
    mkdir -p "$MOD_DIR"

    cat >"$WIDGET_FILE" <<'WIDGET'
<?php
$dbPath = '/etc/pihole/speedtest.db';
$lastTest = null;

if (file_exists($dbPath)) {
    try {
        $db = new SQLite3($dbPath, SQLITE3_OPEN_READONLY);
        $result = $db->query('SELECT start_time, from_server, server, server_ping, download, upload, share_url FROM speedtest ORDER BY id DESC LIMIT 1;');
        if ($result !== false) {
            $lastTest = $result->fetchArray(SQLITE3_ASSOC);
        }
        $db->close();
    } catch (Exception $e) {
        $lastTest = null;
    }
}
?>
<div class="col-lg-3 col-sm-6" id="speedtest-box">
    <div class="small-box bg-teal">
        <div class="inner">
            <?php if ($lastTest): ?>
                <h3><?= htmlspecialchars(number_format((float) $lastTest['download'], 2), ENT_QUOTES, 'UTF-8') ?> / <?= htmlspecialchars(number_format((float) $lastTest['upload'], 2), ENT_QUOTES, 'UTF-8') ?></h3>
                <p>Speedtest (Mbps)</p>
                <p>Ping: <?= htmlspecialchars((string) $lastTest['server_ping'], ENT_QUOTES, 'UTF-8') ?> ms</p>
                <p>Server: <?= htmlspecialchars((string) $lastTest['server'], ENT_QUOTES, 'UTF-8') ?></p>
            <?php else: ?>
                <h3>Speedtest</h3>
                <p>No data yet</p>
                <p>Run: <code>sudo bash /opt/pihole/speedtestmod/speedtest.sh</code></p>
            <?php endif; ?>
        </div>
        <div class="icon"><i class="fa fa-tachometer-alt"></i></div>
        <a href="settings.php?tab=piholedhcp" class="small-box-footer">Speedtest database: /etc/pihole/speedtest.db</a>
    </div>
</div>
WIDGET

    mkdir -p "$(dirname "$V6_PARTIAL")"
    cat >"$V6_PARTIAL" <<'V6PARTIAL'
<?php
$widget = '/opt/pihole/speedtestmod/widget.php';
if (file_exists($widget)) {
    include $widget;
}
V6PARTIAL
}

patch_v6_content() {
    [[ -f "$V6_CONTENT" ]] || return 1

    if grep -q "$MARKER_BEGIN" "$V6_CONTENT"; then
        return 0
    fi

    cat >>"$V6_CONTENT" <<'V6BLOCK'

<?php
// PIHOLE-SPEEDTEST-BEGIN
$speedtestWidget = __DIR__ . '/box_speedtest.php';
if (file_exists($speedtestWidget)) {
    include $speedtestWidget;
}
// PIHOLE-SPEEDTEST-END
?>
V6BLOCK

    return 0
}

patch_legacy_index() {
    [[ -f "$LEGACY_INDEX" ]] || return 1

    if grep -q "$MARKER_BEGIN" "$LEGACY_INDEX"; then
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log "Warning: python3 is required to patch legacy index.php layout. Skipping legacy UI patch."
        return 0
    fi

    python3 - "$LEGACY_INDEX" "$MARKER_BEGIN" "$MARKER_END" <<'PY'
import sys
path, begin, end = sys.argv[1:4]
block = f"""
<?php
// {begin}
$widget = '/opt/pihole/speedtestmod/widget.php';
if (file_exists($widget)) {{
    include $widget;
}}
// {end}
?>
""".strip("\n")

with open(path, "r", encoding="utf-8") as f:
    content = f.read()

pos = content.lower().rfind("</body>")
if pos >= 0:
    content = content[:pos] + "\n" + block + "\n" + content[pos:]
else:
    content = content + "\n\n" + block + "\n"

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PY

    return 0
}

install_integration() {
    install_widget_files

    if [[ -f "$V6_CONTENT" && -d "$(dirname "$V6_PARTIAL")" ]]; then
        patch_v6_content
        log "Installed Pi-hole v6 dashboard integration (content.php + box_speedtest.php)."
        return 0
    fi

    if [[ -f "$LEGACY_INDEX" ]]; then
        patch_legacy_index
        log "Installed legacy dashboard integration (index.php fallback)."
        return 0
    fi

    log "Warning: unsupported Pi-hole dashboard layout. Installed runner, but skipped UI patching safely."
    return 0
}

uninstall_all() {
    strip_marker_block "$V6_CONTENT"
    strip_marker_block "$LEGACY_INDEX"
    rm -f "$V6_PARTIAL"
    rm -f "$WIDGET_FILE"
    rm -f "$RUNNER_FILE"
    rmdir "$MOD_DIR" >/dev/null 2>&1 || true
    log "Uninstall complete. Kept /etc/pihole/speedtest.db and log files intact."
}

main() {
    local reinstall=false
    local uninstall=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--reinstall|-u|--update)
                reinstall=true
                ;;
            -n|--uninstall)
                uninstall=true
                ;;
            -v|--version)
                echo "$SCRIPT_VERSION"
                return 0
                ;;
            -h|--help)
                help
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                help
                return 1
                ;;
        esac
        shift
    done

    if $uninstall; then
        uninstall_all
        return 0
    fi

    install_dependencies
    ensure_speedtest_cli
    install_runner_file

    if $reinstall; then
        strip_marker_block "$V6_CONTENT"
        strip_marker_block "$LEGACY_INDEX"
    fi

    install_integration
    log "Installation complete."
    log "Run a test with: sudo bash $RUNNER_FILE"
}

require_root
main "$@"
