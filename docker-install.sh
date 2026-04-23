#!/bin/bash

# ==============================================================================
# SCRIPT: Ultimate Docker Deployer (Pro Edition)
# DESCRIPTION: Automated Setup for Docker, VPN-Proxy, and NFS-MergerFS Stacks
# LOGGING: /var/log/docker_system_setup.log
# ==============================================================================

# --- Configuration & Colors ---
LOG_FILE="/var/log/docker_system_setup.log"
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Logging & Helper Functions ---
log() {
    local MESSAGE="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "$MESSAGE" >> "$LOG_FILE"
}

section_title() {
    echo -e "\n${CYAN}====================================================${NC}"
    echo -e "${CYAN}>>> $1${NC}"
    echo -e "${CYAN}====================================================${NC}"
}

success_msg() {
    echo -e "${GREEN}[OK]${NC} $1"
}

error_exit() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run with sudo/root privileges."
fi

# --- 1. Main Menu ---
clear
echo -e "${BLUE}====================================================${NC}"
echo -e "${YELLOW}          CHOOSE INSTALLATION OPTION               ${NC}"
echo -e "${BLUE}====================================================${NC}"
echo -e "1) ${GREEN}DOCKSERVER${NC}               (External Script: git.io/J3GDc)"
echo -e "2) ${GREEN}Docker Full Setup${NC}         (Complete Docker + Compose System)"
echo -e "3) ${GREEN}Docker VPN-Proxy System${NC}   (Docker + VPN-Proxy Container Selection)"
echo -e "4) ${GREEN}Docker NFS-MergerFS System${NC} (Docker + NFS-MergerFS Container Selection)"
echo -e "5) ${RED}Cancel${NC}"
echo -e "${BLUE}====================================================${NC}"
read -rp "Selection [1-5]: " main_choice

case $main_choice in
    1)
        log "Switching to DOCKSERVER..."
        wget -qO- https://git.io/J3GDc | sudo bash
        exit 0
        ;;
    2) log "Option 2 selected: Docker Full Setup..." ;;
    3) log "Option 3 selected: Docker VPN-Proxy System..." ;;
    4) log "Option 4 selected: Docker NFS-MergerFS System..." ;;
    5) echo "Exiting..."; exit 0 ;;
    *) error_exit "Invalid selection." ;;
esac

# --- 2. Container Selection ---
if [[ "$main_choice" == "3" ]]; then
    echo -e "\n${YELLOW}[SELECTION] Which VPN-Proxy containers should be deployed?${NC}"
    echo -e "Options: (v)pn-proxy, (d)ockhand"
    echo -e "${CYAN}Tip: Just press Enter to install ALL containers.${NC}"
    read -rp "Your choice [v d]: " container_selection
    [[ -z "$container_selection" ]] && container_selection="v d"
fi

if [[ "$main_choice" == "4" ]]; then
    echo -e "\n${YELLOW}[SELECTION] Which NFS-MergerFS containers should be deployed?${NC}"
    echo -e "Options: (n)fs-mount, (d)ockhand"
    echo -e "${CYAN}Tip: Just press Enter to install ALL containers.${NC}"
    read -rp "Your choice [n d]: " container_selection
    [[ -z "$container_selection" ]] && container_selection="n d"
fi

# --- 3. System Preparation ---
section_title "System Preparation & Updates"
log "Updating package lists and upgrading system..."
sudo apt-get update -yqq >> "$LOG_FILE" 2>&1 && success_msg "Package lists updated."
sudo apt-get upgrade -yqq >> "$LOG_FILE" 2>&1 && success_msg "System packages upgraded."
sudo apt-get autoclean -yqq >> "$LOG_FILE" 2>&1 && success_msg "Package cache cleaned."

log "Installing base utilities..."
PACKAGES=(python3.12 python3-pip git update-motd curl gnupg2 software-properties-common figlet)

for pkg in "${PACKAGES[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg "; then
        echo -e "${YELLOW}[SKIP]${NC} $pkg is already installed."
    else
        echo -n -e "${BLUE}[INSTALL]${NC} Installing $pkg... "
        apt-get install -yqq "$pkg" >> "$LOG_FILE" 2>&1
        echo -e "${GREEN}Done.${NC}"
    fi
done

log "Handling Python EXTERNALLY-MANAGED marker (if present)..."
if [ -f "/usr/lib/python3.12/EXTERNALLY-MANAGED" ]; then
    mv /usr/lib/python3.12/EXTERNALLY-MANAGED /usr/lib/python3.12/EXTERNALLY-MANAGED.bak >> "$LOG_FILE" 2>&1
    success_msg "EXTERNALLY-MANAGED renamed to .bak"
else
    echo -e "${YELLOW}[SKIP]${NC} /usr/lib/python3.12/EXTERNALLY-MANAGED not found."
fi

clear
figlet -f slant "Docker Setup"

# --- 4. Docker Engine Installation ---
section_title "Docker Engine & Legacy Support"
log "Removing old Docker versions if existing..."
apt-get remove -yqq docker docker-engine docker.io containerd runc >> "$LOG_FILE" 2>&1

log "Setting up Docker GPG Keyring..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes >> "$LOG_FILE" 2>&1
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(. /etc/os-release; echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

log "Installing Docker Engine and Plugins..."
apt-get update -yqq >> "$LOG_FILE" 2>&1
apt-get install -yqq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1
success_msg "Docker Engine installed."

log "Starting Docker service..."
systemctl daemon-reload
systemctl enable --now docker >> "$LOG_FILE" 2>&1

# Wait for Daemon
echo -n -e "${BLUE}[WAIT]${NC} Waiting for Docker Daemon... "
RETRIES=0
while ! docker info >/dev/null 2>&1; do
    echo -n "."
    [ $RETRIES -gt 2 ] && { systemctl stop docker.socket; systemctl restart docker; } >> "$LOG_FILE" 2>&1
    [ $RETRIES -gt 5 ] && error_exit "Docker Daemon failed to start."
    sleep 2
    ((RETRIES++))
done
echo -e " ${GREEN}Online!${NC}"

# Legacy docker-compose fix
log "Creating legacy symlink for 'docker-compose'..."
ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
success_msg "Symlink created."

# --- 5. Networks & Plugins ---
section_title "Docker Networks & Volume Plugins"
log "Installing Local-Persist Volume Plugin..."
curl -fsSL https://raw.githubusercontent.com/MatchbookLab/local-persist/master/scripts/install.sh | sudo bash >> "$LOG_FILE" 2>&1

log "Creating 'proxy' network..."
if [ -z "$(docker network ls --filter name=^proxy$ --format="{{.Name}}")" ]; then
    docker network create proxy >> "$LOG_FILE" 2>&1
    success_msg "Network 'proxy' created."
else
    echo -e "${YELLOW}[INFO]${NC} Network 'proxy' already exists."
fi

# --- 6. GitHub Repository Sync ---
section_title "GitHub Data Synchronization"
log "Cloning repository (Branch: main)..."
TEMP_GIT="/tmp/docker-setup-repo"
rm -rf "$TEMP_GIT"
git clone -b main https://github.com/cyb3rgh05t/cyb3rgh05t.git "$TEMP_GIT" >> "$LOG_FILE" 2>&1

REPO_UTILS_DIR="$TEMP_GIT/utils"

if [ ! -d "$REPO_UTILS_DIR" ]; then
    error_exit "Source directory not found in repository: $REPO_UTILS_DIR"
fi

echo -e "${BLUE}[COPY]${NC} Moving project files to /opt..."
mkdir -p /opt

case $main_choice in
    2) FOLDERS_TO_COPY=(motd) ;;
    3) FOLDERS_TO_COPY=(vpn-proxy motd) ;;
    4) FOLDERS_TO_COPY=(nfs-mergerfs motd) ;;
esac

for folder in "${FOLDERS_TO_COPY[@]}"; do
    if [ -d "$REPO_UTILS_DIR/$folder" ]; then
        rm -rf "/opt/$folder"
        cp -r "$REPO_UTILS_DIR/$folder" /opt/
    else
        error_exit "Source folder not found in repository: $REPO_UTILS_DIR/$folder"
    fi
done

if [ "$SUDO_USER" ]; then
    for folder in "${FOLDERS_TO_COPY[@]}"; do
        chown -R "$SUDO_USER":"$SUDO_USER" "/opt/$folder"
    done
fi

success_msg "Folders moved to /opt successfully."
rm -rf "$TEMP_GIT"

# --- 7. MOTD Setup ---
section_title "MOTD Configuration"
log "Deploying dynamic MOTD..."

chmod -x /etc/update-motd.d/* 2>/dev/null || true
mkdir -p /etc/update-motd.d
chmod 0775 /etc/update-motd.d

MOTD_FILES=(00-header 10-sysinfo 30-diskinfo 90-updates-available 98-reboot-required)
for motd_file in "${MOTD_FILES[@]}"; do
    if [ -f "/opt/motd/$motd_file" ]; then
        cp "/opt/motd/$motd_file" "/etc/update-motd.d/$motd_file"
        chmod 0775 "/etc/update-motd.d/$motd_file"
        success_msg "MOTD file deployed: $motd_file"
    else
        echo -e "${YELLOW}[SKIP]${NC} MOTD file not found: /opt/motd/$motd_file"
    fi
done

log "Installing lolcat (pip)..."
pip3 install lolcat >> "$LOG_FILE" 2>&1 && success_msg "lolcat installed." \
    || echo -e "${YELLOW}[WARN]${NC} lolcat install failed (non-critical)."

success_msg "MOTD configured successfully."

# --- 8. Container Deployment ---
deploy_compose() {
    local file=$1
    local name=$2
    if [[ -f "$file" ]]; then
        echo -e "${BLUE}[DEPLOYING]${NC} Starting $name container..."
        docker-compose -f "$file" up -d >> "$LOG_FILE" 2>&1
        success_msg "$name is up and running."
    else
        echo -e "${RED}[ERROR]${NC} $file not found!"
    fi
}

if [[ "$main_choice" == "3" ]]; then
    section_title "VPN-Proxy Container Deployment"
    cd /opt/vpn-proxy || error_exit "Directory /opt/vpn-proxy missing."
    [[ "$container_selection" =~ "v" ]] && deploy_compose "vpn-proxy.yml" "VPN-Proxy"
    [[ "$container_selection" =~ "d" ]] && deploy_compose "dockhand.yml" "Dockhand"
fi

if [[ "$main_choice" == "4" ]]; then
    section_title "NFS-MergerFS Container Deployment"
    cd /opt/nfs-mergerfs || error_exit "Directory /opt/nfs-mergerfs missing."
    [[ "$container_selection" =~ "n" ]] && deploy_compose "nfs-mount.yml" "NFS-Mount"
    [[ "$container_selection" =~ "d" ]] && deploy_compose "dockhand.yml" "Dockhand"
fi

# --- 9. Final Status Report ---
section_title "Installation Final Report"
[ "$SUDO_USER" ] && usermod -aG docker "$SUDO_USER"
apt-get autoremove -yqq >> "$LOG_FILE" 2>&1

echo -e "\n${BLUE}[SYSTEM VERSIONS]${NC}"
echo -e "  - Docker:         $(docker --version)"
echo -e "  - Compose:        $(docker-compose version --short)"
echo -e "  - Python:         $(python3 --version)"

echo -e "\n${BLUE}[NETWORK STATUS]${NC}"
docker network ls --filter "name=proxy" --format "  Network: {{.Name}} ({{.Driver}})"

echo -e "\n${BLUE}[CONTAINER STATUS]${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "\n${BLUE}[PERSISTENCE STATUS]${NC}"
if systemctl is-active --quiet local-persist; then
    echo -e "  Local-Persist:  ${GREEN}ACTIVE${NC}"
else
    echo -e "  Local-Persist:  ${RED}FAILED/INACTIVE${NC}"
fi

echo -e "\n${CYAN}====================================================${NC}"
echo -e "${GREEN}SUCCESS! Your system is ready to use.${NC}"
echo -e "Check logs at: ${YELLOW}$LOG_FILE${NC}"
if [ "$SUDO_USER" ]; then
    echo -e "${RED}IMPORTANT:${NC} Please logout and login again for Docker group permissions!"
fi
echo -e "${CYAN}====================================================${NC}"
figlet -f small "COMPLETE"