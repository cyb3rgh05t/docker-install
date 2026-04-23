#!/bin/bash
INTERFACE="enp65s0f0" # Dein 10G Interface
S1="168.119.199.33"
S2="168.119.199.34"
LOGFILE="/var/log/streaming_stats.log"

echo "Monitoring gestartet. Logs unter $LOGFILE"
echo "Datum,Zeit,Download_Mbit,S1_Pipes,S2_Pipes,RAM_Cache,Retrans" >> $LOGFILE

while true; do
    # 1. Bandbreite berechnen
    RX_PREV=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    sleep 2
    RX_NEXT=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    MBPS=$(echo "scale=2; ($RX_NEXT - $RX_PREV) * 8 / 1024 / 1024 / 2" | bc)

    # 2. Pipes und RAM-Werte sammeln
    CONN1=$(ss -ant | grep :2049 | grep $S1 | wc -l)
    CONN2=$(ss -ant | grep :2049 | grep $S2 | wc -l)
    CACHE=$(free -m | awk '/Mem:/ {print $6}') # in MB für leichtere Log-Analyse
    RETR=$(nstat -az TcpRetransSegs | awk 'NR==2 {print $2}')

    # 3. Log-Eintrag erstellen (CSV-Format für Excel/Grafik-Tools)
    TIMESTAMP=$(date +'%Y-%m-%d,%H:%M:%S')
    LOG_LINE="$TIMESTAMP,$MBPS,$CONN1,$CONN2,$CACHE,$RETR"
    echo "$LOG_LINE" >> $LOGFILE

    # 4. Saubere Konsolenausgabe (flackert nicht)
    clear
    echo "--- LIVE STREAMING REPORT [$TIMESTAMP] ---"
    echo "----------------------------------------------------"
    echo -e "AKTUELLER DOWNLOAD: \033[1;32m$MBPS Mbit/s\033[0m"
    echo "Hetzner S1 Pipes: $CONN1/16 | Hetzner S2 Pipes: $CONN2/16"
    echo "RAM im Cache:     $CACHE MB"
    echo "TCP Retrans:      $RETR"
    echo "----------------------------------------------------"
    echo "Logdatei: tail -f $LOGFILE"
done
