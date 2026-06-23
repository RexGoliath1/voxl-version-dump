#!/bin/sh
# Dump all version/commit information from a VOXL device.
#
# ── On VOXL (target device) ──────────────────────────────────────────────────
#   adb push voxl_version_dump.sh /tmp/ && adb shell sh /tmp/voxl_version_dump.sh > versions.txt
#
# ── macOS (native dry-run) ───────────────────────────────────────────────────
#   sh voxl_version_dump.sh > versions.txt
#
# ── macOS / Linux (Docker dry-run, closer to real VOXL environment) ─────────
#   docker run --rm -v "$PWD/voxl_version_dump.sh:/tmp/voxl_version_dump.sh" \
#     ubuntu:24.04 sh /tmp/voxl_version_dump.sh > versions.txt
#
# ── Windows (Docker Desktop — PowerShell) ────────────────────────────────────
#   docker run --rm -v "${PWD}\voxl_version_dump.sh:/tmp/voxl_version_dump.sh" `
#     ubuntu:24.04 sh /tmp/voxl_version_dump.sh > versions.txt
#
# ── Windows (Docker Desktop — cmd.exe) ───────────────────────────────────────
#   docker run --rm -v "%CD%\voxl_version_dump.sh:/tmp/voxl_version_dump.sh" ^
#     ubuntu:24.04 sh /tmp/voxl_version_dump.sh > versions.txt

SEP="============================================================"

# ── OS detection ────────────────────────────────────────────────────────────
OS=$(uname -s)
IS_MAC=0
[ "$OS" = "Darwin" ] && IS_MAC=1

# ── timeout wrapper ──────────────────────────────────────────────────────────
# macOS ships gtimeout via coreutils (brew), otherwise fall back to plain run
run_timeout() {
  secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    rc=$?; [ $rc -eq 124 ] && echo "  [timed out after ${secs}s]"; return $rc
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    rc=$?; [ $rc -eq 124 ] && echo "  [timed out after ${secs}s]"; return $rc
  else
    "$@"
  fi
}

# ── fingerprint helpers ──────────────────────────────────────────────────────
# Linux: GNU build-id via readelf, fallback sha256sum
# macOS: build UUID via otool, fallback shasum -a 256
bin_fingerprint() {
  bin=$1
  if [ $IS_MAC -eq 1 ]; then
    if command -v otool >/dev/null 2>&1; then
      id=$(otool -l "$bin" 2>/dev/null \
        | awk '/LC_UUID/{found=1} found && /uuid/{print $2; exit}')
      [ -n "$id" ] && echo "uuid:$id" && return
    fi
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$bin" 2>/dev/null | awk '{print "sha256:" $1}'; return
    fi
  else
    if command -v readelf >/dev/null 2>&1; then
      id=$(readelf -n "$bin" 2>/dev/null | grep 'Build ID' | awk '{print $NF}')
      [ -n "$id" ] && echo "$id" && return
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$bin" 2>/dev/null | awk '{print "sha256:" $1}'; return
    fi
  fi
  echo "<no fingerprint tool available>"
}

# macOS ELF check doesn't apply — use Mach-O detection instead
is_native_binary() {
  bin=$1
  if [ $IS_MAC -eq 1 ]; then
    # Mach-O magic: feedface / feedfacf / cefaedfe / cffaedfe / cafebabe
    magic=$(dd if="$bin" bs=4 count=1 2>/dev/null | od -A n -t x1 2>/dev/null | tr -d ' \n')
    case "$magic" in
      feedface|feedfacf|cefaedfe|cffaedfe|cafebabe) return 0 ;;
      *) return 1 ;;
    esac
  else
    # ELF magic: 7f 45 4c 46
    magic=$(dd if="$bin" bs=4 count=1 2>/dev/null | od -A n -t x1 2>/dev/null | tr -d ' \n')
    [ "$magic" = "7f454c46" ]
  fi
}

# ── network helpers ──────────────────────────────────────────────────────────
show_network_interfaces() {
  if command -v ip >/dev/null 2>&1; then
    ip addr show 2>/dev/null
  else
    ifconfig -a 2>/dev/null || echo "  ip/ifconfig not available"
  fi
}

show_routing_table() {
  if command -v ip >/dev/null 2>&1; then
    ip route show 2>/dev/null
  elif [ $IS_MAC -eq 1 ]; then
    netstat -rn 2>/dev/null || echo "  routing info not available"
  else
    route -n 2>/dev/null || netstat -rn 2>/dev/null || echo "  routing info not available"
  fi
}

show_network_connections() {
  if command -v ss >/dev/null 2>&1; then
    echo "--- TCP (ss -tnp) ---"
    ss -tnp 2>/dev/null || echo "  ss -tnp failed"
    echo ""
    echo "--- UDP (ss -unp) ---"
    ss -unp 2>/dev/null || echo "  ss -unp failed"
  elif command -v netstat >/dev/null 2>&1; then
    if [ $IS_MAC -eq 1 ]; then
      echo "--- TCP (netstat -anp tcp) ---"
      netstat -anp tcp 2>/dev/null || echo "  netstat failed"
      echo ""
      echo "--- UDP (netstat -anp udp) ---"
      netstat -anp udp 2>/dev/null || echo "  netstat failed"
    else
      echo "--- TCP+UDP (netstat -tnup) ---"
      netstat -tnup 2>/dev/null || netstat -tnp 2>/dev/null || echo "  netstat failed"
    fi
  else
    echo "  neither ss nor netstat available — falling back to /proc/net"
    cat /proc/net/tcp  2>/dev/null | head -30 || echo "  /proc/net/tcp not readable"
    cat /proc/net/udp  2>/dev/null | head -30 || echo "  /proc/net/udp not readable"
  fi
}

# ── git search dirs (Linux/VOXL only) ────────────────────────────────────────
GIT_SEARCH_DIRS="/root /home /data /opt/ros /opt/modalai /usr/local/src /srv /workspace /catkin_ws"

# ────────────────────────────────────────────────────────────────────────────
echo "$SEP"
echo "VOXL VERSION DUMP  $(date)"
[ $IS_MAC -eq 1 ] && echo "  NOTE: running on macOS — VOXL binaries will show <not found>"
echo "$SEP"

echo ""
echo "=== DEVICE IDENTITY ==="
echo "Hostname:  $(hostname 2>/dev/null)"
echo "OS:        $OS  $(uname -r 2>/dev/null)"
if [ $IS_MAC -eq 1 ]; then
  sw_vers 2>/dev/null || true
else
  cat /data/modalai/sku.txt 2>/dev/null && echo "" || echo "SKU: not found"
  cat /etc/os-release 2>/dev/null || cat /etc/issue 2>/dev/null
fi

echo ""
echo "=== VOXL / MODALAI / PX4 PACKAGES ==="
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' 2>/dev/null \
    | grep -iE 'voxl|modal|px4|libfc|libslpi|royale|rtl88' \
    | sort
else
  echo "  dpkg not available (not a Debian-based system)"
fi

echo ""
echo "=== ALL PACKAGES (full dpkg -l) ==="
if command -v dpkg >/dev/null 2>&1; then
  dpkg -l 2>/dev/null
else
  echo "  dpkg not available"
fi

echo ""
echo "=== GIT REPOS ON HOST FILESYSTEM ==="
if [ $IS_MAC -eq 1 ]; then
  echo "  (skipped on macOS — only meaningful on target device)"
else

# Only report repos whose remote URL contains keywords relevant to this device.
# Unrelated ROS/third-party packages in the same search dirs are skipped.
RELEVANT_PATTERN='voxl|modal|px4|brecourt|starling|qrb5165'

GITDIRS=""
for d in $GIT_SEARCH_DIRS; do
  [ -d "$d" ] || continue
  found=$(run_timeout 10 find "$d" -maxdepth 8 -name '.git' -type d 2>/dev/null)
  GITDIRS="$GITDIRS $found"
done
GITDIRS=$(echo "$GITDIRS" | tr ' ' '\n' | sed '/^$/d')

if [ -z "$GITDIRS" ]; then
  echo "No git repos found (searched: $GIT_SEARCH_DIRS)"
else
  matched=0
  skipped=0
  echo "$GITDIRS" | while read -r gitdir; do
    repodir=$(dirname "$gitdir")
    remote=$(run_timeout 5 git -C "$repodir" remote get-url origin 2>/dev/null \
             || run_timeout 5 git -C "$repodir" remote -v 2>/dev/null | head -1)
    # check remote URL and repo path against relevant keywords
    if echo "$remote $repodir" | grep -qiE "$RELEVANT_PATTERN"; then
      echo ""
      echo "--- Repo: $repodir ---"
      echo "  Remote:  $remote"
      echo "  Branch:  $(run_timeout 5 git -C "$repodir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      echo "  HEAD:    $(run_timeout 5 git -C "$repodir" rev-parse HEAD 2>/dev/null)"
      echo "  Subject: $(run_timeout 5 git -C "$repodir" log -1 --pretty='%s' 2>/dev/null)"
      echo "  Date:    $(run_timeout 5 git -C "$repodir" log -1 --pretty='%ci' 2>/dev/null)"
    else
      echo "  (skipped unrelated repo: $repodir)"
    fi
  done
fi

fi # end IS_MAC skip

echo ""
echo "=== DOCKER ==="
if command -v docker >/dev/null 2>&1; then
  echo "--- docker version ---"
  run_timeout 10 docker version 2>/dev/null

  echo ""
  echo "--- running containers ---"
  run_timeout 10 docker ps 2>/dev/null

  echo ""
  echo "--- all containers ---"
  run_timeout 10 docker ps -a 2>/dev/null

  echo ""
  echo "--- images (with digests) ---"
  run_timeout 10 docker images --digests 2>/dev/null

  echo ""
  echo "--- container details (inspect + git repos) ---"
  for cid in $(run_timeout 10 docker ps -q 2>/dev/null); do
    echo ""
    echo "  Container: $cid"
    run_timeout 10 docker inspect "$cid" 2>/dev/null \
      | grep -E '"Image"|"RepoDigests"|"Id"|"RepoTags"' | head -20

    echo "  --- git repos inside container $cid ---"
    for idir in /root /home /workspace /catkin_ws /opt/ros /app /src; do
      run_timeout 15 docker exec "$cid" find "$idir" -maxdepth 8 \
        -name '.git' -type d 2>/dev/null | while read -r igitdir; do
        irepodir=$(dirname "$igitdir")
        echo ""
        echo "    --- Inner repo: $irepodir ---"
        run_timeout 5 docker exec "$cid" git -C "$irepodir" remote -v 2>/dev/null \
          || echo "    (no remotes)"
        echo "    Branch:  $(run_timeout 5 docker exec "$cid" git -C "$irepodir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        echo "    HEAD:    $(run_timeout 5 docker exec "$cid" git -C "$irepodir" rev-parse HEAD 2>/dev/null)"
        echo "    Subject: $(run_timeout 5 docker exec "$cid" git -C "$irepodir" log -1 --pretty='%s' 2>/dev/null)"
        echo "    Date:    $(run_timeout 5 docker exec "$cid" git -C "$irepodir" log -1 --pretty='%ci' 2>/dev/null)"
      done
    done
  done
else
  echo "Docker not installed."
fi

echo ""
echo "=== RUNNING SERVICES ==="
if command -v systemctl >/dev/null 2>&1; then
  run_timeout 10 systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -iE 'voxl|modal|px4|ros|precision|vision' \
    || echo "  (no matching running services)"
  echo ""
  echo "=== ALL SYSTEMD SERVICE STATES (voxl/modal/px4/ros) ==="
  run_timeout 10 systemctl list-units --type=service --all 2>/dev/null \
    | grep -iE 'voxl|modal|px4|ros|precision|vision' \
    || echo "  (none found)"
elif [ $IS_MAC -eq 1 ]; then
  echo "  (macOS — launchctl list, filtering relevant services)"
  launchctl list 2>/dev/null | grep -iE 'voxl|modal|px4|ros|precision|vision' \
    || echo "  (none found)"
else
  echo "  systemctl not available"
fi

echo ""
echo "=== FULL PROCESS LIST ==="
ps aux 2>/dev/null || ps -ef 2>/dev/null || echo "  ps not available"

echo ""
echo "=== NETWORK INTERFACES ==="
show_network_interfaces

echo ""
echo "=== ROUTING TABLE ==="
show_routing_table

echo ""
echo "=== /etc/hosts ==="
cat /etc/hosts 2>/dev/null || echo "  not found"

echo ""
echo "=== ACTIVE NETWORK CONNECTIONS ==="
show_network_connections

echo ""
echo "=== MPA PIPES AND SUBSCRIBERS ==="
MPA_DIR=""
for d in /run/mpa /dev/mpa; do
  [ -d "$d" ] && MPA_DIR="$d" && break
done
if [ -z "$MPA_DIR" ]; then
  echo "  MPA pipe directory not found (checked /run/mpa, /dev/mpa)"
else
  echo "  Found MPA at: $MPA_DIR"
  echo ""
  for pipedir in "$MPA_DIR"/*/; do
    [ -d "$pipedir" ] || continue
    pipename=$(basename "$pipedir")
    subscribers=$(ls "$pipedir" 2>/dev/null \
      | grep -vE '^(info|request|control)$' \
      | tr '\n' ' ')
    if [ -n "$subscribers" ]; then
      printf "  %-40s subscribers: %s\n" "$pipename" "$subscribers"
    else
      printf "  %-40s (no active subscribers)\n" "$pipename"
    fi
  done
fi

echo ""
echo "=== VOXL-INSPECT (MPA pipe consumers) ==="
if command -v voxl-inspect >/dev/null 2>&1; then
  run_timeout 10 voxl-inspect 2>/dev/null || echo "  voxl-inspect failed"
else
  echo "  voxl-inspect not installed"
fi

echo ""
echo "=== KEY BINARY FINGERPRINTS ==="
if [ $IS_MAC -eq 1 ]; then
  echo "  fingerprint method: build-uuid (otool) or sha256 (shasum)"
elif command -v readelf >/dev/null 2>&1; then
  echo "  fingerprint method: build-id (readelf)"
else
  echo "  fingerprint method: sha256sum (readelf not available)"
fi

for name in voxl-vision-hub voxl-px4 voxl-mavlink-server \
            voxl-camera-server voxl-tag-detector \
            voxl-flow-server voxl-qvio-server \
            voxl-open-vins-server voxl-mpa-to-ros; do
  bin=""
  for candidate in "/usr/bin/$name" "/usr/local/bin/$name" "/opt/modalai/bin/$name"; do
    [ -f "$candidate" ] && bin="$candidate" && break
  done
  [ -z "$bin" ] && bin=$(command -v "$name" 2>/dev/null)

  if [ -n "$bin" ]; then
    printf "  %-40s %s\n" "$bin" "$(bin_fingerprint "$bin")"
  else
    printf "  %-40s %s\n" "$name" "<not found>"
  fi
done

# Scan custom install locations for native binaries only
if [ $IS_MAC -eq 1 ]; then
  SCAN_DIRS="/usr/local/bin $HOME/bin"
else
  SCAN_DIRS="/usr/local/bin /data/modalai /home"
fi
for dir in $SCAN_DIRS; do
  [ -d "$dir" ] || continue
  run_timeout 15 find "$dir" -maxdepth 3 -type f -executable 2>/dev/null \
  | while read -r bin; do
    is_native_binary "$bin" || continue
    fp=$(bin_fingerprint "$bin")
    [ -n "$fp" ] && printf "  %-40s %s\n" "$bin" "$fp"
  done
done

echo ""
echo "=== VISION HUB CONFIG ==="
cat /etc/modalai/voxl-vision-hub.conf 2>/dev/null || echo "  not found"

echo ""
echo "=== PX4 CONFIG ==="
cat /etc/modalai/voxl-px4.conf 2>/dev/null || echo "  not found"

echo ""
echo "$SEP"
echo "DUMP COMPLETE  $(date)"
echo "$SEP"
