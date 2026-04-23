#!/bin/bash

# --- KONFIGURATION ---
LOGFILE="/mnt/unionfs.log"
DISCORD_WEBHOOK="https://discord.com/api/webhooks/999705430597042397/jlWFa-XkgN-GhUopGGmUCgmiwAsxr5p-zsENN-8UWNHRg_QuQ1Dgh6cSZaIcKp2pPAKv"
TELEGRAM_TOKEN=""       # Hier Token eintragen (optional)
TELEGRAM_CHAT_ID=""     # Hier Chat-ID eintragen (optional)
CHECK_INTERVAL=60       # Watchdog-Intervall (Sekunden)
ETH_DEV="enp65s0f0"     # Dein Haupt-Netzwerk-Interface

# Log file initialisieren
> $LOGFILE

# --- PERFORMANCE SETUP (CPU & TCP OPTIMIZATION) ---
setup_performance() {
    log_message "Optimiere CPU-Lastverteilung (RPS/XPS) für $ETH_DEV..."
    # Last auf alle 64 Kerne verteilen
    mask="ffffffff,ffffffff"
    for rx in /sys/class/net/$ETH_DEV/queues/rx-*; do echo $mask > $rx/rps_cpus; done
    for tx in /sys/class/net/$ETH_DEV/queues/tx-*; do echo $mask > $tx/xps_cpus; done

    log_message "Setze TCP-Buffer und BBR für 3.8 Gbit/s Durchsatz..."
    # TCP Puffer auf 128MB für 10G Strecken
    sysctl -w net.core.rmem_max=134217728 >/dev/null
    sysctl -w net.core.wmem_max=134217728 >/dev/null
    # BBR aktivieren (Essenziell gegen Paketverluste)
    sysctl -w net.core.default_qdisc=fq >/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
    # MTU auf Standard (kein IPsec mehr nötig)
    ip link set dev $ETH_DEV mtu 1500
}

# --- NOTIFICATION & HELPER ---
log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> $LOGFILE
}

format_number() {
    local num=$(echo "$1" | tr -d -c '0-9')
    if [ -z "$num" ]; then echo "0"; return; fi
    if [ ${#num} -gt 15 ]; then echo "Unbegrenzt"; else
        printf "%'d" "$num" 2>/dev/null || echo "$num"
    fi
}

send_notification() {
    local status=$1
    local event_msg=$2
    
    local ip=$(hostname -I | awk '{print $1}')
    local conn=$(ss -ant | grep ':2049' | wc -l)
    local disk=$(df -h /mnt/unionfs 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')
    local load=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | sed 's/ //g')
    local ofiles=$(format_number "$(cat /proc/sys/fs/file-nr | awk '{print $1}')")
    local m1="🔴 Offline"; mountpoint -q /mnt/storage && m1="🟢 Online"
    local m2="🔴 Offline"; mountpoint -q /mnt/storage2 && m2="🟢 Online"

    local color=3066993
    local emoji="🚀"
    [[ "$status" != "SUCCESS" ]] && { color=15158588; emoji="⚠️"; }
    [[ "$status" == "STOP" ]] && { color=9807270; emoji="🛑"; }

    if [[ "$DISCORD_WEBHOOK" =~ ^http ]]; then
        curl -s -H "Content-Type: application/json" -X POST -d @- "$DISCORD_WEBHOOK" <<EOF
{
  "embeds": [{
    "title": "$emoji NFS-MergerFS Report",
    "description": "**Event:** $event_msg",
    "color": $color,
    "fields": [
      { "name": "📡 Netzwerk", "value": "**IP:** \`$ip\`\n**Pipes:** \`$conn\`", "inline": true },
      { "name": "💻 Last", "value": "**Load:** \`$load\`\n**Files:** \`$ofiles\`", "inline": true },
      { "name": "🗄️ Hosts", "value": "**storage300:** $m1\n**storage150:** $m2", "inline": true },
      { "name": "📊 Kapazität", "value": "\`$disk\`", "inline": false }
    ],
    "footer": { "text": "Node: $HOSTNAME • $(date +'%H:%M:%S')" }
  }]
}
EOF
    fi

    if [[ -n "$TELEGRAM_TOKEN" ]]; then
        local tg_msg="<b>$emoji NFS Report</b>%0A<b>Event:</b> $event_msg%0A<b>Load:</b> $load%0A<b>Storage:</b> $m1 | $m2"
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d "chat_id=$TELEGRAM_CHAT_ID&text=$tg_msg&parse_mode=HTML" >/dev/null
    fi
}

# --- LOGIK FUNKTIONEN ---

ping_nfs_servers() {
    log_message "Prüfe Erreichbarkeit der Storage-Server (Direkt-IP)..."
    local nfs_server1="168.119.199.33"
    local nfs_server2="168.119.199.34"
    while true; do
        if ping -c1 -W2 "$nfs_server1" >/dev/null 2>&1 && ping -c1 -W2 "$nfs_server2" >/dev/null 2>&1; then
            log_message "Server erreichbar."
            return 0
        fi
        log_message "Warte auf Netzwerk/Server..."
        sleep 5
    done
}

mount_nfs() {
    log_message "Mounting NFS shares (Turbo Mode - nconnect=16)..."
    # Optimiert für hohe Bandbreite ohne Verschlüsselung
    local OPTS="rw,nfsvers=4.2,rsize=1048576,wsize=1048576,hard,proto=tcp,nconnect=16,timeo=600,retrans=2,noatime,async"
    
    mountpoint -q /mnt/storage || mount -t nfs -o $OPTS "168.119.199.33:/mnt/raidpool/filesystem/" "/mnt/storage" &>/dev/null
    mountpoint -q /mnt/storage2 || mount -t nfs -o $OPTS "168.119.199.34:/mnt/raidpool/filesystem/" "/mnt/storage2" &>/dev/null

    # Read-Ahead Tuning (16MB pro Device für flüssiges 4K Streaming)
    sleep 2
    for bdi in /sys/class/bdi/*; do
        if grep -q "nfs" <(cat $bdi/../device/uevent 2>/dev/null); then echo 16384 > $bdi/read_ahead_kb; fi
    done
}

mount_mergerfs() {
    local unionfs_mount="/mnt/unionfs"
    mountpoint -q "$unionfs_mount" && fusermount -u "$unionfs_mount"
    
    log_message "Starte MergerFS mit Kernel-Cache für 256GB RAM..."
    # Volle Nutzung des RAM-Caches und Splice für Zero-Copy
    mergerfs -o rw,use_ino,nonempty,allow_other,statfs_ignore=nc,func.getattr=newest,category.action=all,category.create=ff,cache.files=partial,dropcacheonclose=true,kernel_cache,splice_move,splice_read,direct_io,fsname=mergerfs "/mnt/downloads:/mnt/storage:/mnt/storage2" "$unionfs_mount" &>>$LOGFILE
	
    
    return $?
}

watchdog() {
    while true; do
        sleep $CHECK_INTERVAL
        # Prüfe physische Test-Dateien auf beiden Mounts
        if [ ! -f "/mnt/storage/.storagecheck/test" ] || [ ! -f "/mnt/storage2/.storagecheck/test2" ]; then
            log_message "CRITICAL: NFS Verbindung verloren! Re-mount wird versucht..."
            send_notification "CRITICAL" "Verbindung zum NFS-Speicher unterbrochen! Reparatur läuft..."
            
            # Versuche Re-Mount
            mount_nfs
            mount_mergerfs
            
            sleep 10
        fi
    done
}

cleanup() {
    log_message "STOP-Signal erhalten. Unmount-Vorgang gestartet..."
    mountpoint -q /mnt/unionfs && fusermount -u /mnt/unionfs
    mountpoint -q /mnt/storage && umount -l /mnt/storage
    mountpoint -q /mnt/storage2 && umount -l /mnt/storage2
    
    send_notification "STOP" "Der Service wurde beendet. Laufwerke wurden sicher getrennt."
    exit 0
}

trap cleanup SIGTERM SIGINT

# --- MAIN ---
main() {
    setup_performance
    ping_nfs_servers
    mount_nfs
    
    sleep 2
    # Check ob .storagecheck Dateien lesbar sind
    if [ -f "/mnt/storage/.storagecheck/test" ] && [ -f "/mnt/storage2/.storagecheck/test2" ]; then
        if mount_mergerfs; then
            send_notification "SUCCESS" "Turbo-Modus aktiv (3.8 Gbit/s Potential). Alle Laufwerke online."
            watchdog
        else
            send_notification "CRITICAL" "MergerFS Mount fehlgeschlagen!"
        fi
    else
        send_notification "CRITICAL" "NFS Mount Validierung fehlgeschlagen! (Testdateien nicht lesbar)"
        # Trotzdem Watchdog starten um es weiter zu versuchen
        watchdog
    fi
}

main