#!/usr/bin/env bash
# deploy.sh — Automated deployment for a Dockerized app to a remote Ubuntu server.
# Usage: ./deploy.sh
# Author: Nkereuwem Peter Elijah
# GitHub: https://github.com/nkereuwemelijah

set -o errexit
set -o nounset
set -o pipefail

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="deploy_${TIMESTAMP}.log"
exec > >(tee -a "$LOGFILE") 2>&1

info()  { printf "\n[INFO] %s\n" "$1"; }
err()   { printf "\n[ERROR] %s\n" "$1" >&2; }
fatal() { err "$1"; exit "${2:-1}"; }

trap 'err "Script interrupted. See $LOGFILE for progress."; exit 2' INT TERM

# -------- Helper functions --------
prompt() {
  local varname="$1" prompt_text="$2" default="${3:-}"
  local val
  if [ -n "$default" ]; then
    read -rp "$prompt_text [$default]: " val
    : "${val:=$default}"
  else
    read -rp "$prompt_text: " val
    while [ -z "$val" ]; do
      read -rp "$prompt_text (cannot be empty): " val
    done
  fi
  eval "$varname=\$val"
}

run_remote() {
  # usage: run_remote "ssh user@ip -i key 'commands'"
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER@$REMOTE_IP" "$@"
}

# -------- Collect input --------
info "Collecting inputs"
prompt REPO_URL "Git repository URL (HTTPS) (e.g. https://github.com/user/repo.git)" "https://github.com/nkereuwemelijah/your-repo.git"
prompt GITHUB_USER "Your GitHub username" "nkereuwemelijah"
prompt PAT "Personal Access Token (PAT) — will be used for clone/pull (will not be stored permanently)" ""
prompt BRANCH "Branch (press enter for default 'main')" "main"
prompt REMOTE_USER "Remote SSH username (often 'ubuntu' for Ubuntu AMIs)" "ubuntu"
prompt REMOTE_IP "Remote server public IP" ""
prompt SSH_KEY_PATH "Path to SSH private key for remote (e.g. ~/Downloads/my-ec2-key.pem)" "~/Downloads/my-ec2-key.pem"
prompt APP_PORT "Application internal container port (e.g. 8080)" "8080"

# expand tilde
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

info "REPO_URL=$REPO_URL"
info "REMOTE=$REMOTE_USER@$REMOTE_IP"
info "BRANCH=$BRANCH"
info "APP_PORT=$APP_PORT"
info "Logfile: $LOGFILE"

# -------- Clone or update local repo --------
WORKDIR="$(pwd)/deploy_workdir"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || fatal "Cannot cd to $WORKDIR"

repo_name="$(basename -s .git "$REPO_URL")"
clone_dir="$WORKDIR/$repo_name"

# Build authenticated clone URL using PAT
if [ -n "$PAT" ]; then
  # This encodes PAT as username: use PAT as password with username
  AUTHED_REPO_URL=$(echo "$REPO_URL" | sed -E "s#https://#https://${GITHUB_USER}:${PAT}@#")
else
  AUTHED_REPO_URL="$REPO_URL"
fi

if [ -d "$clone_dir/.git" ]; then
  info "Repository already exists locally. Fetching & checking out branch."
  cd "$clone_dir" || fatal "cd fail"
  git remote set-url origin "$AUTHED_REPO_URL" || true
  git fetch origin --prune || fatal "git fetch failed"
  git checkout "$BRANCH" || git checkout -b "$BRANCH" origin/"$BRANCH" || fatal "branch checkout failed"
  git pull origin "$BRANCH" || info "git pull may have failed but continuing"
else
  info "Cloning repository..."
  git clone --branch "$BRANCH" "$AUTHED_REPO_URL" "$clone_dir" || fatal "git clone failed"
  cd "$clone_dir" || fatal "cd failed"
fi

# verify Dockerfile or docker-compose
if [ -f Dockerfile ] || [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  info "Found Dockerfile or docker-compose.yml"
else
  fatal "No Dockerfile or docker-compose.yml found in repo root."
fi

# -------- Test SSH connectivity to remote --------
info "Checking SSH connectivity to remote server..."
ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "echo connected" >/dev/null 2>&1 || {
  err "SSH connectivity failed. Trying SSH dry-run to show error..."
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "echo connected" || fatal "SSH failed. Check IP / key / user."
}
info "SSH connectivity OK"

# -------- Rsync project to remote --------
REMOTE_APP_DIR="/home/$REMOTE_USER/${repo_name}"
info "Syncing files to remote: $REMOTE_APP_DIR"
rsync -avz -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" --delete --exclude '.git' ./ "$REMOTE_USER@$REMOTE_IP:$REMOTE_APP_DIR" || fatal "rsync failed"

# -------- Remote install: Docker, Docker Compose plugin, nginx --------
info "Preparing remote environment (install Docker, docker-compose plugin, nginx)"

/bin/bash <<SSH_CMDS
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" bash -s <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Update packages
sudo apt-get update -y
sudo apt-get upgrade -y

# Install prerequisites
sudo apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common apt-transport-https

# Install Docker (official repo)
if ! command -v docker >/dev/null 2>&1; then
  mkdir -p /tmp/docker-key
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
fi

# Docker Compose plugin
if ! docker compose version >/dev/null 2>&1; then
  sudo apt-get install -y docker-compose-plugin
fi

# Install nginx
if ! command -v nginx >/dev/null 2>&1; then
  sudo apt-get install -y nginx
fi

# Add remote user to docker group
if ! groups "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER" || true
fi

# Ensure services enabled
sudo systemctl enable docker --now || true
sudo systemctl enable nginx --now || true

# Show versions
docker --version || true
docker compose version || true
nginx -v || true
REMOTE
REMOTE
SSH_CMDS

info "Remote environment prepared"

# -------- Build & run app on remote --------
info "Deploying app on remote"

# choose run method based on docker-compose presence
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  info "Using docker-compose on remote"
  SSH_SCRIPT=$(cat <<'EOF'
set -euo pipefail
cd "$REMOTE_APP_DIR"
# stop any existing compose run
sudo docker compose down --remove-orphans || true
sudo docker compose pull || true
sudo docker compose up -d --build
# Wait & show container status
sudo docker compose ps
sudo docker compose logs --tail=50
EOF
)
else
  info "Using docker build + run on remote"
  # A simple container run format:
  SSH_SCRIPT=$(cat <<'EOF'
set -euo pipefail
cd "$REMOTE_APP_DIR"
# find Dockerfile and build
IMAGE_NAME="${repo_name}:latest"
# stop old container if exists
if sudo docker ps -a --format '{{.Names}}' | grep -w app_container >/dev/null 2>&1; then
  sudo docker rm -f app_container || true
fi
# build
sudo docker build -t "$IMAGE_NAME" .
# run (idempotent)
sudo docker run -d --name app_container -p ${APP_PORT}:${APP_PORT} "$IMAGE_NAME" || (sudo docker run -d --name app_container -p ${APP_PORT}:$APP_PORT "$IMAGE_NAME")
# show status
sudo docker ps --filter "name=app_container"
sudo docker logs --tail=50 app_container || true
EOF
)
fi

# execute the script on remote
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "bash -s" <<REMOTE_RUN
$SSH_SCRIPT
REMOTE_RUN

info "Application containers started"

# -------- Nginx reverse proxy configuration --------
info "Configuring Nginx reverse proxy"

NGINX_CONF="/etc/nginx/sites-available/${repo_name}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${repo_name}.conf"
PROXY_TARGET="http://127.0.0.1:${APP_PORT}"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "sudo bash -s" <<'NGINX'
set -euo pipefail
REPO_NAME="${repo_name}"
NGINX_CONF="/etc/nginx/sites-available/${repo_name}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${repo_name}.conf"
cat > "\$NGINX_CONF" <<'EOF'
server {
    listen 80;
    server_name _;

    client_max_body_size 50M;

    location / {
        proxy_pass '"$PROXY_TARGET"';
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# enable site
ln -sf "\$NGINX_CONF" "\$NGINX_LINK"
# test and reload
sudo nginx -t
sudo systemctl reload nginx
NGINX

info "Nginx config done and reloaded"

# -------- Validation --------
info "Validating deployment (local from remote & remote localhost)"

# Check Docker & container health
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Test app endpoint via remote curl (from server)
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "curl -f -sS http://127.0.0.1:${APP_PORT} || echo 'local curl failed'"

# Test via public IP (from local machine)
info "Testing public endpoint: http://$REMOTE_IP/"
curl -I --max-time 10 "http://$REMOTE_IP/" || err "Public curl failed — check security group / nginx / app"

info "Deployment validation finished"

info "All done. Log: $LOGFILE"
info "To re-run safely, re-run this script. To clean up, remove the container on the server and nginx site and unregister files."
