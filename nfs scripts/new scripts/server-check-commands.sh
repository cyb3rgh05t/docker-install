#!/bin/bash
# ============================================================
#  NFS/MergerFS Streaming Server - Diagnostic Commands
#  Server: plexBeast (193.108.118.53)
# ============================================================

# ────────────────────────────────────────────────────────────
#  SYSTEM OVERVIEW
# ────────────────────────────────────────────────────────────

# Memory usage (RAM + Cache)
free -h

# CPU load & I/O-Wait (5 Sekunden Snapshot)
vmstat 1 5

# Top Prozesse nach CPU/RAM
htop

# System uptime + load average
uptime

# ────────────────────────────────────────────────────────────
#  NFS MOUNTS
# ────────────────────────────────────────────────────────────

# Alle aktiven NFS Mounts anzeigen
mount -t nfs4

# NFS Mount-Optionen im Detail
cat /proc/mounts | grep nfs4

# NFS Client-Statistiken (Retransmits, Timeouts, etc.)
nfsstat -c

# NFS I/O Statistiken pro Mount
nfsiostat 1 5

# NFS RPC Slots prüfen (sollte 128 sein)
cat /proc/sys/sunrpc/tcp_max_slot_table_entries

# NFS Read-Ahead pro Mount prüfen (sollte 16384 sein)
for bdi in /sys/class/bdi/0:*; do
    echo "$bdi: $(cat $bdi/read_ahead_kb) KB"
done

# NFS Verbindungen pro Server anzeigen (nconnect)
ss -tn | grep ':2049' | awk '{print $5}' | cut -d: -f1 | sort | uniq -c

# ────────────────────────────────────────────────────────────
#  MERGERFS
# ────────────────────────────────────────────────────────────

# MergerFS Prozess + vollständige Optionen
cat /proc/$(pgrep -x mergerfs | head -1)/cmdline | tr '\0' '\n'

# Nur Cache-Einstellungen anzeigen
cat /proc/$(pgrep -x mergerfs | head -1)/cmdline | tr '\0' '\n' | grep cache

# MergerFS Mount prüfen
mount | grep mergerfs

# MergerFS PID
pgrep -x mergerfs

# MergerFS Version
mergerfs --version

# ────────────────────────────────────────────────────────────
#  DATENBANK (NFS-Mount Manager)
# ────────────────────────────────────────────────────────────

# Alle MergerFS Konfigurationen
sqlite3 /opt/appdata/nfs-mount/data/nfs-manager.db "SELECT * FROM mergerfs_configs;"

# MergerFS Optionen (formatiert)
sqlite3 /opt/appdata/nfs-mount/data/nfs-manager.db "SELECT options FROM mergerfs_configs WHERE name='UnionFS';" | tr ',' '\n'

# Alle NFS Mounts in der DB
sqlite3 /opt/appdata/nfs-mount/data/nfs-manager.db "SELECT * FROM nfs_mounts;"

# NFS Mount-Optionen (formatiert)
sqlite3 /opt/appdata/nfs-mount/data/nfs-manager.db "SELECT mount_options FROM nfs_mounts;" | tr ',' '\n'

# Alle NFS Exports in der DB
sqlite3 /opt/appdata/nfs-mount/data/nfs-manager.db "SELECT * FROM nfs_exports;"

# Alle Tabellen anzeigen
sqlite3 /opt/appdata/nfs-mount/data/nfs-manager.db ".tables"

# ────────────────────────────────────────────────────────────
#  KERNEL TUNING
# ────────────────────────────────────────────────────────────

# TCP Buffer Sizes (sollte 128MB = 134217728 sein)
sysctl net.core.rmem_max net.core.wmem_max

# TCP Memory
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem

# TCP Congestion Control (sollte bbr sein)
sysctl net.ipv4.tcp_congestion_control

# Dirty Ratio (Cache Write-Back)
sysctl vm.dirty_ratio vm.dirty_background_ratio

# VFS Cache Pressure
sysctl vm.vfs_cache_pressure

# Swappiness (sollte niedrig sein für Streaming)
sysctl vm.swappiness

# Max Map Count
sysctl vm.max_map_count

# Alle relevanten Kernel-Parameter auf einmal
sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_congestion_control vm.dirty_ratio vm.dirty_background_ratio vm.vfs_cache_pressure vm.swappiness

# ────────────────────────────────────────────────────────────
#  NETZWERK
# ────────────────────────────────────────────────────────────

# Netzwerk-Interface Statistiken
ip -s link show

# Aktive NFS Verbindungen
ss -tn | grep 2049

# Netzwerk-Durchsatz live (falls iftop installiert)
# iftop -i eth0

# Bandbreite zu NFS Server testen
# iperf3 -c 168.119.199.33

# RPS/XPS Status prüfen (CPU Affinität für Netzwerk)
for q in /sys/class/net/*/queues/rx-*/rps_cpus; do
    echo "$q: $(cat $q)"
done

# ────────────────────────────────────────────────────────────
#  STORAGE / DISK
# ────────────────────────────────────────────────────────────

# Disk Usage aller Mounts
df -h | grep -E '(mnt|Filesystem)'

# I/O Statistiken (falls iostat installiert)
iostat -x 1 5

# Offene Dateien auf MergerFS (z.B. Plex Streams)
lsof +D /mnt/unionfs 2>/dev/null | head -20

# ────────────────────────────────────────────────────────────
#  DOCKER / NFS-MOUNT MANAGER
# ────────────────────────────────────────────────────────────

# Container Status
docker ps | grep nfs

# Container Logs (letzte 50 Zeilen)
docker logs --tail 50 nfs-mount

# Container Logs live
docker logs -f nfs-mount

# Container restart
docker restart nfs-mount

# ────────────────────────────────────────────────────────────
#  PLEX
# ────────────────────────────────────────────────────────────

# Plex Container Status
docker ps | grep plex

# Plex aktive Streams (offene Dateien)
lsof -c Plex 2>/dev/null | grep /mnt/unionfs | head -20

# ────────────────────────────────────────────────────────────
#  QUICK HEALTH CHECK (alles auf einmal)
# ────────────────────────────────────────────────────────────

echo "=== Memory ===" && free -h && echo ""
echo "=== Load ===" && uptime && echo ""
echo "=== NFS Mounts ===" && mount -t nfs4 && echo ""
echo "=== MergerFS ===" && mount | grep mergerfs && echo ""
echo "=== NFS Connections ===" && ss -tn | grep 2049 | wc -l && echo ""
echo "=== Disk Usage ===" && df -h | grep mnt && echo ""
echo "=== Docker ===" && docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E '(nfs|plex|NAMES)'
