#!/bin/bash

# AIBalance Forwarder Service Uninstall and Reinstall Script
# Set color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Display title
echo -e "${GREEN}=== AIBalance Forwarder Service Uninstall and Fix Script ===${NC}"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script with root privileges${NC}"
  exit 1
fi

# Set variables
INSTALL_DIR="/root/aibalance"
BINARY_NAME="aibalance"
FULL_PATH="$INSTALL_DIR/$BINARY_NAME"
SERVICE_PATH="/etc/systemd/system/aibalance-forward.service"
LOG_PATH="$INSTALL_DIR/aibalance-forward-log.txt"
LOGROTATE_PATH="/etc/logrotate.d/aibalance-forward"
RULES_PATH="$INSTALL_DIR/rules.yml"
REGISTER_URL="https://aibalance.yaklang.com/forwarder/register"

# Step 1: Stop and disable the current service
echo "Stopping and disabling the current AIBalance Forwarder service..."
systemctl stop aibalance-forward 2>/dev/null
systemctl disable aibalance-forward 2>/dev/null
echo -e "${GREEN}Service stopped and disabled${NC}"

# Step 2: Remove the current service file
echo "Removing the current service file..."
if [ -f "$SERVICE_PATH" ]; then
  rm -f "$SERVICE_PATH"
  echo -e "${GREEN}Service file removed${NC}"
else
  echo -e "${YELLOW}Service file not found. Continuing...${NC}"
fi

# Step 3: Create the new service file with the correct URL parameter
echo "Creating new service file with the correct URL parameter..."

echo "Select log management method:"
echo "1) Use systemd journald (recommended, auto-rotation, no log file needed)"
echo "2) Output to log file and rotate with logrotate (if you need a specific log file)"
read -p "Enter 1 or 2, then press Enter: " LOGMODE

if [[ "$LOGMODE" == "1" ]]; then
  # Configure systemd journald logging
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AIBalance Forwarder Service
After=network.target

[Service]
Type=simple
ExecStart=$FULL_PATH forward -c $RULES_PATH --url $REGISTER_URL
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  echo "Configured systemd journald for logging with auto-rotation."
else
  # Configure tee + logrotate logging
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AIBalance Forwarder Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '$FULL_PATH forward -c $RULES_PATH --url $REGISTER_URL 2>&1 | tee -a $LOG_PATH'
Restart=always
RestartSec=3
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

  # Write logrotate configuration if it doesn't exist
  if [ ! -f "$LOGROTATE_PATH" ]; then
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
  fi

  touch "$LOG_PATH" 2>/dev/null
  chmod 644 "$LOG_PATH" 2>/dev/null

  echo "Configured logging to $LOG_PATH with logrotate rotation."
fi

# Step 4: Reload systemd, enable and start the new service
echo "Reloading systemd configuration..."
systemctl daemon-reload

echo "Enabling AIBalance Forwarder service to start on boot..."
systemctl enable aibalance-forward

echo "Starting AIBalance Forwarder service..."
systemctl restart aibalance-forward

# Step 5: Check if service started successfully
sleep 2
if systemctl is-active --quiet aibalance-forward; then
  echo -e "${GREEN}AIBalance Forwarder service successfully started${NC}"
else
  echo -e "${RED}Failed to start AIBalance Forwarder service. Checking logs...${NC}"
  journalctl -u aibalance-forward -n 20 --no-pager
fi

# Step 6: Display service status
echo "Current service status:"
systemctl status aibalance-forward --no-pager

echo "-----------------------------------------"
echo "AIBalance Forwarder service reinstallation completed!"
echo "Check service status: systemctl status aibalance-forward"
if [[ "$LOGMODE" == "1" ]]; then
  echo "View logs: journalctl -u aibalance-forward -f"
else
  echo "View logs: tail -f $LOG_PATH"
fi
echo "-----------------------------------------"

