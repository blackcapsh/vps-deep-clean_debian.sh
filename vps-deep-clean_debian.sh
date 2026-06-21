#!/usr/bin/env bash
#
# vps-deep-clean.sh
# Limpieza profunda para VPS con Debian 12 (Bookworm)
#
# Limpia:
#   - Cache y paquetes huérfanos de APT
#   - Kernels antiguos (conserva el actual + el anterior)
#   - Logs del sistema (journalctl + /var/log)
#   - Docker: contenedores parados, imágenes dangling/no usadas,
#             volúmenes huérfanos, redes sin usar, build cache
#   - Archivos temporales (/tmp, /var/tmp)
#   - Cachés de usuario (pip, npm, snap si existe)
#
# Uso:
#   sudo bash vps-deep-clean.sh            # modo interactivo
#   sudo bash vps-deep-clean.sh --yes      # sin confirmaciones (modo no interactivo)
#   sudo bash vps-deep-clean.sh --dry-run  # solo muestra qué haría, no borra nada
#
set -uo pipefail

# ───────────────────────── Configuración ─────────────────────────
AUTO_YES=false
DRY_RUN=false
JOURNAL_KEEP="14d"        # cuántos días de logs de journalctl conservar
KEEP_KERNELS=2            # cuántos kernels conservar (incluye el actual)
LOG_FILE="/var/log/vps-deep-clean.log"

for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      echo "Uso: sudo bash $0 [--yes] [--dry-run]"
      exit 0
      ;;
  esac
done

# ───────────────────────── Utilidades ─────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "${CYAN}[*]${NC} $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }

run() {
  # Ejecuta un comando respetando --dry-run
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${NC} $*"
  else
    eval "$@"
  fi
}

confirm() {
  local prompt="$1"
  if $AUTO_YES; then
    return 0
  fi
  read -rp "$prompt [s/N]: " resp
  [[ "$resp" =~ ^([sS][iI]?|[yY])$ ]]
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Este script debe ejecutarse como root (usa sudo)."
    exit 1
  fi
}

human_disk_usage() {
  df -h / | awk 'NR==2 {print "Usado: " $3 " / " $2 " (" $5 " ocupado) | Libre: " $4}'
}

# ───────────────────────── Inicio ─────────────────────────
require_root
touch "$LOG_FILE"

echo "============================================================"
echo "   Limpieza profunda del VPS - $(hostname) - $(date)"
echo "============================================================"
log "Espacio en disco ANTES de limpiar:"
human_disk_usage
echo

if $DRY_RUN; then
  warn "Modo DRY-RUN activado: no se borrará nada, solo se mostrará lo que se haría."
fi

# ───────────────────────── 1. APT: cache y paquetes huérfanos ─────────────────────────
log "1) Limpieza de APT (cache, paquetes huérfanos y residuales)..."
if confirm "¿Limpiar cache de APT y paquetes huérfanos/residuales?"; then
  run "apt-get clean -y"
  run "apt-get autoclean -y"
  run "apt-get autoremove --purge -y"

  # Paquetes en estado "rc" (removidos pero con config residual)
  RC_PKGS=$(dpkg -l | awk '/^rc/ {print $2}')
  if [[ -n "$RC_PKGS" ]]; then
    log "Purgando configuraciones residuales de paquetes ya removidos..."
    run "dpkg --purge $RC_PKGS"
  else
    ok "No hay paquetes con configuración residual."
  fi
  ok "APT limpiado."
else
  warn "Saltando limpieza de APT."
fi
echo

# ───────────────────────── 2. Kernels antiguos ─────────────────────────
log "2) Revisando kernels instalados (se conservarán $KEEP_KERNELS, incluyendo el actual)..."

CURRENT_KERNEL=$(uname -r)
INSTALLED_KERNELS=$(dpkg --list | awk '/^ii  linux-image-[0-9]/{print $2}' | sort -V)

if [[ -z "$INSTALLED_KERNELS" ]]; then
  warn "No se detectaron paquetes linux-image instalados (puede usar un kernel del proveedor)."
else
  echo "Kernels instalados:"
  echo "$INSTALLED_KERNELS" | sed 's/^/   - /'
  echo "Kernel en uso actualmente: $CURRENT_KERNEL"
  echo

  # Excluir el kernel en uso de la lista de candidatos a borrar
  KERNELS_TO_KEEP=$(echo "$INSTALLED_KERNELS" | grep -v "$CURRENT_KERNEL" | tail -n $((KEEP_KERNELS - 1)))
  KERNELS_CANDIDATE=$(echo "$INSTALLED_KERNELS" | grep -v "$CURRENT_KERNEL")
  KERNELS_TO_REMOVE=$(comm -23 <(echo "$KERNELS_CANDIDATE" | sort) <(echo "$KERNELS_TO_KEEP" | sort))

  if [[ -n "$KERNELS_TO_REMOVE" ]]; then
    echo "Kernels candidatos a eliminar:"
    echo "$KERNELS_TO_REMOVE" | sed 's/^/   - /'
    if confirm "¿Eliminar estos kernels antiguos?"; then
      for kpkg in $KERNELS_TO_REMOVE; do
        run "apt-get purge -y \"$kpkg\""
      done
      run "update-grub"
      ok "Kernels antiguos eliminados y GRUB actualizado."
    else
      warn "Saltando eliminación de kernels."
    fi
  else
    ok "No hay kernels antiguos para eliminar (ya estás en el mínimo configurado)."
  fi
fi
echo

# ───────────────────────── 3. Logs del sistema ─────────────────────────
log "3) Limpieza de logs (journalctl y /var/log)..."
if confirm "¿Reducir journalctl a los últimos $JOURNAL_KEEP y rotar/vaciar logs antiguos?"; then
  if command -v journalctl &>/dev/null; then
    run "journalctl --vacuum-time=$JOURNAL_KEEP"
    run "journalctl --vacuum-size=200M"
  fi

  # Logs rotados y comprimidos antiguos (.gz, .1, .old)
  run "find /var/log -type f \\( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \\) -delete"

  # Vaciar logs activos muy grandes (mayores a 50MB) sin borrar el archivo (mantiene el handle del proceso)
  run "find /var/log -type f -name '*.log' -size +50M -exec truncate -s 0 {} \\;"

  ok "Logs limpiados."
else
  warn "Saltando limpieza de logs."
fi
echo

# ───────────────────────── 4. Docker ─────────────────────────
if command -v docker &>/dev/null; then
  log "4) Limpieza de Docker (contenedores parados, imágenes, volúmenes, redes, build cache)..."
  echo "Resumen actual de uso de Docker:"
  run "docker system df" || true
  echo

  if confirm "¿Eliminar contenedores parados?"; then
    run "docker container prune -f"
  fi

  if confirm "¿Eliminar imágenes Docker no usadas (no solo dangling, sino TODAS las que no estén en uso por un contenedor)?"; then
    run "docker image prune -a -f"
  else
    if confirm "¿Eliminar al menos las imágenes 'dangling' (<none>)?"; then
      run "docker image prune -f"
    fi
  fi

  if confirm "¿Eliminar volúmenes Docker no usados? (CUIDADO: si tienes volúmenes con datos de apps detenidas, se perderán)"; then
    run "docker volume prune -f"
  else
    warn "Saltando limpieza de volúmenes Docker."
  fi

  if confirm "¿Eliminar redes Docker no usadas?"; then
    run "docker network prune -f"
  fi

  if confirm "¿Limpiar build cache de Docker (docker builder prune)?"; then
    run "docker builder prune -af"
  fi

  ok "Limpieza de Docker completada."
  echo "Resumen de Docker después de limpiar:"
  run "docker system df" || true
else
  warn "4) Docker no está instalado en este sistema. Saltando esta sección."
fi
echo

# ───────────────────────── 5. Temporales y cachés varias ─────────────────────────
log "5) Limpieza de archivos temporales y cachés de usuario..."
if confirm "¿Limpiar /tmp, /var/tmp y cachés (pip, npm, snap si existen)?"; then
  run "find /tmp -mindepth 1 -mtime +2 -delete 2>/dev/null"
  run "find /var/tmp -mindepth 1 -mtime +7 -delete 2>/dev/null"

  if command -v pip3 &>/dev/null; then
    run "pip3 cache purge 2>/dev/null"
  fi

  if command -v npm &>/dev/null; then
    run "npm cache clean --force 2>/dev/null"
  fi

  if command -v snap &>/dev/null; then
    log "Eliminando revisiones antiguas de snaps (si las hay)..."
    if $DRY_RUN; then
      echo "[DRY-RUN] snap list --all | awk '/disabled/{print \$1, \$3}' | while read name rev; do snap remove \"\$name\" --revision=\"\$rev\"; done"
    else
      snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r name rev; do
        snap remove "$name" --revision="$rev" 2>/dev/null
      done
    fi
  fi

  ok "Temporales y cachés limpiados."
else
  warn "Saltando limpieza de temporales."
fi
echo

# ───────────────────────── 6. Core dumps antiguos ─────────────────────────
if [[ -d /var/crash || -d /var/lib/systemd/coredump ]]; then
  log "6) Limpieza de core dumps antiguos..."
  if confirm "¿Eliminar core dumps guardados por el sistema?"; then
    run "rm -rf /var/crash/* 2>/dev/null"
    run "rm -f /var/lib/systemd/coredump/* 2>/dev/null"
    ok "Core dumps eliminados."
  else
    warn "Saltando limpieza de core dumps."
  fi
  echo
fi

# ───────────────────────── Resultado final ─────────────────────────
echo "============================================================"
ok "Limpieza finalizada."
log "Espacio en disco DESPUÉS de limpiar:"
human_disk_usage
echo "Log detallado guardado en: $LOG_FILE"
echo "============================================================"
