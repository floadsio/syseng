#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 [-v] [-k] [-u user] [-i identity_file] <server-node> <client-node>" >&2
  echo "  -v  Verbose output" >&2
  echo "  -k  Skip host key verification (for trusted networks)" >&2
  echo "  -u  SSH user" >&2
  echo "  -i  SSH identity file" >&2
  exit 1
}

VERBOSE=0
SSH_USER=""
SSH_KEY=""
SKIP_HOST_KEY=0

while getopts ":vki:u:" opt; do
  case "$opt" in
    v) VERBOSE=1 ;;
    k) SKIP_HOST_KEY=1 ;;
    u) SSH_USER=$OPTARG ;;
    i) SSH_KEY=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 2 ]; then
  usage
fi

server_node=$1
client_node=$2
server_host=$1
server_job=""
server_log_tailer=""
server_started=0
server_log=$(mktemp /tmp/iperf3-server.XXXXXX)
IPERF_PORT=${IPERF_PORT:-5201}

verbose_log() {
  if [ "$VERBOSE" -eq 1 ]; then
    printf "[verbose] %s\n" "$*"
  fi
}

strip_user() {
  case "$1" in
    *@*)
      printf '%s\n' "${1#*@}"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

format_target() {
  fmt_node=$1
  case "$fmt_node" in
    *@*)
      printf '%s\n' "$fmt_node"
      ;;
    *)
      if [ -n "$SSH_USER" ]; then
        printf '%s@%s\n' "$SSH_USER" "$fmt_node"
      else
        printf '%s\n' "$fmt_node"
      fi
      ;;
  esac
}

ssh_remote() {
  remote_node=$1
  shift
  remote_target=$(format_target "$remote_node")
  if [ "$SKIP_HOST_KEY" -eq 1 ]; then
    ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
  else
    ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
  fi
  if [ -n "$SSH_KEY" ]; then
    ssh $ssh_opts -i "$SSH_KEY" "$remote_target" "$@"
  else
    ssh $ssh_opts "$remote_target" "$@"
  fi
}

# SSH without reading stdin - for use when stdin might interfere
ssh_remote_noinput() {
  remote_node=$1
  shift
  remote_target=$(format_target "$remote_node")
  if [ "$SKIP_HOST_KEY" -eq 1 ]; then
    ssh_opts="-n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
  else
    ssh_opts="-n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
  fi
  if [ -n "$SSH_KEY" ]; then
    ssh $ssh_opts -i "$SSH_KEY" "$remote_target" "$@"
  else
    ssh $ssh_opts "$remote_target" "$@"
  fi
}

is_ipv4() {
  ip=$1
  case "$ip" in
    ''|*[!0-9.]*)
      return 1
      ;;
  esac
  (
    IFS=.
    set -- $ip
    [ "$#" -eq 4 ] || exit 1
    for octet in "$@"; do
      [ -n "$octet" ] || exit 1
      if [ "$octet" -lt 0 ] 2>/dev/null || [ "$octet" -gt 255 ] 2>/dev/null; then
        exit 1
      fi
    done
  )
}

resolve_ip() {
  target=$1
  if is_ipv4 "$target"; then
    printf '%s\n' "$target"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    resolved=$(python3 - "$target" <<'PY'
import socket, sys
target = sys.argv[1]
try:
    infos = socket.getaddrinfo(target, None, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror:
    sys.exit(1)
if infos:
    print(infos[0][4][0])
    sys.exit(0)
sys.exit(1)
PY
)
    if [ -n "${resolved:-}" ]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  if command -v getent >/dev/null 2>&1; then
    resolved=$(getent hosts "$target" | awk 'NR==1 {print $1}')
    if [ -n "${resolved:-}" ] && is_ipv4 "$resolved"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  if command -v host >/dev/null 2>&1; then
    resolved=$(host "$target" 2>/dev/null | awk '/ has address / {print $4; exit}')
    if [ -n "${resolved:-}" ] && is_ipv4 "$resolved"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  echo "Failed to resolve IPv4 address for $target; please ensure it's resolvable locally." >&2
  exit 1
}

# Resolve IP from a remote node's perspective
resolve_ip_from_node() {
  resolve_node=$1
  resolve_target=$2

  if is_ipv4 "$resolve_target"; then
    printf '%s\n' "$resolve_target"
    return 0
  fi

  # Try python3 first (most reliable)
  resolved=$(ssh_remote "$resolve_node" python3 - "$resolve_target" 2>/dev/null <<'PY' || true
import socket, sys
target = sys.argv[1]
try:
    infos = socket.getaddrinfo(target, None, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror:
    sys.exit(1)
if infos:
    print(infos[0][4][0])
    sys.exit(0)
sys.exit(1)
PY
)
  if [ -n "${resolved:-}" ] && is_ipv4 "$resolved"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  # Try getent
  resolved=$(ssh_remote "$resolve_node" "getent hosts '$resolve_target' 2>/dev/null | awk 'NR==1 {print \$1}'" 2>/dev/null || true)
  if [ -n "${resolved:-}" ] && is_ipv4 "$resolved"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  # Try host command
  resolved=$(ssh_remote "$resolve_node" "host '$resolve_target' 2>/dev/null | awk '/ has address / {print \$4; exit}'" 2>/dev/null || true)
  if [ -n "${resolved:-}" ] && is_ipv4 "$resolved"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

server_host=$(strip_user "$server_host")
# server_ip will be resolved after ensuring connectivity to client

stop_server_processes() {
  if [ "${server_started:-0}" -eq 1 ]; then
    stop_existing_server "$server_node" 1  # async mode for cleanup
    server_started=0
  fi
  if [ -n "$server_job" ]; then
    # Kill local SSH process - don't wait as it may hang
    kill "$server_job" 2>/dev/null || true
    kill -9 "$server_job" 2>/dev/null || true
    server_job=""
  fi
  if [ -n "$server_log_tailer" ]; then
    # Kill process group to get pipeline children
    # Suppress job termination messages by redirecting stderr around wait
    {
      kill -9 -"$server_log_tailer" 2>/dev/null || kill -9 "$server_log_tailer" 2>/dev/null || true
      pkill -9 -f "tail -f $server_log" 2>/dev/null || true
      wait "$server_log_tailer" 2>/dev/null || true
    } 2>/dev/null
    server_log_tailer=""
  fi
}

stop_existing_server() {
  node=$1
  async=${2:-0}  # Optional: 1 for async (cleanup), 0 for sync (normal)
  verbose_log "Ensuring iperf3 server port is free on $node"
  _stop_target=$(format_target "$node")
  if [ "$async" -eq 1 ]; then
    # Async mode for cleanup - fire and forget to avoid hanging
    if [ "$SKIP_HOST_KEY" -eq 1 ]; then
      _stop_ssh_opts="-n -f -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=2 -o ServerAliveCountMax=1"
    else
      _stop_ssh_opts="-n -f -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=2 -o ServerAliveCountMax=1"
    fi
    if [ -n "$SSH_KEY" ]; then
      _stop_ssh_opts="$_stop_ssh_opts -i $SSH_KEY"
    fi
    ssh $_stop_ssh_opts "$_stop_target" "pkill iperf3 2>/dev/null; killall iperf3 2>/dev/null; true" 2>/dev/null || true
  else
    # Sync mode - wait for completion before proceeding
    ssh_remote_noinput "$node" "pkill iperf3 2>/dev/null; killall iperf3 2>/dev/null; true" 2>/dev/null || true
  fi
}

ensure_ping() {
  ping_node=$1
  ping_target=$2
  ping_label=$3
  verbose_log "Checking reachability from $ping_node to $ping_label via ping"
  if ssh_remote "$ping_node" "ping -c 1 $ping_target >/dev/null 2>&1"; then
    verbose_log "Ping from $ping_node to $ping_label succeeded"
    return 0
  fi
  echo "Connectivity test failed: cannot ping $ping_label from $ping_node" >&2
  echo "Please verify DNS and basic network reachability between the nodes before running iperf3." >&2
  return 1
}

tcp_precheck() {
  server_node=$1
  client_node=$2
  conn_ip=$3
  conn_label=$4
  conn_port=$5

  if ! ssh_remote "$server_node" "command -v python3 >/dev/null 2>&1"; then
    echo "Python3 is not available on $server_node; skipping TCP connectivity pre-check." >&2
    return 0
  fi

  if ! ssh_remote "$client_node" "command -v python3 >/dev/null 2>&1"; then
    echo "Python3 is not available on $client_node; skipping TCP connectivity pre-check." >&2
    return 0
  fi

  verbose_log "Checking TCP connectivity from $client_node to $conn_label:$conn_port"
  listener_log=$(mktemp /tmp/iperf3-port-check.XXXXXX)

  ssh_remote "$server_node" python3 - "$conn_port" <<'PY' >"$listener_log" 2>&1 &
import socket, sys
port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("", port))
sock.listen(1)
sock.settimeout(10)
try:
    conn, _ = sock.accept()
    conn.close()
    sys.exit(0)
except socket.timeout:
    sys.exit(2)
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
  listener_job=$!

  # Give the listener a brief moment to start.
  sleep 1

  client_status=0
  if ! ssh_remote "$client_node" python3 - "$conn_ip" "$conn_port" <<'PY'; then
import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect((host, port))
    s.close()
    sys.exit(0)
except OSError:
    sys.exit(1)
PY
    client_status=$?
  fi

  # Stop the listener if it's still running, then capture its exit status.
  wait "$listener_job" 2>/dev/null || true
  listener_status=$?

  if [ "$listener_status" -ne 0 ]; then
    if [ -s "$listener_log" ]; then
      sed 's/^/listener: /' "$listener_log" >&2
    fi
    rm -f "$listener_log"
    echo "Temporary TCP listener on $server_node failed (status $listener_status); skipping TCP pre-check." >&2
    return 0
  fi

  rm -f "$listener_log"

  if [ "$client_status" -eq 0 ]; then
    verbose_log "TCP connectivity to $conn_label:$conn_port confirmed"
    return 0
  fi

  echo "TCP connectivity test to $conn_label:$conn_port failed before starting iperf3." >&2
  exit 1
}

ensure_iperf3() {
  node=$1
  verbose_log "Checking iperf3 availability on $node"
  if ssh_remote "$node" "command -v iperf3 >/dev/null 2>&1"; then
    return 0
  fi

  printf "iperf3 not found on %s, attempting installation...\n" "$node"
  if ! ssh_remote "$node" /bin/sh <<'EOS'; then
set -eu

if command -v iperf3 >/dev/null 2>&1; then
  exit 0
fi

if command -v sudo >/dev/null 2>&1; then
  PRIV_CMD="sudo"
elif command -v doas >/dev/null 2>&1; then
  PRIV_CMD="doas"
else
  PRIV_CMD=""
fi

run_priv() {
  if [ -n "$PRIV_CMD" ]; then
    "$PRIV_CMD" "$@"
  else
    "$@"
  fi
}

is_debian_like() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu|linuxmint|elementary|pop|kali|raspbian)
        return 0
        ;;
    esac
    if printf '%s\n' "${ID_LIKE:-}" | grep -Eq '(^|[[:space:]])debian([[:space:]]|$)'; then
      return 0
    fi
  fi
  return 1
}

os=$(uname -s)
case "$os" in
  Linux)
    if is_debian_like && command -v apt-get >/dev/null 2>&1; then
      run_priv apt-get update
      run_priv apt-get install -y iperf3
    else
      echo "Unsupported Linux distribution for automatic iperf3 installation (need Debian-based host)" >&2
      exit 1
    fi
    ;;
  FreeBSD)
    run_priv pkg install -y iperf3
    ;;
  OpenBSD)
    run_priv pkg_add iperf3
    ;;
  *)
    echo "Unsupported operating system: $os" >&2
    exit 1
    ;;
esac
EOS
    echo "Failed to install iperf3 on $node" >&2
    exit 1
  fi
}

cleanup() {
  stop_server_processes
  [ -f "$server_log" ] && rm -f "$server_log"
}

trap cleanup INT TERM EXIT

ensure_iperf3 "$server_node"
ensure_iperf3 "$client_node"

# Resolve server IP from client's perspective (since client needs to connect)
verbose_log "Resolving $server_host from $client_node's perspective..."
if server_ip=$(resolve_ip_from_node "$client_node" "$server_host"); then
  verbose_log "Client resolved $server_host to $server_ip"
else
  verbose_log "Client could not resolve $server_host, falling back to local resolution"
  if server_ip=$(resolve_ip "$server_host"); then
    verbose_log "Locally resolved $server_host to $server_ip"
    printf "Warning: Using locally-resolved IP %s (client could not resolve %s)\n" "$server_ip" "$server_host" >&2
  else
    echo "Failed to resolve $server_host from either client or locally" >&2
    exit 1
  fi
fi

ensure_ping "$client_node" "$server_ip" "$server_host ($server_ip)"
tcp_precheck "$server_node" "$client_node" "$server_ip" "$server_host ($server_ip)" "$IPERF_PORT"

printf "Starting iperf3 server on %s...\n" "$server_node"
stop_existing_server "$server_node"
ssh_remote "$server_node" iperf3 -s -1 >"$server_log" 2>&1 &
server_job=$!
server_started=1
if [ "$VERBOSE" -eq 1 ]; then
  verbose_log "Streaming server output..."
  # Run in subshell so we can kill entire pipeline
  # Disable job control to suppress "Killed" message on cleanup
  set +m
  (tail -f "$server_log" 2>/dev/null | sed 's/^/server: /') &
  server_log_tailer=$!
fi

sleep 2

printf "Running iperf3 client from %s against %s (%s)...\n" "$client_node" "$server_node" "$server_ip"

if ssh_remote "$client_node" iperf3 -c "$server_ip" --connect-timeout 10000; then
  stop_server_processes
  printf "iperf3 test finished successfully.\n"
else
  stop_server_processes
  printf "iperf3 client failed; showing server logs:\n" >&2
  sed 's/^/server: /' "$server_log" >&2
  exit 1
fi
