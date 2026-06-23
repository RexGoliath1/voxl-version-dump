#!/bin/sh
# Dump version/commit/service information from a VOXL2 device.
# Runs on the device itself — see README for usage.

SEP="============================================================"

run_timeout() {
  secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    rc=$?; [ $rc -eq 124 ] && echo "  [timed out after ${secs}s]"; return $rc
  else
    "$@"
  fi
}

bin_fingerprint() {
  bin=$1
  if command -v readelf >/dev/null 2>&1; then
    id=$(readelf -n "$bin" 2>/dev/null | grep 'Build ID' | awk '{print $NF}')
    [ -n "$id" ] && echo "$id" && return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$bin" 2>/dev/null | awk '{print "sha256:" $1}'; return
  fi
  echo "<no fingerprint tool available>"
}

is_elf() {
  magic=$(dd if="$1" bs=4 count=1 2>/dev/null | od -A n -t x1 2>/dev/null | tr -d ' \n')
  [ "$magic" = "7f454c46" ]
}

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
    echo "--- TCP+UDP (netstat -tnup) ---"
    netstat -tnup 2>/dev/null || netstat -tnp 2>/dev/null || echo "  netstat failed"
  else
    echo "  neither ss nor netstat available — falling back to /proc/net"
    cat /proc/net/tcp 2>/dev/null | head -30 || echo "  /proc/net/tcp not readable"
    cat /proc/net/udp 2>/dev/null | head -30 || echo "  /proc/net/udp not readable"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
echo "$SEP"
echo "VOXL VERSION DUMP  $(date)"
echo "$SEP"

echo ""
echo "=== DEVICE IDENTITY ==="
echo "Hostname:  $(hostname 2>/dev/null)"
echo "Kernel:    $(uname -r 2>/dev/null)"
cat /data/modalai/sku.txt 2>/dev/null && echo "" || echo "SKU: not found"
cat /etc/os-release 2>/dev/null || cat /etc/issue 2>/dev/null

echo ""
echo "=== VOXL / MODALAI / PX4 PACKAGES ==="
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' 2>/dev/null \
    | grep -iE 'voxl|modal|px4|libfc|libslpi|royale|rtl88' \
    | sort
else
  echo "  dpkg not available"
fi

echo ""
echo "=== ALL PACKAGES (full dpkg -l) ==="
dpkg -l 2>/dev/null || echo "  dpkg not available"

echo ""
echo "=== GIT REPOS ON HOST FILESYSTEM ==="
GIT_SEARCH_DIRS="/root /home /data /opt/ros /opt/modalai /usr/local/src /srv /workspace /catkin_ws"
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
  echo "$GITDIRS" | while read -r gitdir; do
    repodir=$(dirname "$gitdir")
    echo ""
    echo "--- Repo: $repodir ---"
    run_timeout 5 git -C "$repodir" remote -v 2>/dev/null || echo "  (no remotes)"
    echo "  Branch:  $(run_timeout 5 git -C "$repodir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "  HEAD:    $(run_timeout 5 git -C "$repodir" rev-parse HEAD 2>/dev/null)"
    echo "  Subject: $(run_timeout 5 git -C "$repodir" log -1 --pretty='%s' 2>/dev/null)"
    echo "  Date:    $(run_timeout 5 git -C "$repodir" log -1 --pretty='%ci' 2>/dev/null)"
  done
fi

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
if command -v readelf >/dev/null 2>&1; then
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

# Scan custom install locations for ELF binaries
for dir in /usr/local/bin /data/modalai /home; do
  [ -d "$dir" ] || continue
  run_timeout 15 find "$dir" -maxdepth 3 -type f -executable 2>/dev/null \
  | while read -r bin; do
    is_elf "$bin" || continue
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
