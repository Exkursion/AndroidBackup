#!/usr/bin/env bash
# mtk_backup.sh — ETA für dein Backup (ohne userdata)
# Venv-first & PEP668-safe: bootstrappt venv + pip zuverlässig, installiert Deps in der venv,
# libfuse per Paketmanager. Startet mtk.py/mtk mit dem venv-Python.

set -euo pipefail

# -------------------- CLI / Defaults --------------------
MTK_SETUP="${MTK_SETUP:-auto}"    # auto|venv|user|system
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
QUIET_INSTALL="${QUIET_INSTALL:-1}"
AUTO_OS_DEPS="${AUTO_OS_DEPS:-1}" # 1=libfuse via Paketmanager versuchen
ALLOW_BREAK_SYS="${ALLOW_BREAK_SYS:-0}" # 1=--break-system-packages (nicht empfohlen)

usage() {
  cat <<'USAGE'
Nutzung: ./mtk_backup.sh [--setup=auto|venv|user|system] [--force-reinstall] [--no-os-deps]
Env: MTK_SETUP=..., FORCE_REINSTALL=1, QUIET_INSTALL=0, AUTO_OS_DEPS=0, MTK_DIR=..., MTK_BIN=..., SUDO_OPT="", ALLOW_BREAK_SYS=1
USAGE
  exit 0
}
for arg in "${@:-}"; do
  case "$arg" in
    --help|-h) usage ;;
    --force-reinstall) FORCE_REINSTALL=1 ;;
    --setup=*) MTK_SETUP="${arg#*=}" ;;
    --no-os-deps) AUTO_OS_DEPS=0 ;;
    *) echo "Unbekanntes Argument: $arg" >&2; usage ;;
  esac
done

# -------------------- Basics --------------------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "fehlend: $1" >&2; exit 2; }; }
need awk; need sed; need grep; need stat; need date; need python3
log(){ printf "%s\n" "$*" >&2; }
quiet_flag(){ (( QUIET_INSTALL==1 )) && printf -- "-q" || true; }

# MTK_DIR automatisch aufs Repo setzen, wenn wir im Checkout sind
MTK_DIR="${MTK_DIR:-}"
if [[ -z "${MTK_DIR}" ]]; then
  if [[ -f "./mtk.py" ]]; then MTK_DIR="$PWD"; else MTK_DIR="$HOME/mtkclient"; fi
fi
MTK_BIN="${MTK_BIN:-}"
SUDO_OPT="${SUDO_OPT:-sudo}"

# venv-Ziel
VENV_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/mtk_backup_eta"
VENV_DIR="$VENV_BASE/venv"
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
VENV_MTK="$VENV_DIR/bin/mtk"

PIP_CMD=(python3 -m pip)

is_debian_like(){ command -v apt-get >/dev/null 2>&1; }
is_externally_managed(){ for f in /usr/lib/python3*/EXTERNALLY-MANAGED; do [[ -e "$f" ]] && return 0; done; return 1; }

ensure_pip() {
  if ! python3 -m pip --version >/dev/null 2>&1; then
    log "Installiere pip (ensurepip)…"
    python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  python3 -m pip --version >/dev/null 2>&1 || { log "pip für Python3 fehlt weiterhin."; exit 2; }
}

ensure_python_venv_tool(){
  # Prüfe, ob 'python3 -m venv' verfügbar ist; wenn nicht, installiere passende Pakete.
  if ! python3 -m venv --help >/dev/null 2>&1; then
    if is_debian_like; then
      local pyver
      pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
      log "python3-venv fehlt – installiere über apt (python3-venv & python${pyver}-venv)…"
      $SUDO_OPT apt-get update -y
      $SUDO_OPT apt-get install -y python3-venv "python${pyver}-venv"
    else
      echo "python3 venv-Modul fehlt und Auto-Install ist für diese Distro nicht implementiert." >&2
      exit 2
    fi
  fi
}

bootstrap_pip_in_venv(){
  # 1) ensurepip in der venv probieren
  if [[ ! -x "$VENV_PIP" ]]; then
    "$VENV_PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  # 2) falls noch kein pip: auf Ubuntu/Debian hilft oft python3-full (liefert ensurepip wheels)
  if [[ ! -x "$VENV_PIP" ]] && is_debian_like; then
    log "venv ohne pip – installiere python3-full (liefert ensurepip-Wheels)…"
    $SUDO_OPT apt-get update -y
    $SUDO_OPT apt-get install -y python3-full
    "$VENV_PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  # 3) als letzter Ausweg: get-pip.py
  if [[ ! -x "$VENV_PIP" ]]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$VENV_DIR/get-pip.py"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$VENV_DIR/get-pip.py" https://bootstrap.pypa.io/get-pip.py
    else
      log "Weder curl noch wget vorhanden, kann get-pip.py nicht laden."
    fi
    if [[ -f "$VENV_DIR/get-pip.py" ]]; then
      "$VENV_PY" "$VENV_DIR/get-pip.py" >/dev/null
    fi
  fi
  # 4) prüfen
  if [[ ! -x "$VENV_PIP" ]]; then
    echo "Konnte pip in der venv nicht bootstrappen. Bitte installiere python3-venv/python3-full manuell und versuche es erneut." >&2
    exit 2
  fi
  # pip/wheel upgraden
  "$VENV_PY" -m pip install --upgrade pip wheel >/dev/null 2>&1 || true
}

create_or_use_venv(){
  ensure_python_venv_tool
  if [[ ! -d "$VENV_DIR" || $FORCE_REINSTALL -eq 1 ]]; then
    log "Erstelle venv: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
  bootstrap_pip_in_venv
  PIP_CMD=("$VENV_PY" -m pip)
}

# -------------------- OS-Dependency: libfuse --------------------
has_libfuse() {
  if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | grep -E 'libfuse3?\.so' >/dev/null && return 0
  fi
  python3 - <<'PY' >/dev/null 2>&1
import ctypes.util, sys
sys.exit(0 if (ctypes.util.find_library("fuse3") or ctypes.util.find_library("fuse")) else 1)
PY
}
install_libfuse() {
  (( AUTO_OS_DEPS==1 )) || return 1
  log "Versuche libfuse via Paketmanager zu installieren…"
  if is_debian_like; then
    $SUDO_OPT apt-get update -y
    $SUDO_OPT apt-get install -y fuse3 || $SUDO_OPT apt-get install -y fuse
    return $?
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO_OPT dnf install -y fuse3 fuse3-libs; return $?
  elif command -v yum >/dev/null 2>&1; then
    $SUDO_OPT yum install -y fuse3 fuse3-libs; return $?
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO_OPT pacman -Sy --noconfirm fuse3; return $?
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO_OPT zypper --non-interactive install fuse3; return $?
  elif command -v apk >/dev/null 2>&1; then
    $SUDO_OPT apk add fuse; return $?
  elif command -v emerge >/dev/null 2>&1; then
    $SUDO_OPT emerge --ask=n sys-fs/fuse; return $?
  else
    log "Kein bekannter Paketmanager gefunden. Installiere libfuse bitte manuell."
    return 1
  fi
}

# -------------------- Python-Dependency: fusepy (in venv) --------------------
has_py_module() {
  local mod="$1"
  "$VENV_PY" - "$mod" >/dev/null 2>&1 <<'PY'
import importlib,sys
m=sys.argv[1]
try:
  importlib.import_module(m); sys.exit(0)
except Exception:
  sys.exit(1)
PY
}
ensure_fuse_deps_in_current_context() {
  if ! has_libfuse; then
    log "libfuse nicht gefunden."
    install_libfuse || log "Konnte libfuse nicht automatisch installieren. Bitte manuell installieren (z.B. 'sudo apt-get install fuse3')."
  fi
  if ! has_py_module fuse; then
    log "Python-Modul 'fuse' (fusepy) in venv installieren…"
    "${PIP_CMD[@]}" install $(quiet_flag) --upgrade fusepy
  fi
}

# -------------------- mtk beziehbar machen --------------------
MTK_CMD=()
resolve_mtk_cmd() {
  case "$MTK_SETUP" in
    venv)
      create_or_use_venv
      if [[ -f "$MTK_DIR/requirements.txt" ]]; then
        log "Installiere Repo-Requirements in venv…"
        "${PIP_CMD[@]}" install $(quiet_flag) -r "$MTK_DIR/requirements.txt"
      else
        log "Installiere mtkclient in venv…"
        "${PIP_CMD[@]}" install $(quiet_flag) --upgrade mtkclient
      fi
      if [[ -f "$MTK_DIR/mtk.py" ]]; then
        MTK_CMD=("$SUDO_OPT" "$VENV_PY" "$MTK_DIR/mtk.py")
      elif [[ -x "$VENV_MTK" ]]; then
        MTK_CMD=("$SUDO_OPT" "$VENV_MTK")
      else
        MTK_CMD=("$SUDO_OPT" "$VENV_DIR/bin/mtk")
      fi
      ;;
    user)
      ensure_pip
      python3 -m pip install $(quiet_flag) --user --upgrade mtkclient
      create_or_use_venv
      if [[ -f "$MTK_DIR/mtk.py" ]]; then
        MTK_CMD=("$SUDO_OPT" "$VENV_PY" "$MTK_DIR/mtk.py")
      elif command -v mtk >/dev/null 2>&1; then
        MTK_CMD=("$SUDO_OPT" "$(command -v mtk)")
      else
        MTK_CMD=("$SUDO_OPT" "$VENV_MTK")
      fi
      ;;
    system)
      if is_externally_managed && (( ALLOW_BREAK_SYS==0 )); then
        log "PEP 668 erkannt – nutze stattdessen venv."
        MTK_SETUP="venv"; resolve_mtk_cmd; return
      fi
      ensure_pip
      local extra=()
      (( ALLOW_BREAK_SYS==1 )) && extra+=(--break-system-packages)
      $SUDO_OPT python3 -m pip install $(quiet_flag) "${extra[@]}" --upgrade mtkclient
      create_or_use_venv
      if [[ -f "$MTK_DIR/mtk.py" ]]; then
        MTK_CMD=("$SUDO_OPT" "$VENV_PY" "$MTK_DIR/mtk.py")
      elif command -v mtk >/dev/null 2>&1; then
        MTK_CMD=("$SUDO_OPT" "$(command -v mtk)")
      else
        MTK_CMD=("$SUDO_OPT" "$VENV_MTK")
      fi
      ;;
    auto)
      if [[ -f "$MTK_DIR/mtk.py" ]]; then MTK_SETUP="venv"; resolve_mtk_cmd; return; fi
      if command -v mtk >/dev/null 2>&1; then create_or_use_venv; MTK_CMD=("$SUDO_OPT" "$(command -v mtk)"); return; fi
      MTK_SETUP="venv"; resolve_mtk_cmd ;;
    *) log "Ungültiger MTK_SETUP-Wert: $MTK_SETUP"; exit 2 ;;
  esac
}

resolve_mtk_cmd
log "mtkclient Kommando: ${MTK_CMD[*]}"
log "Installationsmodus: $MTK_SETUP"
log "venv: $VENV_DIR"

# Vor dem ersten mtk-Aufruf: FUSE-Stack in der venv sicherstellen
ensure_fuse_deps_in_current_context

# -------------------- ETA-Logik --------------------
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
GPT="$TMPDIR/gpt.txt"

echo "Lese GPT… (Gerät AUS, dann Lauter halten & USB einstecken sobald 'Waiting for device' erscheint)"
"${MTK_CMD[@]}" printgpt | tee "$GPT" >/dev/null

# Größen (ohne userdata) aufsummieren
total_bytes=0
current_name=""
while IFS= read -r line; do
  case "$line" in
    *Name*:* ) current_name="$(echo "$line" | sed -E 's/.*Name[^:]*:\s*([[:alnum:]_.-]+).*/\1/')" ;;
    *Size*:* )
      szraw="$(echo "$line" | sed -E 's/.*Size[^:]*:\s*([0-9xXa-fA-F]+).*/\1/')"
      if [[ "$szraw" =~ ^0[xX][0-9a-fA-F]+$ ]]; then size=$((szraw)); else size="$szraw"; fi
      if [[ "${current_name,,}" != "userdata" ]]; then total_bytes=$(( total_bytes + size )); fi
      ;;
  esac
done < "$GPT"

if (( total_bytes == 0 )); then
  echo "Konnte keine Größen parsen. (mtkclient-Output-Format?)" >&2
  exit 1
fi

pick_part(){ for p in vbmeta vbmeta_a vbmeta_b dtbo dtbo_a dtbo_b boot boot_a boot_b vendor_boot vendor_boot_a vendor_boot_b; do
  if grep -qi "Name.*: *$p" "$GPT"; then echo "$p"; return; fi; done; echo "super"; }
part="$(pick_part)"
echo "Benchmark lese Partition: $part"

OUT="/dev/shm/mtk_bench_${part}.img"
[[ -d /dev/shm ]] || OUT="$TMPDIR/bench_${part}.img"

start=$(date +%s)
if ! "${MTK_CMD[@]}" r "$part" "$OUT" >/dev/null 2>&1; then
  echo "Benchmark-Read fehlgeschlagen. (USB-Rechte? Kabel? Preloader-Mode?)" >&2
  exit 3
fi
end=$(date +%s)

bytes=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
secs=$(( end - start )); (( secs < 1 )) && secs=1
speed_Bps=$(( bytes / secs )); (( speed_Bps == 0 )) && { echo "Durchsatz = 0?"; exit 4; }
eta_sec=$(( total_bytes / speed_Bps ))

human(){ local b=$1; local u=(B KB MB GB TB); local i=0; while (( b>=1024 && i<4 )); do b=$(( b/1024 )); ((i++)); done; echo "$b ${u[$i]}"; }
fmt_time(){ local t=$1; printf "%02dh:%02dm:%02ds\n" $((t/3600)) $(((t%3600)/60)) $((t%60)); }

echo "-----------------------------------------------------"
echo "Geschätztes Backup-Datenvolumen (ohne userdata): $(human "$total_bytes")"
echo "Gemessene Benchmark-Rate:                         $(human "$speed_Bps")/s"
echo "Erwartete Dauer (nur Lesephase):                  $(fmt_time "$eta_sec")"
echo "Hinweis: + Zeit für SHA256 & ZIP kommt oben drauf."
echo "-----------------------------------------------------"
