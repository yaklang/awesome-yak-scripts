#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function for colored echo
print_message() {
    local type=$1
    local message=$2
    case $type in
        "info") echo -e "${YELLOW}[INFO]${NC} $message" ;;
        "success") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "error") echo -e "${RED}[ERROR]${NC} $message" ;;
    esac
}

# Get domain and port first
read -p "[?] Please enter domain name (e.g., example.com): " domain
read -p "[?] Please enter local service port (1-65535): " port

# Port validation
if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    print_message "error" "Invalid port number"
    exit 1
fi

# Check if port is in use
if ! nc -z localhost $port; then
    print_message "error" "Port $port is not responding. Please check if your service is running"
    read -p "Continue anyway? (y/n): " continue
    if [[ "$continue" != "y" && "$continue" != "Y" ]]; then
        exit 1
    fi
fi

# Check if certificate already exists
cert_path="/etc/nginx/ssl/$domain"
if [ -f "$cert_path/fullchain.pem" ] && [ -f "$cert_path/key.pem" ]; then
    print_message "info" "SSL certificate already exists for $domain"
    skip_cert=true
else
    skip_cert=false
    # Ask for installation only if cert doesn't exist
    read -p "[?] Do you want to install required components (acme.sh/nginx/cron)? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_message "error" "Installation cancelled by user"
        exit 1
    fi

    # Package manager detection and installation
    if command -v apt &> /dev/null; then
        print_message "info" "Debian/Ubuntu detected, using APT..."
        sudo apt update
        sudo apt install -y nginx cron curl socat
    elif command -v yum &> /dev/null; then
        print_message "info" "RHEL/CentOS detected, using YUM..."
        sudo yum install -y epel-release
        sudo yum install -y nginx cronie curl socat
    else
        print_message "error" "Unsupported package manager"
        exit 1
    fi

    # Get email and install acme.sh if needed
    read -p "[?] Please enter your email for SSL notifications: " email
    curl https://get.acme.sh | sh -s email=$email
    source ~/.bashrc

    # SSL certificate issuance
    print_message "info" "Issuing SSL certificate..."
    ~/.acme.sh/acme.sh --issue --standalone -d $domain --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"

    if [ $? -ne 0 ]; then
        print_message "error" "Certificate issuance failed"
        exit 1
    fi

    # Certificate installation
    sudo mkdir -p $cert_path
    sudo ~/.acme.sh/acme.sh --install-cert -d $domain \
        --cert-file $cert_path/cert.pem \
        --key-file $cert_path/key.pem \
        --fullchain-file $cert_path/fullchain.pem

    # Set up auto-renewal
    (crontab -l 2>/dev/null; echo "0 0 * * 0 ~/.acme.sh/acme.sh --cron --home ~/.acme.sh && systemctl reload nginx") | crontab -
fi

# Generate Nginx configuration
config_file="/etc/nginx/sites-available/$domain.conf"
sudo tee $config_file > /dev/null <<EOL
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;

    # SSL Configuration
    ssl_certificate $cert_path/fullchain.pem;
    ssl_certificate_key $cert_path/key.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # CORS headers
        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE, PATCH';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE, PATCH' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;

        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # CORS headers
        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE, PATCH';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE, PATCH' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;

        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOL

# Enable configuration
if [ -d "/etc/nginx/sites-enabled" ]; then
    sudo ln -sf $config_file /etc/nginx/sites-enabled/
fi

# Create management script if it doesn't exist
if [ ! -f "/usr/local/bin/ssl-manager" ]; then
    sudo tee /usr/local/bin/ssl-manager > /dev/null <<'EOL'
#!/bin/bash
case "$1" in
    renew)
        ~/.acme.sh/acme.sh --cron --home ~/.acme.sh
        systemctl reload nginx
        ;;
    status)
        systemctl status nginx
        echo "SSL Certificate Status:"
        ~/.acme.sh/acme.sh --list
        ;;
    *)
        echo "Usage: ssl-manager [renew|status]"
        exit 1
        ;;
esac
EOL
    sudo chmod +x /usr/local/bin/ssl-manager
fi

# Test Nginx configuration and manage service
if sudo nginx -t; then
    if systemctl is-active nginx >/dev/null 2>&1; then
        sudo systemctl reload nginx
    else
        sudo systemctl start nginx
    fi
fi

print_message "success" "Deployment completed!"
if [ "$skip_cert" = false ]; then
    print_message "info" "Auto-renewal task has been added"
fi
print_message "info" "Please ensure:"
echo "1. Domain DNS is properly configured to point to this server's IP"
echo "2. Firewall ports 80 and 443 are open"
echo "3. Local service is running on port $port"
echo ""
print_message "info" "Management commands:"
echo "- Check status: ssl-manager status"
echo "- Manual renewal: ssl-manager renew"

