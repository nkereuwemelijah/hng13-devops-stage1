# DevOps Intern Stage 1 Task — Automated Deployment Bash Script

**Author:** Nkereuwem Peter Elijah  
**GitHub:** https://github.com/nkereuwemelijah

## Overview
This repository contains `deploy.sh`, a single executable Bash script that automates setup, deployment, and configuration of a Dockerized application on a remote Ubuntu server (EC2).

## What `deploy.sh` does
1. Collects required parameters (repo URL, PAT, branch, remote SSH user, IP, key path, app container port).
2. Clones or pulls the repo locally.
3. Verifies `Dockerfile` or `docker-compose.yml`.
4. Rsyncs project files to remote server.
5. Installs Docker, docker-compose plugin, and Nginx on the remote server (if missing).
6. Builds & runs containers (docker-compose or docker build/run).
7. Configures Nginx as reverse proxy (port 80 → container internal port).
8. Validates deployment and logs output to `deploy_YYYYMMDD.log`.
9. Built to be idempotent and safe to re-run.

## Usage
```bash
chmod +x deploy.sh
./deploy.sh
# follow prompts
