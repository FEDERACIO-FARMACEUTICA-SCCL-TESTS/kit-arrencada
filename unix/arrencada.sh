#!/bin/sh
# arrencada.sh - bootstrap kit for macOS/Linux (POSIX sh).
# Installs user-level prerequisites (no sudo, no Homebrew), logs in to GitHub,
# clones the product repo and opens Gentle Shell.
#
# Exit codes: 0 ok, 64 usage/invalid input, 10 missing prerequisite the user
# cannot install, 11 download/checksum failure, 12 Gentle Shell install not
# finished, 13 GitHub login or repo access failure, 1 other.
set -eu

KIT_MARKER='# kit-arrencada'
GH_RELEASES="${ARRENCADA_GH_RELEASES:-https://github.com/cli/cli/releases}"
NODE_DIST="${ARRENCADA_NODE_DIST:-https://nodejs.org/dist/latest-v24.x}"
GS_RELEASES="${ARRENCADA_GS_RELEASES:-https://github.com/Gentleman-Programming/gentle-shell/releases/latest/download}"
NODE_MIN_MAJOR=24

REPO=''
DIR=''
EMAIL=''
NO_OBRIR=0
SENSE_GS=0
TMP_ROOT=''
OS=''
GH_ARCH=''
NODE_ARCH=''
NODE_OS=''

say() { printf '[arrencada] %s\n' "$*"; }

# fail <exit_code> <message>: print the message on stderr and exit.
fail() {
  code=$1
  shift
  printf '[arrencada] ERROR: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
Ús: arrencada.sh --repo ORG/NOM [--directori DIR] [--correu EMAIL]
                 [--no-obrir] [--sense-gentle-shell]

Prepara l'ordinador (git, gh, Node 24, Gentle Shell), inicia la sessió a
GitHub, clona el repositori i obre Gentle Shell.

Opcions:
  --repo ORG/NOM          Repositori de GitHub (obligatori).
  --directori DIR         Carpeta de destinació (per defecte $HOME/projectes/NOM).
  --correu EMAIL          Correu per a git si encara no n'hi ha cap configurat.
  --no-obrir              No obrir Gentle Shell al final.
  --sense-gentle-shell    No instal·lar Gentle Shell.
  -h, --help              Mostra aquesta ajuda.

Codis de sortida: 0 correcte, 64 ús/entrada invàlida, 10 falta un requisit,
11 descàrrega o suma de verificació, 12 Gentle Shell sense instal·lar,
13 accés a GitHub, 1 altres errors.
EOF
}

usage_fail() {
  printf '[arrencada] ERROR: %s\n' "$*" >&2
  usage >&2
  exit 64
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
  TMP_ROOT=''
}

# Create the scratch dir once (never inside a subshell, or cleanup is lost).
ensure_tmp() {
  if [ -z "$TMP_ROOT" ]; then
    TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/arrencada.XXXXXX")
    trap cleanup EXIT
  fi
}

# Base URL overrides are for tests only: without ARRENCADA_TEST=1 any override is refused.
check_overrides() {
  [ "${ARRENCADA_TEST:-}" = 1 ] && return 0
  for u in "${ARRENCADA_GH_RELEASES:-}" "${ARRENCADA_NODE_DIST:-}" "${ARRENCADA_GS_RELEASES:-}"; do
    [ -z "$u" ] || fail 64 "Les URL base alternatives només es permeten en mode de prova: $u"
  done
}

# Exact authority check: scheme https and host exactly github.com, nodejs.org or the
# GitHub download hosts (no userinfo, no port, no lookalike suffix). ARRENCADA_TEST=1 lifts it.
check_url() {
  [ "${ARRENCADA_TEST:-}" = 1 ] && return 0
  rest=${1#https://}
  [ "$rest" != "$1" ] || fail 11 "URL no permesa: $1"
  auth=${rest%%[/?#]*}
  case $auth in
    github.com | nodejs.org | objects.githubusercontent.com | release-assets.githubusercontent.com | github-releases.githubusercontent.com) ;;
    *) fail 11 "URL no permesa: $1" ;;
  esac
}

# has_control <text>: true if the text contains any control character (CR, LF, ...).
has_control() {
  case $1 in
    *[[:cntrl:]]*) return 0 ;;
  esac
  return 1
}

need_curl() {
  command -v curl >/dev/null 2>&1 || fail 10 "Falta 'curl'. Contacta amb Plataforma."
}

# download <url> <dest>
download() {
  check_url "$1"
  need_curl
  if [ "${ARRENCADA_TEST:-}" = 1 ]; then
    curl -fsSL -o "$2" "$1" || fail 11 "No s'ha pogut descarregar $1"
  else
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$2" "$1" || fail 11 "No s'ha pogut descarregar $1"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail 10 "Falta 'shasum' o 'sha256sum' per verificar descàrregues."
  fi
}

# verify_sha <file> <sums_file> <asset_name>: delete the file and exit 11 on any problem.
verify_sha() {
  expected=$(awk -v n="$3" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$2")
  if [ -z "$expected" ]; then
    rm -f "$1"
    fail 11 "No hi ha suma de verificació per a $3. Descàrrega eliminada."
  fi
  actual=$(sha256_of "$1")
  if [ "$(lc "$expected")" != "$(lc "$actual")" ]; then
    rm -f "$1"
    fail 11 "La suma SHA-256 de $3 no coincideix. Descàrrega eliminada."
  fi
}

extract_archive() {
  case $1 in
    *.zip)
      command -v unzip >/dev/null 2>&1 || fail 10 "Falta 'unzip'."
      unzip -q -o "$1" -d "$2" || fail 11 "No s'ha pogut descomprimir $1"
      ;;
    *.tar.gz)
      tar -xzf "$1" -C "$2" || fail 11 "No s'ha pogut descomprimir $1"
      ;;
    *) fail 1 "Format d'arxiu desconegut: $1" ;;
  esac
}

# latest_tag <releases_url>: tag taken from the Location header of /latest.
latest_tag() {
  check_url "$1/latest"
  need_curl
  if [ "${ARRENCADA_TEST:-}" = 1 ]; then
    headers=$(curl -fsSI "$1/latest") || fail 11 "No s'ha pogut consultar $1/latest"
  else
    headers=$(curl -fsSI --proto '=https' --proto-redir '=https' --tlsv1.2 "$1/latest") || fail 11 "No s'ha pogut consultar $1/latest"
  fi
  loc=$(printf '%s\n' "$headers" | tr -d '\r' | grep -i '^location:' | tail -n 1 || true)
  loc=${loc#*: }
  tag=${loc##*/}
  printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || fail 11 "No s'ha pogut determinar l'última versió de gh."
  printf '%s' "$tag"
}

detect_platform() {
  case $(uname -s) in
    Darwin) OS=macos; NODE_OS=darwin ;;
    Linux) OS=linux; NODE_OS=linux ;;
    *) fail 1 "Sistema operatiu no compatible: $(uname -s)" ;;
  esac
  case $(uname -m) in
    arm64 | aarch64) GH_ARCH=arm64; NODE_ARCH=arm64 ;;
    x86_64 | amd64) GH_ARCH=amd64; NODE_ARCH=x64 ;;
    *) fail 1 "Arquitectura no compatible: $(uname -m)" ;;
  esac
}

# Persist ~/.local/bin in PATH, idempotent thanks to the marker line.
persist_path() {
  if [ "$OS" = macos ]; then rc="$HOME/.zprofile"; else rc="$HOME/.profile"; fi
  if [ -f "$rc" ] && grep -qF "$KIT_MARKER" "$rc"; then
    return 0
  fi
  {
    printf '\n%s\n' "$KIT_MARKER"
    # shellcheck disable=SC2016
    printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"'
  } >>"$rc"
  say "He afegit ~/.local/bin al PATH a $rc"
}

install_gh() {
  check_overrides
  ensure_tmp
  work="$TMP_ROOT/gh"
  mkdir -p "$work"
  say "Instal·lant GitHub CLI (gh) a ~/.local/bin ..."
  tag=$(latest_tag "$GH_RELEASES")
  ver=${tag#v}
  if [ "$OS" = macos ]; then
    top="gh_${ver}_macOS_${GH_ARCH}"
    asset="$top.zip"
  else
    top="gh_${ver}_linux_${GH_ARCH}"
    asset="$top.tar.gz"
  fi
  download "$GH_RELEASES/download/$tag/$asset" "$work/$asset"
  download "$GH_RELEASES/download/$tag/gh_${ver}_checksums.txt" "$work/sums.txt"
  verify_sha "$work/$asset" "$work/sums.txt" "$asset"
  mkdir -p "$work/x"
  extract_archive "$work/$asset" "$work/x"
  [ -f "$work/x/$top/bin/gh" ] || fail 11 "L'arxiu de gh no conté bin/gh."
  mkdir -p "$HOME/.local/bin"
  cp "$work/x/$top/bin/gh" "$HOME/.local/bin/.gh.new"
  chmod 755 "$HOME/.local/bin/.gh.new"
  mv "$HOME/.local/bin/.gh.new" "$HOME/.local/bin/gh"
  persist_path
}

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  nv=$(node --version 2>/dev/null) || return 1
  nv=${nv#v}
  nmajor=${nv%%.*}
  case $nmajor in '' | *[!0-9]*) return 1 ;; esac
  [ "$nmajor" -ge "$NODE_MIN_MAJOR" ]
}

install_node() {
  check_overrides
  ensure_tmp
  work="$TMP_ROOT/node"
  mkdir -p "$work/x"
  say "Instal·lant Node.js 24 a ~/.local/node ..."
  download "$NODE_DIST/SHASUMS256.txt" "$work/SHASUMS256.txt"
  suffix="-${NODE_OS}-${NODE_ARCH}.tar.gz"
  asset=$(awk -v suf="$suffix" 'substr($2, 1, 6) == "node-v" && substr($2, length($2) - length(suf) + 1) == suf { print $2; exit }' "$work/SHASUMS256.txt")
  [ -n "$asset" ] || fail 11 "No hi ha cap paquet de Node per a ${NODE_OS}-${NODE_ARCH}."
  download "$NODE_DIST/$asset" "$work/$asset"
  verify_sha "$work/$asset" "$work/SHASUMS256.txt" "$asset"
  extract_archive "$work/$asset" "$work/x"
  top=${asset%.tar.gz}
  [ -x "$work/x/$top/bin/node" ] || fail 11 "L'arxiu de Node no conté bin/node."
  mkdir -p "$HOME/.local/bin"
  rm -rf "$HOME/.local/node" # our own previous install only
  mv "$work/x/$top" "$HOME/.local/node"
  for t in node npm npx; do
    ln -sf "$HOME/.local/node/bin/$t" "$HOME/.local/bin/$t"
  done
  persist_path
}

install_gentle_shell() {
  check_overrides
  ensure_tmp
  work="$TMP_ROOT/gs"
  mkdir -p "$work/x"
  say "Descarregant l'instal·lador oficial de Gentle Shell ..."
  if [ "$OS" = macos ]; then
    asset=gentle-shell-installer-macos.zip
    inner="$work/x/Gentle Shell Installer/Install Gentle Shell.command"
  else
    asset=gentle-shell-installer-linux.tar.gz
    inner="$work/x/gentle-shell-installer/install-gentle-shell.sh"
  fi
  download "$GS_RELEASES/$asset" "$work/$asset"
  download "$GS_RELEASES/gentle-shell-installers-SHA256SUMS.txt" "$work/sums.txt"
  verify_sha "$work/$asset" "$work/sums.txt" "$asset"
  extract_archive "$work/$asset" "$work/x"
  [ -f "$inner" ] || fail 12 "L'instal·lador de Gentle Shell no té el contingut esperat."
  say "S'obrirà l'assistent de Gentle Shell al navegador: acaba'l fins al final."
  if command -v bash >/dev/null 2>&1; then shell='bash'; else shell='sh'; fi
  "$shell" "$inner" || fail 12 "L'instal·lador de Gentle Shell ha fallat."
  PATH="$HOME/.local/bin:$PATH"
  gentle_shell_present || fail 12 "Gentle Shell encara no està instal·lat. Acaba l'assistent i torna a executar aquest script."
  persist_path
}

gentle_shell_present() {
  command -v gentle-shell >/dev/null 2>&1 || [ -x "$HOME/.local/bin/gentle-shell" ]
}

validate_repo() {
  has_control "$REPO" && usage_fail "--repo conté caràcters de control."
  case $REPO in
    */*) ;;
    *) usage_fail "--repo ha de tenir el format ORG/NOM" ;;
  esac
  owner=${REPO%%/*}
  name=${REPO#*/}
  printf '%s' "$owner" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$' || usage_fail "Propietari invàlid a --repo: $owner"
  printf '%s' "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || usage_fail "Nom de repositori invàlid a --repo: $name"
  [ "${#name}" -ge 3 ] && [ "${#name}" -le 50 ] || usage_fail "El nom del repositori ha de tenir entre 3 i 50 caràcters."
}

validate_email() {
  has_control "$1" && usage_fail "El correu conté caràcters de control."
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || usage_fail "Correu invàlid: $1"
  edomain=$(lc "${1#*@}")
  for d in ${ARRENCADA_DOMINIS:-fedefarma.com}; do
    [ "$edomain" = "$(lc "$d")" ] && return 0
  done
  usage_fail "El domini del correu no està permès (${ARRENCADA_DOMINIS:-fedefarma.com})."
}

# ARRENCADA_INSTALAR_PREREQUISITS=0: never install anything, ask IT instead (exit 10).
prereq_allowed() {
  [ "${ARRENCADA_INSTALAR_PREREQUISITS:-1}" = 1 ] && return 0
  fail 10 "Falta $1 i la instal·lació automàtica està desactivada (ARRENCADA_INSTALAR_PREREQUISITS=0). Demana-ho a IT/Plataforma i torna a executar aquest script."
}

step1() {
  say "Pas 1/7: comprovant requisits (git, gh, node >= $NODE_MIN_MAJOR)"
  if [ "$OS" = macos ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      xcode-select --install || true
      fail 10 "Falten les eines de línia d'ordres d'Apple (git). S'està obrint l'instal·lador: quan acabi, torna a executar aquest script."
    fi
  elif ! command -v git >/dev/null 2>&1; then
    fail 10 "Falta git. Instal·la'l amb 'sudo apt-get install -y git' o 'sudo dnf install -y git' (o demana-ho a Plataforma) i torna a executar aquest script."
  fi
  if ! command -v gh >/dev/null 2>&1; then
    prereq_allowed gh
    install_gh
  fi
  if ! node_ok; then
    prereq_allowed "node >= $NODE_MIN_MAJOR"
    install_node
  fi
  say "Requisits correctes."
}

step2() {
  if [ "$SENSE_GS" = 1 ]; then
    say "Pas 2/7: Gentle Shell omès (--sense-gentle-shell)"
    return 0
  fi
  say "Pas 2/7: Gentle Shell"
  if gentle_shell_present; then
    say "Gentle Shell ja està instal·lat."
    return 0
  fi
  install_gentle_shell
}

step3() {
  say "Pas 3/7: sessió a GitHub"
  # --active: a stale secondary account must not make the status fail (older gh: plain status).
  if gh auth status --hostname github.com --active >/dev/null 2>&1 || gh auth status >/dev/null 2>&1; then
    say "Ja tens la sessió iniciada a GitHub."
  else
    say "S'obrirà el navegador per iniciar sessió a GitHub."
    gh auth login --hostname github.com --web --git-protocol https || fail 13 "No s'ha pogut iniciar sessió a GitHub."
  fi
  gh auth setup-git || fail 13 "No s'ha pogut configurar git amb GitHub."
  if ! gh repo view "$REPO" --json name >/dev/null 2>&1; then
    fail 13 "No tens accés al repositori $REPO. Demana accés a Plataforma i torna-ho a provar."
  fi
}

step4() {
  say "Pas 4/7: configuració de git"
  gname=$(git config --global user.name 2>/dev/null || true)
  gemail=$(git config --global user.email 2>/dev/null || true)
  if [ -n "$gname" ] && [ -n "$gemail" ]; then
    say "git ja té nom i correu configurats."
    return 0
  fi
  if [ -z "$gemail" ]; then
    email=$EMAIL
    if [ -z "$email" ]; then
      printf '[arrencada] Correu corporatiu per a git: ' >&2
      if ! { read -r email </dev/tty; } 2>/dev/null; then
        fail 64 "No puc preguntar el correu. Torna a executar amb --correu EMAIL."
      fi
    fi
    validate_email "$email"
  fi
  if [ -z "$gname" ]; then
    gname=$(gh api user --jq '.name // .login' 2>/dev/null || true)
    [ -n "$gname" ] || fail 13 "No s'ha pogut obtenir el nom des de GitHub."
    git config --global user.name "$gname"
  fi
  if [ -z "$gemail" ]; then
    git config --global user.email "$email"
  fi
  say "git configurat."
}

step5() {
  say "Pas 5/7: repositori a $DIR"
  if [ -e "$DIR" ] && [ ! -d "$DIR" ]; then
    fail 64 "$DIR existeix i no és una carpeta."
  fi
  if [ -d "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
    origin=$(git -C "$DIR" remote get-url origin 2>/dev/null || true)
    origin=$(lc "$origin")
    origin=${origin%/}
    origin=${origin%.git}
    want=$(lc "$REPO")
    # Exact identity: host github.com + owner/repo (https, scp-style or ssh:// forms).
    case $origin in
      https://github.com/*) opath=${origin#https://github.com/} ;;
      git@github.com:*) opath=${origin#git@github.com:} ;;
      ssh://git@github.com/*) opath=${origin#ssh://git@github.com/} ;;
      *) opath='' ;;
    esac
    if [ -n "$opath" ] && [ "$opath" = "$want" ]; then
      say "Ja existeix un clon d'aquest repositori: no es torna a clonar."
      return 0
    fi
    fail 64 "La carpeta $DIR ja existeix i no és un clon de $REPO. Tria una altra amb --directori."
  fi
  mkdir -p "$(dirname "$DIR")"
  gh repo clone "$REPO" "$DIR" || fail 1 "No s'ha pogut clonar $REPO."
}

step6() {
  say "Pas 6/7: dependències del projecte"
  cd "$DIR"
  if [ ! -f package.json ]; then
    say "No hi ha package.json: no cal instal·lar dependències."
    return 0
  fi
  if [ -f package-lock.json ]; then
    npm ci || fail 1 "Ha fallat 'npm ci'."
  else
    npm install || fail 1 "Ha fallat 'npm install'."
  fi
}

step7() {
  say "Pas 7/7: tot a punt"
  say "Resum: repositori $REPO a $DIR"
  say "Per fer la visita guiada, escriu /gentle:guide dins de Gentle Shell."
  if [ "$NO_OBRIR" = 1 ]; then
    return 0
  fi
  if ! gentle_shell_present; then
    say "Gentle Shell no està instal·lat: no l'obro. Torna a executar sense --sense-gentle-shell."
    return 0
  fi
  cleanup # exec skips the EXIT trap
  cd "$DIR"
  exec gentle-shell
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help) usage; exit 0 ;;
      --repo | --directori | --correu)
        [ $# -ge 2 ] || usage_fail "L'opció $1 necessita un valor."
        case $1 in
          --repo) REPO=$2 ;;
          --directori) DIR=$2 ;;
          --correu) EMAIL=$2 ;;
        esac
        shift 2
        ;;
      --no-obrir) NO_OBRIR=1; shift ;;
      --sense-gentle-shell) SENSE_GS=1; shift ;;
      *) usage_fail "Opció desconeguda: $1" ;;
    esac
  done
  [ -n "$REPO" ] || usage_fail "Falta --repo ORG/NOM."
  validate_repo
  has_control "$DIR" && usage_fail "--directori conté caràcters de control."
  [ -z "$EMAIL" ] || validate_email "$EMAIL"
  case ${ARRENCADA_INSTALAR_PREREQUISITS:-1} in
    0 | 1) ;;
    *) usage_fail "ARRENCADA_INSTALAR_PREREQUISITS ha de ser 0 o 1." ;;
  esac
  [ -n "$DIR" ] || DIR="$HOME/projectes/${REPO#*/}"
  # Absolute destination, resolved once: steps 6 and 7 change directory.
  case $DIR in
    /*) ;;
    *) DIR="$PWD/$DIR" ;;
  esac
  while [ "${#DIR}" -gt 1 ]; do
    case $DIR in */) DIR=${DIR%/} ;; *) break ;; esac
  done
  check_overrides
  detect_platform
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  step1
  step2
  step3
  step4
  step5
  step6
  step7
}

# Tests source this file with ARRENCADA_NOMES_FUNCIONS=1 to reuse the functions.
if [ "${ARRENCADA_NOMES_FUNCIONS:-}" = 1 ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

main "$@"
