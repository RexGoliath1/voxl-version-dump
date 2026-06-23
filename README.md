# voxl-version-dump

Shell script that captures a complete version and service snapshot from a VOXL2 device — installed packages, binary fingerprints, running services, MPA pipe subscribers, network connections, and any git repos present on the device.

## Usage

The script runs on the device itself. The recommended way is via ADB from a connected host machine:

```sh
adb push voxl_version_dump.sh /tmp/
adb shell sh /tmp/voxl_version_dump.sh > versions.txt
```

This executes the script on the VOXL and streams the output back to `versions.txt` on your machine.

If you have SSH access instead:

```sh
scp voxl_version_dump.sh root@<device-ip>:/tmp/
ssh root@<device-ip> sh /tmp/voxl_version_dump.sh > versions.txt
```

## What it captures

| Section | Contents |
|---|---|
| Device identity | Hostname, kernel, SKU, OS release |
| VOXL/ModalAI/PX4 packages | All matching dpkg packages with exact versions |
| All packages | Full `dpkg -l` output |
| Git repos | Remote URLs, branch, HEAD commit hash and message for any repos found under `/root`, `/home`, `/data`, `/opt/ros`, `/workspace`, `/catkin_ws` |
| Docker | Running/stopped containers, image digests, git repos inside each running container |
| Running services | Active systemd units matching voxl/modal/px4/ros/precision/vision |
| Full process list | Complete `ps aux` output |
| Network interfaces | `ip addr` output |
| Routing table | `ip route` output |
| `/etc/hosts` | Hostname/IP mappings |
| Active connections | TCP and UDP sockets with owning process (`ss -tnp / -unp`) |
| MPA pipes | All pipes under `/run/mpa` with active subscriber process names |
| Binary fingerprints | GNU build-id (or sha256 fallback) for key VOXL binaries |
| Vision hub config | Full `/etc/modalai/voxl-vision-hub.conf` |
| PX4 config | Full `/etc/modalai/voxl-px4.conf` |

## Testing

Two Dockerfiles are provided to verify the script runs correctly without a physical device:

```sh
sh test.sh
```

- **`docker/Dockerfile.bionic`** — Ubuntu 18.04 with binutils, iproute2, and a stubbed MPA pipe structure. Matches the real VOXL2 OS and exercises the full code paths (readelf, ss, ip).
- **`docker/Dockerfile.noble`** — Minimal Ubuntu 24.04 with no extra packages. Exercises all fallback paths.

CI runs both on every push via GitHub Actions.
