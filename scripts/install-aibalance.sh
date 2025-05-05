#!/bin/bash

# AIBalance Installation and Update Script
# For Linux AMD64 environments

# Set color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Display title
echo -e "${GREEN}=== AIBalance Installation and Update Script ===${NC}"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script with root privileges${NC}"
  exit 1
fi

# Set variables
BASE_URL="https://aliyun-oss.yaklang.com/aibalance"
VERSION_URL="${BASE_URL}/latest/version.txt"
INSTALL_DIR="/root/aibalance"
BINARY_NAME="aibalance"
FULL_PATH="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="/tmp/aibalance_version.txt"
LOCAL_VERSION_FILE="$INSTALL_DIR/version.txt"
SERVICE_PATH="/etc/systemd/system/aibalance.service"
LOG_PATH="$INSTALL_DIR/ai-balance-log.txt"
LOGROTATE_PATH="/etc/logrotate.d/aibalance"
CONFIG_PATH="$INSTALL_DIR/config.yml"

# Create installation directory if it doesn't exist
mkdir -p "$INSTALL_DIR" 2>/dev/null

# Check if service exists
SERVICE_EXISTS=false
if [ -f "$SERVICE_PATH" ]; then
  SERVICE_EXISTS=true
fi

# Get latest version information
echo "Checking for the latest version..."
wget -q "$VERSION_URL" -O "$VERSION_FILE"

if [ $? -ne 0 ]; then
  echo -e "${RED}Failed to retrieve version information. Please check your network connection${NC}"
  exit 1
fi

NEW_VERSION=$(cat "$VERSION_FILE")
echo -e "Latest version: ${GREEN}${NEW_VERSION}${NC}"

# Check currently installed version (if exists)
CURRENT_VERSION="Unknown"
if [ -f "$LOCAL_VERSION_FILE" ]; then
  CURRENT_VERSION=$(cat "$LOCAL_VERSION_FILE")
  echo -e "Currently installed version: ${YELLOW}${CURRENT_VERSION}${NC}"
fi

# Determine if this is a new installation or an update
if [ "$SERVICE_EXISTS" = true ]; then
  echo -e "${GREEN}AIBalance service is already installed.${NC}"
  
  # Ask user to confirm update
  if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
    echo -e "${YELLOW}Current version is the same as the latest version. Update anyway? [y/N]${NC}"
    read -r confirm
    confirm=${confirm:-N}
  else
    echo -e "Update to version ${GREEN}${NEW_VERSION}${NC}? [Y/n]"
    read -r confirm
    confirm=${confirm:-Y}
  fi

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Update cancelled"
    exit 0
  fi
  
  # Proceed with update
  echo "Starting AIBalance update..."
else
  echo -e "${YELLOW}AIBalance service is not installed. Proceeding with new installation...${NC}"
fi

# Stop existing service if it exists
if [ "$SERVICE_EXISTS" = true ]; then
  echo "Stopping AIBalance service..."
  systemctl stop aibalance 2>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}AIBalance service stopped${NC}"
  else
    echo -e "${YELLOW}Failed to stop AIBalance service. Continuing deployment...${NC}"
  fi
fi

# Backup old version (if exists)
if [ -f "$FULL_PATH" ]; then
  echo "Backing up existing AIBalance binary..."
  mv "$FULL_PATH" "${FULL_PATH}.bak"
  echo -e "${GREEN}Backup completed: ${FULL_PATH}.bak${NC}"
fi

# Use version number to build download URL, avoiding CDN cache
DOWNLOAD_URL="${BASE_URL}/${NEW_VERSION}/aibalance"
echo "Downloading AIBalance from $DOWNLOAD_URL..."
wget "$DOWNLOAD_URL" -O "$FULL_PATH"

if [ $? -ne 0 ]; then
  echo -e "${RED}Download failed. Please check your network connection or download URL${NC}"
  
  # Restore backup
  if [ -f "${FULL_PATH}.bak" ]; then
    echo "Restoring backup..."
    mv "${FULL_PATH}.bak" "$FULL_PATH"
  fi
  
  exit 1
fi

# Set execution permissions
echo "Setting execution permissions..."
chmod +x "$FULL_PATH"

# Save new version information
echo "$NEW_VERSION" > "$LOCAL_VERSION_FILE"
echo -e "${GREEN}Version information updated in $LOCAL_VERSION_FILE${NC}"

# Config file creation or update
CONFIG_NEEDS_UPDATE=false
if [ ! -f "$CONFIG_PATH" ]; then
  CONFIG_NEEDS_UPDATE=true
  echo -e "${YELLOW}No configuration file found. Will create a new one.${NC}"
else
  if [ "$SERVICE_EXISTS" = false ]; then
    echo -e "${YELLOW}Configuration file exists. Do you want to update it? [y/N]${NC}"
    read -r update_config
    if [[ "$update_config" =~ ^[Yy]$ ]]; then
      CONFIG_NEEDS_UPDATE=true
    fi
  fi
fi

if [ "$CONFIG_NEEDS_UPDATE" = true ]; then
  echo -e "${YELLOW}Please set an admin password for AIBalance:${NC}"
  read -s -p "Enter admin password: " ADMIN_PASSWORD
  echo ""
  
  # Create config.yml with the provided password
  cat > "$CONFIG_PATH" <<EOF
admin-password: "$ADMIN_PASSWORD"
keys: []
models:
  - name: "gemini-2.0-flash"
    providers: []
  - name: "gemini-2.5-flash"
    providers: []
  - name: "gemini-2.5-pro"
    providers: []
EOF
  echo -e "${GREEN}Configuration file created at $CONFIG_PATH${NC}"
  echo -e "${YELLOW}Remember to update the configuration with your API providers later.${NC}"
fi

# If service doesn't exist, set it up
if [ "$SERVICE_EXISTS" = false ]; then
  echo "Setting up AIBalance service..."
  
  echo "Select log management method:"
  echo "1) Use systemd journald (recommended, auto-rotation, no log file needed)"
  echo "2) Output to log file and rotate with logrotate (if you need a specific log file)"
  read -p "Enter 1 or 2, then press Enter: " LOGMODE

  if [[ "$LOGMODE" == "1" ]]; then
    # Configure systemd journald logging
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AI Balance Service
After=network.target

[Service]
Type=simple
ExecStart=$FULL_PATH --listen 127.0.0.1:8223 -c $INSTALL_DIR/config.yml
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Set journald log rotation policy
    sed -i.bak '/^SystemMaxUse/d;/^SystemMaxFileSize/d' /etc/systemd/journald.conf
    echo "SystemMaxUse=1G" >> /etc/systemd/journald.conf
    echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
    systemctl restart systemd-journald

    echo "Configured systemd journald for logging with auto-rotation."
  else
    # Configure tee + logrotate logging
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AI Balance Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '$FULL_PATH --listen 127.0.0.1:8223 -c $INSTALL_DIR/config.yml 2>&1 | tee -a $LOG_PATH'
Restart=always
RestartSec=3
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

    # Write logrotate configuration
    cat > "$LOGROTATE_PATH" <<EOF
$LOG_PATH {
    size 100M
    rotate 10
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    touch "$LOG_PATH"
    chmod 644 "$LOG_PATH"

    echo "Configured logging to $LOG_PATH with logrotate rotation."
  fi
fi

# Enable and restart the service
echo "Reloading systemd configuration..."
systemctl daemon-reload

echo "Enabling AIBalance service to start on boot..."
systemctl enable aibalance

echo "Starting AIBalance service..."
systemctl restart aibalance

if [ $? -eq 0 ]; then
  echo -e "${GREEN}AIBalance service successfully started${NC}"
else
  echo -e "${RED}Failed to start AIBalance service. Please check service configuration${NC}"
  exit 1
fi

# Check service status
echo "Checking service status..."
systemctl status aibalance --no-pager

echo -e "${GREEN}AIBalance ${SERVICE_EXISTS:+"update":"installation"} completed! Current version: ${NEW_VERSION}${NC}"
echo "-----------------------------------------"
echo "AIBalance service deployment completed!"
echo "Check service status: systemctl status aibalance"
if [[ "$LOGMODE" == "1" || "$SERVICE_EXISTS" = true ]]; then
  echo "View logs: journalctl -u aibalance -f"
else
  echo "View logs: tail -f $LOG_PATH"
fi
echo "-----------------------------------------"

# Clean up temporary files
rm -f "$VERSION_FILE"

