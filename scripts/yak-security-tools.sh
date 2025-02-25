#!/bin/bash

# Check yak binary
YAK_BIN=$(which yak 2>/dev/null)
if [ -z "$YAK_BIN" ]; then
    echo "Error: Yak is not installed. Please install Yak environment first."
    echo "Installation docs: https://yaklang.com/docs/startup"
    exit 1
fi

# Verify script repository
SCRIPT_REPO="https://github.com/yaklang/awesome-yak-scripts.git"
SCRIPT_DIR="/root/awesome-yak-scripts"

if [ ! -d "$SCRIPT_DIR" ]; then
    read -p "Script repository not found. Clone to $SCRIPT_DIR? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [ -z "$REPLY" ]; then
        if ! git clone "$SCRIPT_REPO" "$SCRIPT_DIR"; then
            echo "Error: Failed to clone repository"
            exit 1
        fi
        echo "Repository cloned successfully"
    else
        echo "Operation cancelled"
        exit 0
    fi
fi

# Check if service exists and is running
if systemctl is-active yak-security-tools.service &>/dev/null; then
    echo "Yak security tools service is already running"
    echo "Restarting service..."
    if ! sudo systemctl restart yak-security-tools.service; then
        echo "Error: Failed to restart service"
        exit 1
    fi
    echo "Service restarted successfully"
else
    echo "Installing yak security tools service..."
    if ! sudo systemctl enable yak-security-tools.service; then
        echo "Error: Failed to enable service"
        exit 1
    fi
    if ! sudo systemctl start yak-security-tools.service; then
        echo "Error: Failed to start service" 
        exit 1
    fi
    echo "Service installed and started successfully"
fi


# Validate script path
SCRIPT_PATH="$SCRIPT_DIR/server/security-tools.yak"
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Warning: Security tools script not found at $SCRIPT_PATH"
    read -p "Continue creating service? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
fi

# Create service file
SERVICE_FILE="/etc/systemd/system/yak-security-tools.service"
SERVICE_CONTENT="[Unit]
Description=Yak Security Tools Service
After=network.target

[Service]
Type=simple
Environment=HOME=/root
Environment=XDG_CONFIG_HOME=/root/.config
Environment=XDG_DATA_HOME=/root/.local/share
Environment=XDG_CACHE_HOME=/root/.cache
ExecStart=$YAK_BIN $SCRIPT_PATH
StandardInput=null
StandardOutput=null
StandardError=null
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target"

echo "Generated service file content:"
echo "$SERVICE_CONTENT"
echo

read -p "Write to $SERVICE_FILE? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Operation cancelled"
    exit 0
fi

# Write service file
if ! echo "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null; then
    echo "Error: Failed to write service file"
    exit 1
fi

# Systemd operations
echo "Reloading systemd configuration..."
sudo systemctl daemon-reload

echo "Enabling service..."
sudo systemctl enable yak-security-tools.service

echo "Starting service..."
sudo systemctl start yak-security-tools.service

echo -e "\nDeployment completed. Service status:"
sudo systemctl status yak-security-tools.service --no-pager

