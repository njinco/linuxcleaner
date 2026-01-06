# Linux Cleaner

System cleanup script for Ubuntu/Debian-based systems.

## What It Does
- Cleans apt cache and removes unused packages
- Purges residual config packages
- Removes old kernels (keeps a configurable number plus the running kernel)
- Vacuums journal logs
- Empties user trash
- Removes disabled Snap revisions
- Removes unused Flatpak runtimes (if Flatpak is installed)
- Prunes unused Docker images/containers/volumes (if Docker is installed and running)
- Clears crash dumps and coredumps
- Trims user cache directories
- Deletes rotated logs under `/var/log`

## Usage
Run as root:

```bash
sudo ./cleaner.sh
```

Options:
- `--no-update` skip `apt-get update`
- `--keep-kernels=N` keep N newest kernel versions (default: 2)
- `--vacuum=7d` set journal vacuum age (default: 7d)

## Notes
- This script is destructive and removes files. Review before use.
- Snap base runtimes are kept as long as apps depend on them.
- Docker prune removes unused volumes; this may delete data you still need.

## Credit
Adapted from 71529-ubucleaner.sh - http://www.opendesktop.org/CONTENT/content-files/71529-ubucleaner.sh (link now defunct; credited for historical reference).
