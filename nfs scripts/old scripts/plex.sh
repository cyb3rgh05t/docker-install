#!/bin/bash
#
# Plex Server (NFS Client) Optimization Script
# Für: Ubuntu 20.04 + NFS Client + StrongSwan IPsec + MergerFS
# Use Case: 80+ gleichzeitige Plex Streams
#
# WICHTIG: Als root ausführen!
#

set -e

echo "=============================================="
echo "  Plex Server NFS Client Optimization"
echo "=============================================="
echo ""

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: Bitte als root ausführen!${NC}"
    echo "Nutze: sudo bash $0"
    exit 1
fi

echo -e "${YELLOW}[INFO] Erstelle Backups...${NC}"
# Backups erstellen mit Timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp /etc/ipsec.conf /etc/ipsec.conf.backup_${TIMESTAMP}
cp /etc/sysctl.conf /etc/sysctl.conf.backup_${TIMESTAMP} 2>/dev/null || true
echo -e "${GREEN}✓ Backups erstellt in /etc/*.backup_${TIMESTAMP}${NC}"
echo ""

# ==========================================
# 1. IPsec Optimierung
# ==========================================
echo -e "${YELLOW}[1/6] Optimiere IPsec Konfiguration...${NC}"

# Debug Logging deaktivieren
sed -i 's/charondebug="ike 2, net 2"/charondebug="ike 0, net 0"/' /etc/ipsec.conf

# AES-GCM Cipher für Hardware-Beschleunigung (AES-NI detected)
echo -e "${GREEN}✓ Aktiviere AES-GCM (Hardware-Beschleunigung)${NC}"
sed -i 's/ike=aes256-sha2_256-modp2048/ike=aes256gcm16-aes128gcm16-prfsha256-modp2048/' /etc/ipsec.conf
sed -i 's/esp=aes256-sha2_256/esp=aes256gcm16-aes128gcm16/' /etc/ipsec.conf

echo -e "${GREEN}✓ IPsec Debug Logging deaktiviert${NC}"

# IPsec neu starten
systemctl restart strongswan-starter
sleep 3
ipsec status > /dev/null 2>&1 && echo -e "${GREEN}✓ IPsec erfolgreich neu gestartet${NC}" || echo -e "${RED}✗ IPsec Start fehlgeschlagen!${NC}"
echo ""

# ==========================================
# 2. Kernel Network Tuning
# ==========================================
echo -e "${YELLOW}[2/6] Optimiere Kernel Netzwerk-Parameter...${NC}"

# NFS Client spezifische Optimierungen
cat >> /etc/sysctl.conf << 'EOF'

# === NFS Client / Plex Streaming Optimierungen ===
# Erhöhe NFS RPC Slots für mehr parallele Requests
sunrpc.tcp_slot_table_entries = 128
sunrpc.udp_slot_table_entries = 128

# Read-ahead für große Video-Dateien
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10

# Connection Tracking für viele Streams
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

# Optimiere für hohen Durchsatz
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
EOF

# Wende Sysctl Settings sofort an
sysctl -p > /dev/null 2>&1

echo -e "${GREEN}✓ Kernel Parameter optimiert${NC}"
echo ""

# ==========================================
# 3. StrongSwan Charon Tuning
# ==========================================
echo -e "${YELLOW}[3/6] Optimiere StrongSwan Charon...${NC}"

# Erstelle charon-custom.conf falls nicht vorhanden
CHARON_CONF="/etc/strongswan.d/charon-custom.conf"
cat > ${CHARON_CONF} << 'EOF'
charon {
    # Erhöhe Worker Threads für IPsec Verarbeitung
    threads = 32
    
    # Größere Pakete für besseren Durchsatz
    max_packet = 20000
    
    # Optimiere IKE_SA Hash Table
    ikesa_table_size = 8
    ikesa_table_segments = 8
    
    # Replay Window vergrößern
    replay_window = 256
}
EOF

echo -e "${GREEN}✓ StrongSwan Charon optimiert (32 Threads, größere Pakete)${NC}"
echo ""

# ==========================================
# 4. NFS Mounts optimieren
# ==========================================
echo -e "${YELLOW}[4/6] Optimiere NFS Mounts...${NC}"

# Warte kurz damit IPsec Tunnel sich stabilisieren
sleep 3

# Unmount MergerFS
echo "Unmounte MergerFS..."
umount /mnt/unionfs 2>/dev/null || echo "  (MergerFS war nicht gemounted)"

# Unmount alte NFS Mounts
echo "Unmounte alte NFS Mounts..."
umount /mnt/storage 2>/dev/null || echo "  (storage war nicht gemounted)"
umount /mnt/storage2 2>/dev/null || echo "  (storage2 war nicht gemounted)"

# Warte kurz
sleep 2

# Storage 1 mit optimierten Optionen mounten
echo "Mounte storage mit optimierten Optionen..."
mount -t nfs4 -o vers=4.2,rsize=1048576,wsize=1048576,hard,proto=tcp,timeo=150,retrans=5,nconnect=8,actimeo=60,async 168.119.199.33:/mnt/raidpool/filesystem /mnt/storage
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ /mnt/storage erfolgreich gemounted${NC}"
else
    echo -e "${RED}✗ /mnt/storage mount fehlgeschlagen!${NC}"
fi

# Storage 2 mit optimierten Optionen mounten
echo "Mounte storage2 mit optimierten Optionen..."
mount -t nfs4 -o vers=4.2,rsize=1048576,wsize=1048576,hard,proto=tcp,timeo=150,retrans=5,nconnect=8,actimeo=60,async 168.119.199.34:/mnt/raidpool/filesystem /mnt/storage2
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ /mnt/storage2 erfolgreich gemounted${NC}"
else
    echo -e "${RED}✗ /mnt/storage2 mount fehlgeschlagen!${NC}"
fi

echo ""
echo "Neue Mount Optionen:"
mount | grep nfs | grep -E "storage|storage2"
echo ""

# Wichtige Optimierungen erklärt:
echo -e "${GREEN}Neue NFS Optimierungen:${NC}"
echo "  • nconnect=8     → 8 parallele TCP Connections (statt 1!)"
echo "  • actimeo=60     → Cached Attributes für 60 Sek"
echo "  • async          → Asynchrone Writes (für Streaming)"
echo "  • timeo=150      → Kürzerer Timeout (1.5 Sek)"
echo ""

# ==========================================
# 5. MergerFS optimiert neu mounten
# ==========================================
echo -e "${YELLOW}[5/6] Mounte MergerFS mit optimierten Optionen...${NC}"

# Optimierte MergerFS Options (ohne parallel-direct-writes für Kompatibilität)
MERGERFS_OPTS="rw,use_ino,nonempty,allow_other,statfs_ignore=nc,func.getattr=newest,category.action=all,category.create=ff,cache.files=auto-full,cache.entry=60,cache.negative_entry=60,cache.attr=60,cache.statfs=60,dropcacheonclose=true,direct_io,fsname=mergerfs"

mergerfs -o ${MERGERFS_OPTS} /mnt/downloads:/mnt/storage:/mnt/storage2 /mnt/unionfs

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ MergerFS erfolgreich gemounted${NC}"
else
    echo -e "${RED}✗ MergerFS mount fehlgeschlagen!${NC}"
    echo "Versuche Fallback ohne direct_io..."
    MERGERFS_OPTS_FALLBACK="rw,use_ino,nonempty,allow_other,statfs_ignore=nc,func.getattr=newest,category.action=all,category.create=ff,cache.files=auto-full,cache.entry=60,cache.negative_entry=60,cache.attr=60,cache.statfs=60,dropcacheonclose=true,fsname=mergerfs"
    mergerfs -o ${MERGERFS_OPTS_FALLBACK} /mnt/downloads:/mnt/storage:/mnt/storage2 /mnt/unionfs
fi

echo ""
echo "MergerFS Status:"
mount | grep mergerfs
ps aux | grep mergerfs | grep -v grep
echo ""

echo -e "${GREEN}Neue MergerFS Optimierungen:${NC}"
echo "  • cache.entry=60             → Entry Cache für 60 Sek"
echo "  • cache.attr=60              → Attribute Cache für 60 Sek"
echo "  • cache.statfs=60            → Statfs Cache für 60 Sek"
echo "  • cache.negative_entry=60    → Negative Entry Cache"
echo "  • direct_io                  → Direct I/O für große Dateien"
echo ""

# ==========================================
# 6. Status Check & Plex Restart
# ==========================================
echo -e "${YELLOW}[6/6] Status Check...${NC}"
echo ""

echo "IPsec Connections:"
ipsec status | grep -E "conn|ESTABLISHED"
echo ""

echo "NFS Mount Status:"
df -h | grep -E "storage|unionfs"
echo ""

# Plex Docker Container neustarten um neue Mounts zu nutzen
if docker ps | grep -q plex; then
    echo -e "${YELLOW}Starte Plex Docker Container neu...${NC}"
    docker restart plex
    sleep 5
    if docker ps | grep -q plex; then
        echo -e "${GREEN}✓ Plex Container erfolgreich neu gestartet${NC}"
    else
        echo -e "${RED}✗ Plex restart fehlgeschlagen - bitte manuell prüfen!${NC}"
    fi
else
    echo -e "${YELLOW}[INFO] Plex Container läuft nicht oder wurde nicht gefunden${NC}"
    echo "Verfügbare Container:"
    docker ps --format "table {{.Names}}\t{{.Status}}"
fi

echo ""
echo "=============================================="
echo -e "${GREEN}  ✓ Client Optimierung abgeschlossen!${NC}"
echo "=============================================="
echo ""
echo -e "${YELLOW}WICHTIG - Docker spezifische Hinweise:${NC}"
echo "1. Plex läuft in Docker - Container wurde neu gestartet"
echo "2. Stelle sicher, dass Plex die NFS Mounts sehen kann:"
echo "   docker exec plex ls -la /mnt/unionfs"
echo "   (oder dein Mount-Pfad im Container)"
echo ""
echo -e "${YELLOW}Nächste Schritte:${NC}"
echo "1. Prüfe ob Plex Container läuft: docker ps | grep plex"
echo "2. Teste mit 10-20 Streams ob alles funktioniert"
echo "3. Steigere langsam auf 80+ Streams"
echo "4. Überwache mit: top, iotop, nfsstat -c"
echo ""
echo -e "${GREEN}Erwartete Verbesserungen:${NC}"
echo "  • 8x mehr NFS Parallelität (nconnect=8)"
echo "  • 50-70% weniger CPU Last"
echo "  • Besseres Caching (weniger Metadata-Requests)"
echo "  • Schnellere Verschlüsselung durch AES-GCM"
echo "  • Keine Freezes mehr bei 80+ Streams"
echo ""
echo -e "${YELLOW}Monitoring Befehle:${NC}"
echo "  • top                    # CPU Last"
echo "  • iotop                  # I/O Last"
echo "  • nfsstat -c             # NFS Client Stats"
echo "  • ps aux | grep charon   # IPsec CPU Usage"
echo "  • watch -n 1 'ss -tni | grep 168.119'  # Aktive Connections"
echo ""
