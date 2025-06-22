#!/bin/bash

# === AyurAyush End-to-End Deployment Script ===
# This script sets up backend (Spring Boot), frontend (Flutter Web), PostgreSQL DB, and NGINX on Ubuntu
# Assumes: clean Azure Ubuntu VM with internet access

set -e

# --- Configurable Variables ---
PROJECT_DIR="/root"
SPRING_BACKEND_REPO="https://github.com/athricovil/AAbackend.git"
FLUTTER_FRONTEND_REPO="https://github.com/athricovil/AA.git"
DB_NAME="ayurdb"
DB_USER="ayuruser"
DB_PASS="ayurpass"
JWT_SECRET=$(openssl rand -base64 32)

# --- Install Dependencies ---
echo "[1/10] Installing system dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y openjdk-17-jdk maven git nginx postgresql postgresql-contrib unzip curl xz-utils libglu1-mesa

# --- Set Up PostgreSQL ---
echo "[2/10] Setting up PostgreSQL..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'" | grep -q 1 || sudo -u postgres psql -c "CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

# --- Enable remote access to PostgreSQL ---
echo "[3/10] Enabling PostgreSQL remote access..."
PG_CONF=$(find /etc/postgresql -name postgresql.conf)
PG_HBA=$(find /etc/postgresql -name pg_hba.conf)
sudo sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
MY_IP=$(curl -s ifconfig.me)
echo "host    all             all             $MY_IP/32               md5" | sudo tee -a "$PG_HBA"
sudo systemctl restart postgresql

# --- Clone and Build Backend ---
echo "[4/10] Cloning backend repo..."
cd $PROJECT_DIR
[ -d "AAbackend" ] && rm -rf AAbackend
git clone $SPRING_BACKEND_REPO AAbackend
cd AAbackend/server

# Inject DB config into Spring Boot
cat <<EOL > src/main/resources/application.properties
spring.datasource.url=jdbc:postgresql://localhost:5432/$DB_NAME
spring.datasource.username=$DB_USER
spring.datasource.password=$DB_PASS
spring.jpa.hibernate.ddl-auto=update
server.port=8080
jwt.secret=$JWT_SECRET
EOL

mvn clean package -DskipTests -Dmaven.compiler.release=17

# --- Create systemd service for backend ---
echo "[5/10] Creating systemd service for backend..."
cat <<EOL | sudo tee /etc/systemd/system/aabackend.service
[Unit]
Description=AyurAyush Spring Boot Backend
After=network.target

[Service]
User=root
WorkingDirectory=$PROJECT_DIR/AAbackend/server
ExecStart=/usr/bin/java -jar $PROJECT_DIR/AAbackend/server/target/server-0.0.1-SNAPSHOT.jar
SuccessExitStatus=143
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable aabackend
sudo systemctl start aabackend

# --- Install Flutter ---
echo "[6/10] Installing Flutter..."
cd $PROJECT_DIR
[ -d "flutter" ] && rm -rf flutter
git clone https://github.com/flutter/flutter.git -b stable
export PATH="$PROJECT_DIR/flutter/bin:$PATH"
echo 'export PATH="/root/flutter/bin:$PATH"' >> ~/.bashrc

flutter doctor

# --- Build Flutter Web App ---
echo "[7/10] Cloning and building Flutter frontend..."
cd $PROJECT_DIR
[ -d "AAfrontend" ] && rm -rf AAfrontend
git clone $FLUTTER_FRONTEND_REPO AAfrontend
cd AAfrontend/ayurayush_new
flutter pub get
flutter build web

# --- Deploy to NGINX ---
echo "[8/10] Deploying Flutter web app to NGINX..."
sudo rm -rf /var/www/html/*
sudo cp -r build/web/* /var/www/html/
sudo chown -R www-data:www-data /var/www/html/

# --- Configure NGINX ---
echo "[9/10] Configuring NGINX..."
cat <<EOL | sudo tee /etc/nginx/sites-available/default
server {
    listen 80;
    server_name _;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://localhost:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL

sudo nginx -t && sudo systemctl restart nginx

# --- Final Message ---
echo "[10/10] Deployment Complete!"
echo "Visit your app at: http://$(curl -s ifconfig.me)"
echo "Backend runs on port 8080 and is reverse proxied via NGINX"
echo "Database: $DB_NAME | User: $DB_USER | Password: $DB_PASS"
echo "JWT Secret: $JWT_SECRET"
echo "Systemd backend service: sudo systemctl status aabackend"
echo "Make sure port 5432 is open to $MY_IP in Azure NSG for pgAdmin access"

