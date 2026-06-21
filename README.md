# vps-deep-clean_debian.sh
Bash Script for Deep Clean VPS Debian to recover Disk Space

# Primero, prueba en modo simulación (no borra nada, solo muestra qué haría)
sudo bash vps-deep-clean.sh --dry-run

# Modo interactivo (te pregunta antes de cada paso)
sudo bash vps-deep-clean.sh

# Modo automático sin confirmaciones (para cron, por ejemplo)
sudo bash vps-deep-clean.sh --yes
