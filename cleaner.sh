#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 enkiel
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
SELECT_MODE=1
if [[ ! -t 0 ]]; then
  SELECT_MODE=0
fi
UI_MODE="auto"

declare -A RUN_TASKS=(
  [apt_update]=1
  [apt_clean]=1
  [purge_configs]=1
  [kernels]=1
  [journal]=1
  [trash]=1
  [snap]=1
  [flatpak]=1
  [docker]=1
  [crash]=1
  [caches]=1
  [rotated_logs]=1
)

TASK_ORDER=(
  apt_update
  apt_clean
  purge_configs
  kernels
  journal
  trash
  snap
  flatpak
  docker
  crash
  caches
  rotated_logs
)

declare -A TASK_LABELS=(
  [apt_update]="Update package index"
  [apt_clean]="Clean apt cache and unused packages"
  [purge_configs]="Purge residual package configs"
  [kernels]="Remove old kernels"
  [journal]="Vacuum journal logs"
  [trash]="Empty user trash folders"
  [snap]="Remove disabled Snap revisions"
  [flatpak]="Remove unused Flatpak runtimes"
  [docker]="Prune Docker images/containers/volumes"
  [crash]="Clear crash dumps and coredumps"
  [caches]="Trim user cache directories"
  [rotated_logs]="Remove rotated logs under /var/log"
)

usage() {
  echo "Usage: $0 [--select|--all] [--ui|--plain] [--no-update] [--keep-kernels=N] [--vacuum=7d]"
}

select_tasks() {
  local selection token idx key dialog_tool status

  dialog_tool=""
  if [[ "$UI_MODE" != "plain" ]]; then
    if command -v whiptail >/dev/null 2>&1; then
      dialog_tool="whiptail"
    elif command -v dialog >/dev/null 2>&1; then
      dialog_tool="dialog"
    fi
  fi

  if [[ -z "$dialog_tool" && "$UI_MODE" != "plain" ]]; then
    if [[ -t 0 ]]; then
      echo -e "${YELLOW}No dialog tool found (whiptail/dialog).${ENDCOLOR}"
      echo -en "${YELLOW}Install whiptail now? [y/N]: ${ENDCOLOR}"
      read -r selection
      if [[ "$selection" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installing whiptail...${ENDCOLOR}"
        if ! apt-get update -qq; then
          echo -e "${RED}apt-get update failed; continuing install attempt.${ENDCOLOR}"
        fi
        if apt-get install -y whiptail; then
          dialog_tool="whiptail"
        else
          echo -e "${RED}Failed to install whiptail.${ENDCOLOR}"
        fi
      fi
    fi
  fi

  if [[ -n "$dialog_tool" ]]; then
    local options=()
    for key in "${TASK_ORDER[@]}"; do
      options+=("$key" "${TASK_LABELS[$key]}" "ON")
    done

    if [[ "$dialog_tool" == "dialog" ]]; then
      mapfile -t selection < <(
        dialog --stdout --separate-output --title "Linux Cleaner" \
          --checklist "Select cleanup tasks:" 20 90 12 "${options[@]}"
      )
      status=$?
    else
      mapfile -t selection < <(
        whiptail --title "Linux Cleaner" \
          --checklist "Select cleanup tasks:" 20 90 12 --separate-output "${options[@]}" \
          3>&1 1>&2 2>&3
      )
      status=$?
    fi

    if [[ $status -ne 0 ]]; then
      echo -e "${RED}Selection canceled.${ENDCOLOR}"
      exit 1
    fi

    for key in "${TASK_ORDER[@]}"; do
      RUN_TASKS[$key]=0
    done

    if [[ ${#selection[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No tasks selected. Exiting.${ENDCOLOR}"
      exit 0
    fi

    for token in "${selection[@]}"; do
      RUN_TASKS[$token]=1
    done
    return 0
  fi

  if [[ "$UI_MODE" == "dialog" ]]; then
    echo -e "${RED}No dialog tool found (whiptail/dialog). Install one or use --plain.${ENDCOLOR}"
    exit 1
  fi

  echo -e "${CYAN}Select cleanup tasks (space-separated numbers, or press Enter for all):${ENDCOLOR}"
  idx=1
  for key in "${TASK_ORDER[@]}"; do
    printf "  %d) %s\n" "$idx" "${TASK_LABELS[$key]}"
    idx=$((idx + 1))
  done
  read -r selection

  if [[ -z "$selection" || "$selection" == "all" ]]; then
    return 0
  fi

  for key in "${TASK_ORDER[@]}"; do
    RUN_TASKS[$key]=0
  done

  for token in $selection; do
    if [[ "$token" == "all" ]]; then
      for key in "${TASK_ORDER[@]}"; do
        RUN_TASKS[$key]=1
      done
      return 0
    fi
    if [[ ! "$token" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Invalid selection: $token${ENDCOLOR}"
      exit 1
    fi
    idx=$((token - 1))
    key="${TASK_ORDER[$idx]}"
    if [[ -z "$key" ]]; then
      echo -e "${RED}Invalid selection: $token${ENDCOLOR}"
      exit 1
    fi
    RUN_TASKS[$key]=1
  done
}

for arg in "$@"; do
  case "$arg" in
    --select)
      SELECT_MODE=1
      ;;
    --all)
      SELECT_MODE=0
      ;;
    --ui)
      UI_MODE="dialog"
      ;;
    --plain)
      UI_MODE="plain"
      ;;
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

if [[ $SELECT_MODE -eq 1 ]]; then
  select_tasks
fi

echo -e "${CYAN}=== Disk Usage Before Cleanup ===${ENDCOLOR}"
df -h /
echo
echo -e "${CYAN}APT Cache Size Before:${ENDCOLOR}"
du -sh /var/cache/apt 2>/dev/null || echo "N/A"
echo

if [[ ${RUN_TASKS[apt_update]} -eq 1 && $SKIP_UPDATE -eq 0 ]]; then
  echo -e "${YELLOW}Updating package index...${ENDCOLOR}"
  if ! apt-get update -qq; then
    echo -e "${RED}apt-get update failed; continuing anyway.${ENDCOLOR}"
  fi
fi

if [[ ${RUN_TASKS[apt_clean]} -eq 1 ]]; then
  echo -e "${YELLOW}Cleaning apt cache and unused packages...${ENDCOLOR}"
  apt-get clean
  apt-get -y autoremove --purge
  apt-get autoclean
fi

if [[ ${RUN_TASKS[purge_configs]} -eq 1 ]]; then
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
fi

if [[ ${RUN_TASKS[kernels]} -eq 1 ]]; then
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
fi

if [[ ${RUN_TASKS[journal]} -eq 1 ]] && command -v journalctl >/dev/null 2>&1; then
  echo -e "${YELLOW}Clearing old logs (older than ${JOURNAL_VACUUM})...${ENDCOLOR}"
  journalctl --vacuum-time="${JOURNAL_VACUUM}" >/dev/null 2>&1
fi

if [[ ${RUN_TASKS[trash]} -eq 1 ]]; then
  echo -e "${YELLOW}Emptying user trash folders...${ENDCOLOR}"
  find /home/*/.local/share/Trash/files/ -mindepth 1 -delete 2>/dev/null
  find /home/*/.local/share/Trash/info/ -mindepth 1 -delete 2>/dev/null
  find /root/.local/share/Trash/files/ -mindepth 1 -delete 2>/dev/null
  find /root/.local/share/Trash/info/ -mindepth 1 -delete 2>/dev/null
fi

if [[ ${RUN_TASKS[snap]} -eq 1 ]] && command -v snap >/dev/null 2>&1; then
  echo -e "${YELLOW}Cleaning old Snap revisions...${ENDCOLOR}"
  snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
    snap remove "$snapname" --revision="$revision" >/dev/null 2>&1
  done
fi

if [[ ${RUN_TASKS[flatpak]} -eq 1 ]] && command -v flatpak >/dev/null 2>&1; then
  echo -e "${YELLOW}Removing unused Flatpak runtimes...${ENDCOLOR}"
  flatpak uninstall -y --unused >/dev/null 2>&1
fi

if [[ ${RUN_TASKS[docker]} -eq 1 ]] && command -v docker >/dev/null 2>&1; then
  echo -e "${YELLOW}Pruning unused Docker images/containers/volumes...${ENDCOLOR}"
  if docker info >/dev/null 2>&1; then
    docker system prune -a --volumes -f >/dev/null 2>&1
  else
    echo -e "${RED}Docker daemon not available; skipping prune.${ENDCOLOR}"
  fi
fi

if [[ ${RUN_TASKS[crash]} -eq 1 ]]; then
  echo -e "${YELLOW}Clearing crash dumps and coredumps...${ENDCOLOR}"
  rm -rf /var/crash/* 2>/dev/null
  if command -v coredumpctl >/dev/null 2>&1; then
    coredumpctl purge >/dev/null 2>&1
  elif [[ -d /var/lib/systemd/coredump ]]; then
    rm -rf /var/lib/systemd/coredump/* 2>/dev/null
  fi
fi

if [[ ${RUN_TASKS[caches]} -eq 1 ]]; then
  echo -e "${YELLOW}Trimming user cache directories...${ENDCOLOR}"
  find /home -mindepth 2 -maxdepth 2 -type d -name .cache -print0 2>/dev/null | while IFS= read -r -d '' cache_dir; do
    rm -rf "${cache_dir:?}/"* 2>/dev/null
  done
  if [[ -d /root/.cache ]]; then
    rm -rf /root/.cache/* 2>/dev/null
  fi
fi

if [[ ${RUN_TASKS[rotated_logs]} -eq 1 ]]; then
  echo -e "${YELLOW}Removing old rotated logs...${ENDCOLOR}"
  find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' -o -name '*.log.*' \) -delete 2>/dev/null
fi

echo
echo -e "${CYAN}=== Disk Usage After Cleanup ===${ENDCOLOR}"
df -h /
echo
echo -e "${CYAN}APT Cache Size After:${ENDCOLOR}"
du -sh /var/cache/apt 2>/dev/null || echo "N/A"
echo

echo -e "${GREEN}System cleanup complete!${ENDCOLOR}"
