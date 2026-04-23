#!/bin/bash
#
# NFS Storage Server Optimization Script — storage300
# Server: 168.119.199.33 (AMD EPYC 7502, 256 GB RAM, 14x 22TB HDD ZFS RAIDZ1)
# OS: Ubuntu 24.04, 10GbE Hetzner Dedicated
# Use Case: NFS streaming for 80+ concurrent Plex/VOD clients
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Run as root!${NC}"
    exit 1
fi

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Storage 300 — Full Optimization${NC}"
echo -e "${CYAN}  256 GB RAM · AMD EPYC 7502 · 10GbE${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ==========================================
# 1. ZFS ARC Tuning (RAM Cache)
# ==========================================
echo -e "${YELLOW}[1/6] ZFS ARC Cache Tuning...${NC}"

# ARC Max: 200 GB (leaves ~56 GB for OS, NFS, page cache)
ARC_MAX=214748364800
# ARC Min: 100 GB (keeps cache hot, prevents aggressive eviction)
ARC_MIN=107374182400

echo $ARC_MAX > /sys/module/zfs/parameters/zfs_arc_max
echo $ARC_MIN > /sys/module/zfs/parameters/zfs_arc_min

# Prefetch distance: 256 MB (default 67 MB — better for large streaming reads)
echo 268435456 > /sys/module/zfs/parameters/zfetch_max_distance

# Async read threads: 8 (default 3 — more parallel disk reads)
echo 8 > /sys/module/zfs/parameters/zfs_vdev_async_read_max_active

# Persist across reboots
cat > /etc/modprobe.d/zfs.conf << EOF
options zfs zfs_arc_max=$ARC_MAX
options zfs zfs_arc_min=$ARC_MIN
options zfs zfetch_max_distance=268435456
options zfs zfs_vdev_async_read_max_active=8
EOF
update-initramfs -u -k all

echo -e "${GREEN}  ✓ ARC Max: 200 GB | ARC Min: 100 GB${NC}"
echo -e "${GREEN}  ✓ Prefetch: 256 MB | Async Reads: 8 threads${NC}"
echo ""

# ==========================================
# 2. Kernel Sysctl Tuning
# ==========================================
echo -e "${YELLOW}[2/6] Kernel Sysctl Tuning...${NC}"

cp /etc/sysctl.conf /etc/sysctl.conf.backup_${TIMESTAMP} 2>/dev/null || true

cat > /etc/sysctl.conf << 'EOF'
# ====================================================================
# NFS STORAGE SERVER OPTIMIZATION — storage300 (256 GB RAM)
# ====================================================================

# --- NFS RPC Performance ---
sunrpc.tcp_slot_table_entries = 128
sunrpc.udp_slot_table_entries = 128

# --- Network Buffers (10GbE, 1MB NFS blocks) ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# --- Network Performance ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.optmem_max = 262144
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1

# --- Memory / Cache Management ---
# vfs_cache_pressure=10: keep file caches in RAM aggressively
vm.vfs_cache_pressure = 10
# swappiness=1: almost never swap (plenty of RAM)
vm.swappiness = 1
# Dirty pages: start background writes early, avoid bursts
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
EOF

sysctl -p > /dev/null 2>&1
echo -e "${GREEN}  ✓ Sysctl applied (BBR, 64MB buffers, vfs_cache_pressure=10)${NC}"
echo ""

# ==========================================
# 3. NFS Server Threads
# ==========================================
echo -e "${YELLOW}[3/6] NFS Server Threads...${NC}"

# Ubuntu 24.04 uses /etc/nfs.conf instead of /etc/default/nfs-kernel-server
if [ -f /etc/nfs.conf ]; then
    if grep -q '^\[nfsd\]' /etc/nfs.conf; then
        sed -i '/^\[nfsd\]/,/^\[/{s/^#\?\s*threads\s*=.*/threads = 512/}' /etc/nfs.conf
    else
        echo -e "\n[nfsd]\nthreads = 512" >> /etc/nfs.conf
    fi
fi

# Also set legacy config if present
if [ -f /etc/default/nfs-kernel-server ]; then
    sed -i 's/^RPCNFSDCOUNT=.*/RPCNFSDCOUNT=512/' /etc/default/nfs-kernel-server 2>/dev/null || true
fi

# Apply immediately
echo 512 > /proc/fs/nfsd/threads 2>/dev/null || true

echo -e "${GREEN}  ✓ NFS Threads: 512${NC}"
echo ""

# ==========================================
# 4. CPU Load Balancing (RPS/XPS)
# ==========================================
echo -e "${YELLOW}[4/6] CPU Load Balancing (RPS/XPS)...${NC}"

# Auto-detect primary interface
IFACE=$(ip -br link | grep UP | grep -v 'lo\|docker\|br-\|veth' | head -1 | awk '{print $1}')
if [ -n "$IFACE" ]; then
    mask=$(printf %x $(( (1 << $(nproc)) - 1 )))
    for rx in /sys/class/net/$IFACE/queues/rx-*; do echo $mask > $rx/rps_cpus 2>/dev/null; done
    for tx in /sys/class/net/$IFACE/queues/tx-*; do echo $mask > $tx/xps_cpus 2>/dev/null; done
    echo -e "${GREEN}  ✓ RPS/XPS on $IFACE — $(nproc) cores (mask: $mask)${NC}"

    # Persist via systemd service
    cat > /etc/systemd/system/network-tuning.service << EOSVC
[Unit]
Description=Network RPS/XPS CPU Distribution
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'IFACE="$IFACE"; mask=\$(printf %%x \$(( (1 << \$(nproc)) - 1 ))); for rx in /sys/class/net/\$IFACE/queues/rx-*; do echo \$mask > \$rx/rps_cpus; done; for tx in /sys/class/net/\$IFACE/queues/tx-*; do echo \$mask > \$tx/xps_cpus; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOSVC
    systemctl daemon-reload
    systemctl enable network-tuning.service > /dev/null 2>&1
else
    echo -e "${RED}  ✗ Could not detect primary interface${NC}"
fi
echo ""

# ==========================================
# 5. Connection Tracking
# ==========================================
echo -e "${YELLOW}[5/6] Connection Tracking...${NC}"

modprobe nf_conntrack 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_max=524288 > /dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=86400 > /dev/null 2>&1 || true

echo -e "${GREEN}  ✓ Conntrack max: 524288 | TCP timeout: 86400s${NC}"
echo ""

# ==========================================
# 6. Verification
# ==========================================
echo -e "${YELLOW}[6/6] Verification...${NC}"
echo ""

ARC_CUR=$(cat /sys/module/zfs/parameters/zfs_arc_max)
ARC_MIN_CUR=$(cat /sys/module/zfs/parameters/zfs_arc_min)
PREFETCH=$(cat /sys/module/zfs/parameters/zfetch_max_distance)
ASYNC_RD=$(cat /sys/module/zfs/parameters/zfs_vdev_async_read_max_active)
THREADS=$(cat /proc/fs/nfsd/threads 2>/dev/null || echo "N/A")
BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
VFS=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null)
SWAP=$(sysctl -n vm.swappiness 2>/dev/null)

echo -e "  ${CYAN}ZFS ARC Max:${NC}        $(echo "scale=0; $ARC_CUR / 1073741824" | bc) GB"
echo -e "  ${CYAN}ZFS ARC Min:${NC}        $(echo "scale=0; $ARC_MIN_CUR / 1073741824" | bc) GB"
echo -e "  ${CYAN}Prefetch Dist:${NC}      $(echo "scale=0; $PREFETCH / 1048576" | bc) MB"
echo -e "  ${CYAN}Async Read Max:${NC}     $ASYNC_RD"
echo -e "  ${CYAN}NFS Threads:${NC}        $THREADS"
echo -e "  ${CYAN}TCP Congestion:${NC}     $BBR"
echo -e "  ${CYAN}VFS Cache Press:${NC}    $VFS"
echo -e "  ${CYAN}Swappiness:${NC}         $SWAP"
echo ""

# Current ARC status
arc_summary 2>/dev/null | head -15 || true
echo ""

free -h
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✓ Storage 300 Optimization Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} ZFS ARC will warm up over the next hours/days."
echo -e "Monitor with: ${CYAN}free -h && arc_summary | head -20${NC}"
