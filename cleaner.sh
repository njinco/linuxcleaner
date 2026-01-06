#!/usr/bin/env bash
# Ubuntu/Debian Cleaner Script
# Merged from cleaner.sh and cleanerv2.sh
# Cleans apt cache, unused packages, residual configs, old kernels, logs, snap/flatpak leftovers,
# docker artifacts, crash dumps, user caches, and trash

YELLOW="\033[1;33m"
RED="\033[0;31m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
ENDCOLOR="\033[0m"

KEEP_KERNELS=2
SKIP_UPDATE=0
JOURNAL_VACUUM="7d"

usage() {
  echo "Usage: $0 [--no-update] [--keep-kernels=N] [--vacuum=7d]"
}

for arg in "$@"; do
  case "$arg" in
    --no-update)
      SKIP_UPDATE=1
      ;;
    --keep-kernels=*)
      KEEP_KERNELS="${arg#*=}"
      ;;
    --vacuum=*)
      JOURNAL_VACUUM="${arg#*=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $arg${ENDCOLOR}"
      usage
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Error: must be run as root. Exiting...${ENDCOLOR}"
  exit 1
fi

echo -e "${CYAN}=== Disk Usage Before Cleanup ===${ENDCOLOR}"
df -h /
echo
echo -e "${CYAN}APT Cache Size Before:${ENDCOLOR}"
du -sh /var/cache/apt 2>/dev/null || echo "N/A"
echo

if [[ $SKIP_UPDATE -eq 0 ]]; then
  echo -e "${YELLOW}Updating package index...${ENDCOLOR}"
  if ! apt-get update -qq; then
    echo -e "${RED}apt-get update failed; continuing anyway.${ENDCOLOR}"
  fi
fi

echo -e "${YELLOW}Cleaning apt cache and unused packages...${ENDCOLOR}"
apt-get clean
apt-get -y autoremove --purge
apt-get autoclean

mapfile -t OLDCONF < <(dpkg -l | awk '/^rc/ {print $2}')
if [[ ${#OLDCONF[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Purging leftover package configs:${ENDCOLOR}"
  for PKGNAME in "${OLDCONF[@]}"; do
    echo -e "${GREEN}- Purging $PKGNAME${ENDCOLOR}"
    apt-get -y purge "$PKGNAME" >/dev/null 2>&1
  done
else
  echo -e "${GREEN}No residual configs found.${ENDCOLOR}"
fi

CURKERNEL=$(uname -r)
echo -e "${YELLOW}Current kernel: ${GREEN}${CURKERNEL}${ENDCOLOR}"

mapfile -t INSTALLED_KERNEL_VERSIONS < <(
  dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/ {print $2}' | sed 's/^linux-image-//' | sort -V
)
if [[ ${#INSTALLED_KERNEL_VERSIONS[@]} -gt 0 ]]; then
  KEEP_VERSIONS=()
  if [[ ${#INSTALLED_KERNEL_VERSIONS[@]} -gt $KEEP_KERNELS ]]; then
    KEEP_VERSIONS+=("${INSTALLED_KERNEL_VERSIONS[@]: -$KEEP_KERNELS}")
  else
    KEEP_VERSIONS+=("${INSTALLED_KERNEL_VERSIONS[@]}")
  fi
  if [[ ! " ${KEEP_VERSIONS[*]} " =~ " $CURKERNEL " ]]; then
    KEEP_VERSIONS+=("$CURKERNEL")
  fi

  mapfile -t KERNEL_PKGS < <(
    dpkg -l | awk '/^ii/ {print $2}' | grep -E '^(linux-image|linux-headers|linux-modules|linux-modules-extra)-[0-9]+' || true
  )
  KERNEL_PKGS_TO_REMOVE=()
  for pkg in "${KERNEL_PKGS[@]}"; do
    keep_pkg=0
    for ver in "${KEEP_VERSIONS[@]}"; do
      if [[ "$pkg" == *"$ver"* ]]; then
        keep_pkg=1
        break
      fi
    done
    if [[ $keep_pkg -eq 0 ]]; then
      KERNEL_PKGS_TO_REMOVE+=("$pkg")
    fi
  done

  if [[ ${#KERNEL_PKGS_TO_REMOVE[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Removing old kernels (keeping: ${GREEN}${KEEP_VERSIONS[*]}${ENDCOLOR})${ENDCOLOR}"
    apt-get -y purge "${KERNEL_PKGS_TO_REMOVE[@]}"
  else
    echo -e "${GREEN}No old kernels to remove.${ENDCOLOR}"
  fi
else
  echo -e "${GREEN}No versioned kernel packages found.${ENDCOLOR}"
fi

if command -v journalctl >/dev/null 2>&1; then
  echo -e "${YELLOW}Clearing old logs (older than ${JOURNAL_VACUUM})...${ENDCOLOR}"
  journalctl --vacuum-time="${JOURNAL_VACUUM}" >/dev/null 2>&1
fi

echo -e "${YELLOW}Emptying user trash folders...${ENDCOLOR}"
find /home/*/.local/share/Trash/files/ -mindepth 1 -delete 2>/dev/null
find /home/*/.local/share/Trash/info/ -mindepth 1 -delete 2>/dev/null
find /root/.local/share/Trash/files/ -mindepth 1 -delete 2>/dev/null
find /root/.local/share/Trash/info/ -mindepth 1 -delete 2>/dev/null

if command -v snap >/dev/null 2>&1; then
  echo -e "${YELLOW}Cleaning old Snap revisions...${ENDCOLOR}"
  snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
    snap remove "$snapname" --revision="$revision" >/dev/null 2>&1
  done
fi

if command -v flatpak >/dev/null 2>&1; then
  echo -e "${YELLOW}Removing unused Flatpak runtimes...${ENDCOLOR}"
  flatpak uninstall -y --unused >/dev/null 2>&1
fi

if command -v docker >/dev/null 2>&1; then
  echo -e "${YELLOW}Pruning unused Docker images/containers/volumes...${ENDCOLOR}"
  if docker info >/dev/null 2>&1; then
    docker system prune -a --volumes -f >/dev/null 2>&1
  else
    echo -e "${RED}Docker daemon not available; skipping prune.${ENDCOLOR}"
  fi
fi

echo -e "${YELLOW}Clearing crash dumps and coredumps...${ENDCOLOR}"
rm -rf /var/crash/* 2>/dev/null
if command -v coredumpctl >/dev/null 2>&1; then
  coredumpctl purge >/dev/null 2>&1
elif [[ -d /var/lib/systemd/coredump ]]; then
  rm -rf /var/lib/systemd/coredump/* 2>/dev/null
fi

echo -e "${YELLOW}Trimming user cache directories...${ENDCOLOR}"
find /home -mindepth 2 -maxdepth 2 -type d -name .cache -print0 2>/dev/null | while IFS= read -r -d '' cache_dir; do
  rm -rf "${cache_dir:?}/"* 2>/dev/null
done
if [[ -d /root/.cache ]]; then
  rm -rf /root/.cache/* 2>/dev/null
fi

echo -e "${YELLOW}Removing old rotated logs...${ENDCOLOR}"
find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' -o -name '*.log.*' \) -delete 2>/dev/null

echo
echo -e "${CYAN}=== Disk Usage After Cleanup ===${ENDCOLOR}"
df -h /
echo
echo -e "${CYAN}APT Cache Size After:${ENDCOLOR}"
du -sh /var/cache/apt 2>/dev/null || echo "N/A"
echo

echo -e "${GREEN}System cleanup complete!${ENDCOLOR}"
