#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# Matrix Stack Manager - v1.6-local-ca
# Telegram: https://t.me/amirabbas_jadidi
# YouTube:  https://github.com/Amirabbasjadidi/PD-Element-Local
#############################################

LOG_FILE="/var/log/matrix-installer.log"
touch "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

CONFIG_FILE="/etc/matrix-installer.conf"
LEGACY_CONFIG_FILE="/etc/matrix-stack.conf"
VERSION="2.0-enterprise-pki"

read -r -d '' ASCII_BANNER <<'BANNER' || true
╔════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                                                                                ║
║   _______  ______              _______  _        _______  _______  _______  _       _________  ║
║  (  ____ )(  __  \            (  ____ \( \      (  ____ \(       )(  ____ \( (    /|\__   __/  ║
║  | (    )|| (  \  )           | (    \/| (      | (    \/| () () || (    \/|  \  ( |   ) (     ║
║  | (____)|| |   ) |   _____   | (__    | |      | (__    | || || || (__    |   \ | |   | |     ║
║  |  _____)| |   | |  (_____)  |  __)   | |      |  __)   | |(_)| ||  __)   | (\ \) |   | |     ║
║  | (      | |   ) |           | (      | |      | (      | |   | || (      | | \   |   | |     ║
║  | )      | (__/  )           | (____/\| (____/\| (____/\| )   ( || (____/\| )  \  |   | |     ║
║  |/       (______/            (_______/(_______/(_______/|/     \|(_______/|/    )_)   )_(     ║
║                                                                                                ║
╚════════════════════════════════════════════════════════════════════════════════════════════════╝


BANNER


#############################################
# Helpers
#############################################

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run this script as ROOT (sudo -i)."
    exit 1
  fi
}

print_header() {
  clear || true
  echo "$ASCII_BANNER"
  echo "🚀 Matrix Stack Manager v${VERSION}"
  echo "🔗 Telegram: https://t.me/amirabbas_jadidi"
  echo "🐈‍⬛ GitHub : https://github.com/Amirabbasjadidi/PD-Element-Local"
  echo "📝 Log file: ${LOG_FILE}"
  echo
}

pause() {
  read -rp "Press Enter to continue..." _
}

save_config() {
  local HS_DOMAIN="$1"
  local ELEMENT_DOMAIN="$2"
  local BASE_DOMAIN="$3"
  local PUBLIC_IP="$4"
  local CA_DIR="$5"
  local CA_VALID_YEARS="$6"
  local EXTRA_SANS="$7"

  mkdir -p "$(dirname "${CONFIG_FILE}")"
  cat > "${CONFIG_FILE}" <<EOF
HS_DOMAIN=${HS_DOMAIN}
ELEMENT_DOMAIN=${ELEMENT_DOMAIN}
BASE_DOMAIN=${BASE_DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
CA_DIR=${CA_DIR}
CA_VALID_YEARS=${CA_VALID_YEARS}
EXTRA_SANS=${EXTRA_SANS}
EOF
}

load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    return 0
  fi
  if [[ -f "${LEGACY_CONFIG_FILE:-}" ]]; then
    # shellcheck disable=SC1090
    source "${LEGACY_CONFIG_FILE}"
    return 0
  fi
  return 1
}

ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt update
    apt install -y "$pkg"
  fi
}

ensure_sqlite_installed() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "📦 Installing sqlite3..."
    apt update
    apt install -y sqlite3
  fi
}

restart_services() {
  local failed=0
  systemctl restart matrix-synapse || failed=1
  systemctl restart coturn || failed=1
  systemctl reload nginx || failed=1
  return "${failed}"
}

detect_arch() {
  uname -m
}
log_info() {
  local msg="$*"
  echo "[$(date '+%F %T')] INFO: ${msg}"
  logger -t matrix-installer -p user.info -- "${msg}" 2>/dev/null || true
}

log_error() {
  local msg="$*"
  echo "[$(date '+%F %T')] ERROR: ${msg}" >&2
  logger -t matrix-installer -p user.err -- "${msg}" 2>/dev/null || true
}

err_report() {
  local exit_code=$? line_no=${BASH_LINENO[0]:-unknown} cmd=${BASH_COMMAND:-unknown}
  log_error "Command failed at line ${line_no}: ${cmd} (exit code: ${exit_code})"
  log_error "Stack trace: ${FUNCNAME[*]:-main}"
  rollback_if_needed "${exit_code}" "${cmd}"
  exit "${exit_code}"
}

run_cmd() {
  local label="$1"
  shift
  log_info "START: ${label}"
  if "$@"; then
    log_info "OK: ${label}"
    return 0
  fi
  local exit_code=$?
  log_error "FAILED: ${label} (exit code: ${exit_code})"
  return "${exit_code}"
}

validate_domain() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ && "${value}" == *.* ]]
}

validate_ip_or_host() {
  local value="$1"
  [[ -n "${value}" && "${value}" =~ ^[A-Za-z0-9:.-]+$ ]]
}

validate_positive_int() {
  local value="$1" max="${2:-36500}"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1 && "${value}" -le "${max}" ]]
}

LOCK_FILE="/run/matrix-installer.lock"
ROLLBACK_ACTIVE=0
ROLLBACK_DIR=""
ROLLBACK_REASON=""

acquire_lock() {
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    echo "Another matrix-installer instance is already running."
    exit 1
  fi
}

rollback_begin() {
  ROLLBACK_ACTIVE=1
  ROLLBACK_REASON="${1:-operation}"
  ROLLBACK_DIR="$(mktemp -d /tmp/matrix-installer-rollback.XXXXXX)"
  mkdir -p "${ROLLBACK_DIR}"
  log_info "Rollback snapshot started for ${ROLLBACK_REASON}: ${ROLLBACK_DIR}"
}

rollback_capture_path() {
  local path="$1" rel
  [[ "${ROLLBACK_ACTIVE}" -eq 1 ]] || return 0
  rel="${path#/}"
  mkdir -p "${ROLLBACK_DIR}/files/$(dirname "${rel}")"
  if [[ -e "${path}" || -L "${path}" ]]; then
    cp -a "${path}" "${ROLLBACK_DIR}/files/${rel}"
    echo "present:${path}" >> "${ROLLBACK_DIR}/manifest"
  else
    echo "absent:${path}" >> "${ROLLBACK_DIR}/manifest"
  fi
}

rollback_capture_standard_paths() {
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}"
  local paths=(
    "${CONFIG_FILE}"
    "${LEGACY_CONFIG_FILE}"
    "${ca_dir}"
    "/etc/matrix-synapse"
    "/etc/nginx/sites-available/matrix.conf"
    "/etc/nginx/sites-available/element.conf"
    "/etc/nginx/sites-available/wellknown.conf"
    "/etc/nginx/sites-enabled/matrix.conf"
    "/etc/nginx/sites-enabled/element.conf"
    "/etc/nginx/sites-enabled/wellknown.conf"
    "/etc/turnserver.conf"
    "/etc/default/coturn"
    "/var/www/element"
  )
  local item
  for item in "${paths[@]}"; do
    rollback_capture_path "${item}"
  done
}

rollback_commit() {
  ROLLBACK_ACTIVE=0
  [[ -n "${ROLLBACK_DIR}" ]] && rm -rf "${ROLLBACK_DIR}" || true
  ROLLBACK_DIR=""
}

rollback_if_needed() {
  local exit_code="${1:-1}" failed_cmd="${2:-unknown}"

  [[ "${ROLLBACK_ACTIVE}" -eq 1 && -n "${ROLLBACK_DIR}" && -f "${ROLLBACK_DIR}/manifest" ]] || return 0

  log_error "Rolling back ${ROLLBACK_REASON}; failed command: ${failed_cmd}; exit code: ${exit_code}"

  while IFS=: read -r state path; do
    [[ -n "${path:-}" ]] || continue

    local rel="${path#/}"

    if [[ "${state}" == "present" ]]; then
      echo "[RESTORE] ${path}"

      rm -rf "${path}"

      mkdir -p "$(dirname "${path}")"

      if [[ -e "${ROLLBACK_DIR}/files/${rel}" ]]; then
        cp -a "${ROLLBACK_DIR}/files/${rel}" "${path}"
      fi

    else
      echo "[REMOVE] ${path}"

      rm -rf "${path}"

    fi

  done < "${ROLLBACK_DIR}/manifest"


  systemctl daemon-reload || true

  restart_services || true


  ROLLBACK_ACTIVE=0

  log_error "Rollback finished. Original error: ${failed_cmd} (exit code: ${exit_code})"
}

trap err_report ERR


#############################################
# Enterprise Offline PKI / Certificates
#############################################

CA_DIR_DEFAULT="/etc/matrix-pki"
SERVER_CERT_NAME="matrix-stack"
ROOT_CA_YEARS_DEFAULT=20
INTERMEDIATE_CA_YEARS_DEFAULT=10
SERVER_CERT_DAYS_DEFAULT=730
RENEW_THRESHOLD_DAYS_DEFAULT=30
PKI_COUNTRY_DEFAULT="IR"
PKI_ORG_DEFAULT="Matrix Local Network"
PKI_ROOT_CN_DEFAULT="Matrix Offline Root CA"
PKI_INTERMEDIATE_CN_DEFAULT="Matrix Intermediate CA"

is_ip_address() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "${value}" =~ : ]]
}

validate_ca_years() {
  local years="$1"
  [[ "${years}" =~ ^[0-9]+$ && "${years}" -ge 1 && "${years}" -le 20 ]]
}

normalize_csv() {
  local value="${1:-}"
  echo "${value}" | tr ';' ',' | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

append_san_entry() {
  local value="$1"
  [[ -z "${value}" ]] && return 0
  if is_ip_address "${value}"; then
    SAN_ENTRIES+=("IP:${value}")
  else
    SAN_ENTRIES+=("DNS:${value}")
  fi
}

pki_log() {
  log_info "$*"
}

pki_root_dir() { echo "${1:-${CA_DIR_DEFAULT}}/root"; }
pki_intermediate_dir() { echo "${1:-${CA_DIR_DEFAULT}}/intermediate"; }
pki_live_dir() { echo "${1:-${CA_DIR_DEFAULT}}/live/${SERVER_CERT_NAME}"; }

get_root_cert_path() { echo "${1:-${CA_DIR_DEFAULT}}/root/certs/rootCA.crt.pem"; }
get_intermediate_cert_path() { echo "${1:-${CA_DIR_DEFAULT}}/intermediate/certs/intermediate.crt.pem"; }
get_chain_path() { echo "${1:-${CA_DIR_DEFAULT}}/intermediate/certs/chain.pem"; }

get_server_cert_path() {
  local ca_dir="${1:-${CA_DIR_DEFAULT}}"
  echo "${ca_dir}/live/${SERVER_CERT_NAME}/fullchain.pem"
}

get_server_leaf_cert_path() {
  local ca_dir="${1:-${CA_DIR_DEFAULT}}"
  echo "${ca_dir}/live/${SERVER_CERT_NAME}/cert.pem"
}

get_server_key_path() {
  local ca_dir="${1:-${CA_DIR_DEFAULT}}"
  echo "${ca_dir}/live/${SERVER_CERT_NAME}/privkey.pem"
}

pki_init_db() {
  local dir="$1"
  mkdir -p "${dir}/private" "${dir}/certs" "${dir}/crl" "${dir}/newcerts"
  chmod 700 "${dir}/private"
  touch "${dir}/index.txt"
  [[ -f "${dir}/index.txt.attr" ]] || echo "unique_subject = no" > "${dir}/index.txt.attr"
  [[ -f "${dir}/serial" ]] || echo 1000 > "${dir}/serial"
  [[ -f "${dir}/crlnumber" ]] || echo 1000 > "${dir}/crlnumber"
}

pki_write_root_openssl_cnf() {
  local ca_dir="$1" root_dir
  root_dir="$(pki_root_dir "${ca_dir}")"
  cat > "${root_dir}/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${root_dir}
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
private_key       = \$dir/private/rootCA.key.pem
certificate       = \$dir/certs/rootCA.crt.pem
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/rootCA.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 365
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 3650
preserve          = no
policy            = policy_strict
copy_extensions   = copy
unique_subject    = no

[ policy_strict ]
countryName             = optional
stateOrProvinceName     = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = v3_ca

[ req_distinguished_name ]
commonName = Common Name

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF
}

pki_write_intermediate_openssl_cnf() {
  local ca_dir="$1" int_dir
  int_dir="$(pki_intermediate_dir "${ca_dir}")"
  cat > "${int_dir}/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${int_dir}
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand
private_key       = \$dir/private/intermediate.key.pem
certificate       = \$dir/certs/intermediate.crt.pem
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/intermediate.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = ${SERVER_CERT_DAYS_DEFAULT}
preserve          = no
policy            = policy_loose
copy_extensions   = copy
unique_subject    = no

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256

[ req_distinguished_name ]
commonName = Common Name

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "Matrix Enterprise LAN Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF
}

pki_create_root_ca() {
  local ca_dir="${1:-${CA_DIR_DEFAULT}}"
  local years="${2:-${ROOT_CA_YEARS_DEFAULT}}"
  local root_dir root_key root_cert days
  root_dir="$(pki_root_dir "${ca_dir}")"
  root_key="${root_dir}/private/rootCA.key.pem"
  root_cert="${root_dir}/certs/rootCA.crt.pem"
  days=$((years * 365))

  pki_init_db "${root_dir}"
  pki_write_root_openssl_cnf "${ca_dir}"

  if [[ -f "${root_key}" && -f "${root_cert}" ]]; then
    pki_log "Existing Offline Root CA found: ${root_cert}"
    return 0
  fi

  pki_log "Generating Offline Root CA (${years} years)."
  run_cmd "Generate Root CA private key" openssl genrsa -out "${root_key}" 4096
  chmod 600 "${root_key}"
  run_cmd "Generate Root CA certificate" openssl req -config "${root_dir}/openssl.cnf" -key "${root_key}" -new -x509 -days "${days}" -sha256 -extensions v3_ca -out "${root_cert}" -subj "/C=${PKI_COUNTRY_DEFAULT}/O=${PKI_ORG_DEFAULT}/OU=Offline Root/CN=${PKI_ROOT_CN_DEFAULT}"
  cp "${root_cert}" "${ca_dir}/rootCA.pem"
  chmod 644 "${root_cert}" "${ca_dir}/rootCA.pem"
}

pki_create_intermediate_ca() {
  local ca_dir="${1:-${CA_DIR_DEFAULT}}"
  local years="${2:-${INTERMEDIATE_CA_YEARS_DEFAULT}}"
  local root_dir int_dir int_key int_csr int_cert chain days
  root_dir="$(pki_root_dir "${ca_dir}")"
  int_dir="$(pki_intermediate_dir "${ca_dir}")"
  int_key="${int_dir}/private/intermediate.key.pem"
  int_csr="${int_dir}/csr/intermediate.csr.pem"
  int_cert="${int_dir}/certs/intermediate.crt.pem"
  chain="${int_dir}/certs/chain.pem"
  days=$((years * 365))

  if [[ ! -f "$(get_root_cert_path "${ca_dir}")" && ! -f "${root_dir}/private/rootCA.key.pem" ]]; then
    pki_create_root_ca "${ca_dir}" "${ROOT_CA_YEARS_DEFAULT}"
  elif [[ ! -f "${root_dir}/private/rootCA.key.pem" ]]; then
    echo "Root private key is offline. Import it temporarily to sign a new Intermediate."
    return 1
  fi
  pki_init_db "${int_dir}"
  mkdir -p "${int_dir}/csr"
  pki_write_intermediate_openssl_cnf "${ca_dir}"

  if [[ -f "${int_key}" && -f "${int_cert}" ]]; then
    pki_log "Existing Intermediate CA found: ${int_cert}"
    cat "${int_cert}" "$(get_root_cert_path "${ca_dir}")" > "${chain}"
    cp "${int_cert}" "${ca_dir}/intermediateCA.pem"
    return 0
  fi

  pki_log "Generating Intermediate CA (${years} years). Root key is used only for this signing step."
  run_cmd "Generate Intermediate CA private key" openssl genrsa -out "${int_key}" 4096
  chmod 600 "${int_key}"
  run_cmd "Generate Intermediate CA CSR" openssl req -config "${int_dir}/openssl.cnf" -new -sha256 -key "${int_key}" -out "${int_csr}" -subj "/C=${PKI_COUNTRY_DEFAULT}/O=${PKI_ORG_DEFAULT}/OU=Intermediate CA/CN=${PKI_INTERMEDIATE_CN_DEFAULT}"
  run_cmd "Sign Intermediate CA with Root CA" openssl ca -batch -config "${root_dir}/openssl.cnf" -extensions v3_intermediate_ca -days "${days}" -notext -md sha256 -in "${int_csr}" -out "${int_cert}"
  chmod 644 "${int_cert}"
  cat "${int_cert}" "$(get_root_cert_path "${ca_dir}")" > "${chain}"
  cp "${int_cert}" "${ca_dir}/intermediateCA.pem"
}

pki_build_san_entries() {
  local dns_csv="${1:-}" ip_csv="${2:-}" extra_csv="${3:-}"
  SAN_ENTRIES=()
  local item
  IFS=',' read -ra dns_items <<< "$(normalize_csv "${dns_csv}")"
  for item in "${dns_items[@]}"; do item="$(echo "${item}" | xargs)"; [[ -n "${item}" ]] && SAN_ENTRIES+=("DNS:${item}"); done
  IFS=',' read -ra ip_items <<< "$(normalize_csv "${ip_csv}")"
  for item in "${ip_items[@]}"; do item="$(echo "${item}" | xargs)"; [[ -n "${item}" ]] && SAN_ENTRIES+=("IP:${item}"); done
  IFS=',' read -ra extra_items <<< "$(normalize_csv "${extra_csv}")"
  for item in "${extra_items[@]}"; do item="$(echo "${item}" | xargs)"; append_san_entry "${item}"; done
}

pki_write_server_req_cnf() {
  local cn="$1" san_line="$2" out="$3"
  cat > "${out}" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = ${PKI_COUNTRY_DEFAULT}
O  = ${PKI_ORG_DEFAULT}
OU = Matrix Stack
CN = ${cn}

[ req_ext ]
subjectAltName = ${san_line}
EOF
}

pki_install_ca_to_system() {
  local ca_dir="${1:-${CA_DIR_DEFAULT}}"
  if [[ -d /usr/local/share/ca-certificates ]]; then
    cp "$(get_root_cert_path "${ca_dir}")" /usr/local/share/ca-certificates/matrix-stack-root-ca.crt
    cp "$(get_intermediate_cert_path "${ca_dir}")" /usr/local/share/ca-certificates/matrix-stack-intermediate-ca.crt
    update-ca-certificates || true
  fi
}

pki_issue_server_certificate() {
  local ca_dir="${1:-${CA_DIR_DEFAULT}}" cn="$2" dns_csv="$3" ip_csv="$4" extra_csv="${5:-}" days="${6:-${SERVER_CERT_DAYS_DEFAULT}}"
  local int_dir live_dir key csr cert fullchain bundle req_cnf san_line backup_dir
  int_dir="$(pki_intermediate_dir "${ca_dir}")"
  live_dir="$(pki_live_dir "${ca_dir}")"
  key="${live_dir}/privkey.pem"
  csr="${live_dir}/server.csr.pem"
  cert="${live_dir}/cert.pem"
  fullchain="${live_dir}/fullchain.pem"
  bundle="${live_dir}/bundle.pem"
  req_cnf="${live_dir}/server-req.cnf"

  pki_create_intermediate_ca "${ca_dir}" "${INTERMEDIATE_CA_YEARS_DEFAULT}"
  mkdir -p "${live_dir}"
  chmod 700 "${live_dir}"

  backup_dir="$(mktemp -d)"
  if [[ -d "${live_dir}" ]]; then cp -a "${live_dir}/." "${backup_dir}/" 2>/dev/null || true; fi

  pki_build_san_entries "${dns_csv}" "${ip_csv}" "${extra_csv}"
  if [[ ${#SAN_ENTRIES[@]} -eq 0 ]]; then
    echo "At least one DNS or IP SAN is required."
    rm -rf "${backup_dir}"
    return 1
  fi
  san_line="$(IFS=,; echo "${SAN_ENTRIES[*]}")"

  if ! {
    openssl genrsa -out "${key}" 4096 &&
    chmod 600 "${key}" &&
    pki_write_server_req_cnf "${cn}" "${san_line}" "${req_cnf}" &&
    openssl req -new -key "${key}" -out "${csr}" -config "${req_cnf}" &&
    openssl ca -batch -config "${int_dir}/openssl.cnf" -extensions server_cert -days "${days}" -notext -md sha256 -in "${csr}" -out "${cert}" &&
    cat "${cert}" "$(get_intermediate_cert_path "${ca_dir}")" > "${fullchain}" &&
    cat "${cert}" "$(get_intermediate_cert_path "${ca_dir}")" "$(get_root_cert_path "${ca_dir}")" > "${bundle}" &&
    chmod 644 "${cert}" "${fullchain}" "${bundle}" &&
    pki_install_ca_to_system "${ca_dir}"
  }; then
    pki_log "Certificate operation failed; restoring previous live certificate files."
    cp -a "${backup_dir}/." "${live_dir}/" 2>/dev/null || true
    rm -rf "${backup_dir}"
    return 1
  fi

  cat > "${live_dir}/issue.env" <<EOF
CERT_CN=${cn}
CERT_DNS=${dns_csv}
CERT_IPS=${ip_csv}
CERT_EXTRA=${extra_csv}
CERT_DAYS=${days}
EOF
  chmod 600 "${live_dir}/issue.env"
  rm -rf "${backup_dir}"
  pki_log "Server certificate issued by Intermediate CA: ${fullchain}"
}

create_custom_ca_and_server_cert() {
  local HS_DOMAIN="$1" ELEMENT_DOMAIN="$2" BASE_DOMAIN="$3" PUBLIC_IP="$4" CA_DIR="$5" CA_VALID_YEARS="${6:-20}" EXTRA_SANS="${7:-}"
  local server_days="${SERVER_CERT_DAYS:-${SERVER_CERT_DAYS_DEFAULT}}"
  ROOT_CA_YEARS_DEFAULT="${CA_VALID_YEARS:-20}"
  pki_issue_server_certificate "${CA_DIR}" "${HS_DOMAIN}" "${HS_DOMAIN},${ELEMENT_DOMAIN},${BASE_DOMAIN}" "${PUBLIC_IP}" "${EXTRA_SANS}" "${server_days}"
  echo "Local Root CA:        $(get_root_cert_path "${CA_DIR}")"
  echo "Intermediate CA:      $(get_intermediate_cert_path "${CA_DIR}")"
  echo "Server certificate:   $(get_server_cert_path "${CA_DIR}")"
  echo "Server private key:   $(get_server_key_path "${CA_DIR}")"
}

pki_generate_root_menu() {
  print_header
  echo "=== Generate Offline Root CA ==="
  load_config || true
  read -rp "PKI path [${CA_DIR:-${CA_DIR_DEFAULT}}]: " ca_dir
  ca_dir="${ca_dir:-${CA_DIR:-${CA_DIR_DEFAULT}}}"
  read -rp "Root validity years [20]: " years
  years="${years:-20}"
  pki_create_root_ca "${ca_dir}" "${years}"
  pause
}

pki_generate_intermediate_menu() {
  print_header
  echo "=== Generate Intermediate CA ==="
  load_config || true
  read -rp "PKI path [${CA_DIR:-${CA_DIR_DEFAULT}}]: " ca_dir
  ca_dir="${ca_dir:-${CA_DIR:-${CA_DIR_DEFAULT}}}"
  pki_create_intermediate_ca "${ca_dir}" "${INTERMEDIATE_CA_YEARS_DEFAULT}"
  pause
}


pki_export_root_certificate_menu() {
  print_header
  echo "=== Export Root Certificate ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" out_dir root_cert
  read -rp "PKI path [${ca_dir}]: " ca_in; ca_dir="${ca_in:-${ca_dir}}"
  root_cert="$(get_root_cert_path "${ca_dir}")"
  [[ -f "${root_cert}" ]] || { echo "Root certificate not found: ${root_cert}"; pause; return 1; }
  out_dir="${ca_dir}/exports/root-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${out_dir}"
  cp "${root_cert}" "${out_dir}/rootCA.crt"
  cp "${root_cert}" "${out_dir}/rootCA.pem"
  openssl x509 -in "${root_cert}" -outform der -out "${out_dir}/rootCA.der"
  echo "Root certificate exported to: ${out_dir}"
  pause
}

pki_remove_root_private_key_menu() {
  print_header
  echo "=== Remove Root Private Key From Server ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" root_key archive
  read -rp "PKI path [${ca_dir}]: " ca_in; ca_dir="${ca_in:-${ca_dir}}"
  root_key="$(pki_root_dir "${ca_dir}")/private/rootCA.key.pem"
  [[ -f "${root_key}" ]] || { echo "Root private key is already absent: ${root_key}"; pause; return 0; }
  read -rp "Type REMOVE-ROOT-KEY to delete the Root private key from this server: " confirm
  [[ "${confirm}" == "REMOVE-ROOT-KEY" ]] || { echo "Cancelled."; pause; return 0; }
  archive="${ca_dir}/root/private/rootCA.key.removed-$(date +%Y%m%d-%H%M%S).sha256"
  sha256sum "${root_key}" > "${archive}"
  shred -u "${root_key}" 2>/dev/null || rm -f "${root_key}"
  chmod 600 "${archive}"
  echo "Root private key removed. Fingerprint record: ${archive}"
  pause
}

pki_import_root_private_key_menu() {
  print_header
  echo "=== Temporarily Import Root Private Key ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" source_key root_key
  read -rp "PKI path [${ca_dir}]: " ca_in; ca_dir="${ca_in:-${ca_dir}}"
  read -rp "Root private key source path: " source_key
  [[ -f "${source_key}" ]] || { echo "Source key not found."; pause; return 1; }
  root_key="$(pki_root_dir "${ca_dir}")/private/rootCA.key.pem"
  mkdir -p "$(dirname "${root_key}")"
  install -m 600 "${source_key}" "${root_key}"
  echo "Root key imported temporarily. Remove it after signing any new Intermediate."
  pause
}

pki_rotate_intermediate_menu() {
  print_header
  echo "=== Rotate Intermediate CA ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" int_dir old_dir ts root_key
  read -rp "PKI path [${ca_dir}]: " ca_in; ca_dir="${ca_in:-${ca_dir}}"
  root_key="$(pki_root_dir "${ca_dir}")/private/rootCA.key.pem"
  [[ -f "${root_key}" ]] || { echo "Root private key is required temporarily to sign a new Intermediate."; pause; return 1; }
  int_dir="$(pki_intermediate_dir "${ca_dir}")"
  ts="$(date +%Y%m%d-%H%M%S)"
  old_dir="${ca_dir}/intermediate-archive/${ts}"
  mkdir -p "$(dirname "${old_dir}")"
  if [[ -d "${int_dir}" ]]; then
    mv "${int_dir}" "${old_dir}"
    echo "Previous Intermediate archived at: ${old_dir}"
  fi
  pki_create_intermediate_ca "${ca_dir}" "${INTERMEDIATE_CA_YEARS_DEFAULT}"
  read -rp "Reissue all known server certificates with the new Intermediate now? (y/n): " yn
  if [[ "${yn}" == "y" || "${yn}" == "Y" ]]; then
    pki_reissue_all_server_certificates "${ca_dir}"
    restart_services || true
  fi
  pause
}

pki_reissue_all_server_certificates() {
  local ca_dir
  local live_root
  local issued=0
  local live_dir

  ca_dir="${1:-${CA_DIR_DEFAULT}}"
  live_root="${ca_dir}/live"

  if [[ -d "${live_root}" ]]; then
    for live_dir in "${live_root}"/*; do
      [[ -d "${live_dir}" ]] || continue

      if [[ -f "${live_dir}/issue.env" ]]; then
        # shellcheck disable=SC1090
        source "${live_dir}/issue.env"

        pki_issue_server_certificate \
          "${ca_dir}" \
          "${CERT_CN}" \
          "${CERT_DNS}" \
          "${CERT_IPS}" \
          "${CERT_EXTRA:-}" \
          "${CERT_DAYS:-${SERVER_CERT_DAYS_DEFAULT}}"

        issued=$((issued + 1))
      fi
    done
  fi

  if [[ "${issued}" -eq 0 ]]; then
    pki_issue_server_certificate \
      "${ca_dir}" \
      "${HS_DOMAIN:-matrix.local}" \
      "${HS_DOMAIN:-},${ELEMENT_DOMAIN:-},${BASE_DOMAIN:-}" \
      "${PUBLIC_IP:-}" \
      "${EXTRA_SANS:-}" \
      "${SERVER_CERT_DAYS:-${SERVER_CERT_DAYS_DEFAULT}}"
  fi
}
pki_issue_menu() {
  print_header
  echo "=== Issue Server Certificate ==="
  load_config || true
  read -rp "PKI path [${CA_DIR:-${CA_DIR_DEFAULT}}]: " ca_dir; ca_dir="${ca_dir:-${CA_DIR:-${CA_DIR_DEFAULT}}}"
  read -rp "Certificate CN [${HS_DOMAIN:-matrix.local}]: " cn; cn="${cn:-${HS_DOMAIN:-matrix.local}}"
  read -rp "DNS SANs comma-separated [${HS_DOMAIN:-},${ELEMENT_DOMAIN:-},${BASE_DOMAIN:-}]: " dns
  dns="${dns:-${HS_DOMAIN:-},${ELEMENT_DOMAIN:-},${BASE_DOMAIN:-}}"
  read -rp "IP SANs comma-separated [${PUBLIC_IP:-}]: " ips; ips="${ips:-${PUBLIC_IP:-}}"
  read -rp "Extra DNS/IP SANs comma-separated (optional): " extra
  read -rp "Server certificate days [${SERVER_CERT_DAYS:-${SERVER_CERT_DAYS_DEFAULT}}]: " days; days="${days:-${SERVER_CERT_DAYS:-${SERVER_CERT_DAYS_DEFAULT}}}"
  pki_issue_server_certificate "${ca_dir}" "${cn}" "${dns}" "${ips}" "${extra}" "${days}"
  restart_services
  pause
}

pki_reissue_menu() {
  print_header
  echo "=== Reissue Server Certificate ==="
  pki_issue_menu
}

pki_cert_days_left() {
  local cert="$1" end epoch now
  [[ -f "${cert}" ]] || { echo -1; return; }
  end="$(openssl x509 -in "${cert}" -noout -enddate | cut -d= -f2-)"
  epoch="$(date -d "${end}" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch - now) / 86400 ))
}

pki_renew_menu() {
  print_header
  echo "=== Renew Server Certificate ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" cert days_left threshold
  cert="$(get_server_leaf_cert_path "${ca_dir}")"
  days_left="$(pki_cert_days_left "${cert}")"
  read -rp "Renew if fewer than how many days remain? [${RENEW_THRESHOLD_DAYS:-${RENEW_THRESHOLD_DAYS_DEFAULT}}]: " threshold
  threshold="${threshold:-${RENEW_THRESHOLD_DAYS:-${RENEW_THRESHOLD_DAYS_DEFAULT}}}"
  echo "Current server certificate days left: ${days_left}"
  if [[ "${days_left}" -ge "${threshold}" ]]; then
    read -rp "Certificate is not inside the renew window. Renew anyway? (y/n): " yn
    [[ "${yn}" == "y" || "${yn}" == "Y" ]] || { pause; return 0; }
  fi
  pki_issue_server_certificate "${ca_dir}" "${HS_DOMAIN:-matrix.local}" "${HS_DOMAIN:-},${ELEMENT_DOMAIN:-},${BASE_DOMAIN:-}" "${PUBLIC_IP:-}" "${EXTRA_SANS:-}" "${SERVER_CERT_DAYS:-${SERVER_CERT_DAYS_DEFAULT}}"
  restart_services
  pause
}

pki_revoke_menu() {
  print_header
  echo "=== Revoke Server Certificate ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" int_dir cert reason
  int_dir="$(pki_intermediate_dir "${ca_dir}")"
  cert="$(get_server_leaf_cert_path "${ca_dir}")"
  read -rp "Certificate to revoke [${cert}]: " cert_in; cert="${cert_in:-${cert}}"
  [[ -f "${cert}" ]] || { echo "Certificate not found: ${cert}"; pause; return 1; }
  read -rp "Reason [keyCompromise]: " reason; reason="${reason:-keyCompromise}"
  openssl ca -config "${int_dir}/openssl.cnf" -revoke "${cert}" -crl_reason "${reason}"
  openssl ca -config "${int_dir}/openssl.cnf" -gencrl -out "${int_dir}/crl/intermediate.crl.pem"
  echo "CRL: ${int_dir}/crl/intermediate.crl.pem"
  pause
}

pki_verify_certificate() {
  local ca_dir
  local cert
  local key
  local chain
  local root_cert
  local int_cert
  local failed=0

  ca_dir="${1:-${CA_DIR_DEFAULT}}"
  cert="${2:-$(get_server_leaf_cert_path "${ca_dir}")}"
  key="${3:-$(get_server_key_path "${ca_dir}")}"

  chain="$(get_chain_path "${ca_dir}")"
  root_cert="$(get_root_cert_path "${ca_dir}")"
  int_cert="$(get_intermediate_cert_path "${ca_dir}")"

  echo "Certificate Chain:"
  openssl verify -CAfile "${chain}" "${cert}" || failed=1
  echo

  echo "SAN:"
  openssl x509 -in "${cert}" -noout -ext subjectAltName || failed=1
  echo

  echo "Expire Date:"
  openssl x509 -in "${cert}" -noout -dates || failed=1
  echo "Remaining Days: $(pki_cert_days_left "${cert}")"
  echo

  echo "Private Key Match:"
  if [[ -f "${key}" ]]; then
    local cert_mod
    local key_mod

    cert_mod="$(openssl x509 -noout -modulus -in "${cert}" | openssl md5)"
    key_mod="$(openssl rsa -noout -modulus -in "${key}" 2>/dev/null | openssl md5)"

    if [[ "${cert_mod}" == "${key_mod}" ]]; then
      echo "OK"
    else
      echo "FAILED"
      failed=1
    fi
  else
    echo "Key not found: ${key}"
    failed=1
  fi

  echo

  echo "Root Trust:"
  if [[ -f "${root_cert}" ]]; then
    openssl verify -CAfile "${root_cert}" "${root_cert}" || failed=1
  else
    echo "Root certificate not found: ${root_cert}"
    failed=1
  fi

  echo

  echo "Intermediate Trust:"
  if [[ -f "${int_cert}" ]]; then
    openssl verify -CAfile "${root_cert}" "${int_cert}" || failed=1
  else
    echo "Intermediate certificate not found: ${int_cert}"
    failed=1
  fi

  echo

  echo "Issuer:"
  openssl x509 -in "${cert}" -noout -issuer || failed=1

  echo

  echo "Fingerprint:"
  openssl x509 -in "${cert}" -noout -fingerprint -sha256 || failed=1

  return "${failed}"
}

pki_verify_menu() {
  print_header
  echo "=== Verify Certificate ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" cert key
  read -rp "PKI path [${ca_dir}]: " ca_in; ca_dir="${ca_in:-${ca_dir}}"
  cert="$(get_server_leaf_cert_path "${ca_dir}")"
  key="$(get_server_key_path "${ca_dir}")"
  read -rp "Certificate path [${cert}]: " cert_in; cert="${cert_in:-${cert}}"
  read -rp "Private key path [${key}]: " key_in; key="${key_in:-${key}}"
  pki_verify_certificate "${ca_dir}" "${cert}" "${key}"
  pause
}

pki_certificate_viewer_menu() {
  print_header
  echo "=== Certificate Viewer ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" cert
  cert="$(get_server_leaf_cert_path "${ca_dir}")"
  read -rp "Certificate path [${cert}]: " cert_in; cert="${cert_in:-${cert}}"
  [[ -f "${cert}" ]] || { echo "Certificate not found: ${cert}"; pause; return 1; }
  echo "Subject: $(openssl x509 -in "${cert}" -noout -subject | sed 's/^subject=//')"
  echo "Issuer: $(openssl x509 -in "${cert}" -noout -issuer | sed 's/^issuer=//')"
  echo "Serial: $(openssl x509 -in "${cert}" -noout -serial | cut -d= -f2-)"
  echo "Fingerprint: $(openssl x509 -in "${cert}" -noout -fingerprint -sha256 | cut -d= -f2-)"
  echo "Signature Algorithm: $(openssl x509 -in "${cert}" -noout -text | awk -F': ' '/Signature Algorithm/ {print $2; exit}')"
  echo "SAN:"
  openssl x509 -in "${cert}" -noout -ext subjectAltName | sed 's/^/  /' || true
  openssl x509 -in "${cert}" -noout -dates
  echo "Remaining Days: $(pki_cert_days_left "${cert}")"
  pause
}

pki_export_menu() {
  print_header
  echo "=== Export Certificates ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" export_root ts live root_cert root_key int_cert server_cert server_key fullchain bundle chain pass archive_fmt archive_path
  ts="$(date +%Y%m%d-%H%M%S)"
  read -rp "PKI path [${ca_dir}]: " ca_in; ca_dir="${ca_in:-${ca_dir}}"
  echo "Archive format: 1) ZIP  2) TAR.GZ"
  read -rp "Choose [1-2]: " fmt
  export_root="${ca_dir}/exports/${ts}"
  live="$(pki_live_dir "${ca_dir}")"
  root_cert="$(get_root_cert_path "${ca_dir}")"
  root_key="$(pki_root_dir "${ca_dir}")/private/rootCA.key.pem"
  int_cert="$(get_intermediate_cert_path "${ca_dir}")"
  server_cert="$(get_server_leaf_cert_path "${ca_dir}")"
  server_key="$(get_server_key_path "${ca_dir}")"
  fullchain="$(get_server_cert_path "${ca_dir}")"
  bundle="${live}/bundle.pem"
  chain="$(get_chain_path "${ca_dir}")"
  read -rsp "PKCS#12 export password [changeit]: " pass; echo; pass="${pass:-changeit}"
  mkdir -p "${export_root}"/{MikroTik,Windows,Linux,Android}
  cp "${server_cert}" "${export_root}/server.crt"
  cp "${server_key}" "${export_root}/server.key"
  cat "${server_cert}" "${server_key}" > "${export_root}/server.pem"
  openssl pkcs12 -export -inkey "${server_key}" -in "${server_cert}" -certfile "${chain}" -out "${export_root}/server.p12" -passout "pass:${pass}"
  openssl x509 -in "${server_cert}" -outform der -out "${export_root}/server.der"
  cp "${fullchain}" "${export_root}/fullchain.pem"
  cp "${bundle}" "${export_root}/bundle.pem"
  cp "${chain}" "${export_root}/chain.pem"
  cp "${root_cert}" "${export_root}/rootCA.crt"
  cp "${root_cert}" "${export_root}/rootCA.pem"
  openssl x509 -in "${root_cert}" -outform der -out "${export_root}/rootCA.der"
  if [[ -f "${root_key}" ]]; then
    openssl pkcs12 -export -inkey "${root_key}" -in "${root_cert}" -out "${export_root}/rootCA.p12" -passout "pass:${pass}"
  else
    echo "Root private key is offline; rootCA.p12 skipped."
  fi
  cp "${int_cert}" "${export_root}/intermediate.crt"
  cp "${int_cert}" "${export_root}/intermediate.pem"
  openssl x509 -in "${int_cert}" -outform der -out "${export_root}/intermediate.der"
  cp "${server_cert}" "${server_key}" "${root_cert}" "${int_cert}" "${export_root}/MikroTik/"
  cp "${export_root}/server.p12" "${export_root}/rootCA.crt" "${export_root}/intermediate.crt" "${export_root}/Windows/"
  cp "${export_root}/fullchain.pem" "${export_root}/chain.pem" "${export_root}/rootCA.pem" "${export_root}/intermediate.pem" "${export_root}/Linux/"
  cp "${export_root}/rootCA.crt" "${export_root}/intermediate.crt" "${export_root}/Android/"
  if [[ "${fmt}" == "1" ]]; then
    archive_fmt="zip"
    archive_path="${export_root}.zip"
    (cd "$(dirname "${export_root}")" && zip -qr "${archive_path}" "$(basename "${export_root}")")
  else
    archive_fmt="tar.gz"
    archive_path="${export_root}.tar.gz"
    tar -czf "${archive_path}" -C "$(dirname "${export_root}")" "$(basename "${export_root}")"
  fi
  echo "Export directory: ${export_root}"
  echo "${archive_fmt} archive: ${archive_path}"
  pause
}

pki_backup_menu() {
  print_header
  echo "=== Backup PKI / Config / Database / Keys / CRL / Logs ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" backup_dir ts out pass tmp manifest
  backup_dir="/root/matrix-pki-backups"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="${backup_dir}/matrix-full-${ts}.tar.gz"
  tmp="$(mktemp -d)"
  manifest="${tmp}/MANIFEST.txt"
  mkdir -p "${backup_dir}"
  {
    echo "Matrix backup ${ts}"
    echo "Includes: PKI, config, database, keys, CRL, logs"
  } > "${manifest}"
  tar -czf "${out}" \
    "${ca_dir}" \
    "${CONFIG_FILE}" \
    /etc/matrix-synapse \
    /etc/nginx/sites-available \
    /etc/nginx/sites-enabled \
    /etc/turnserver.conf \
    /etc/default/coturn \
    /var/lib/matrix-synapse \
    /var/log/matrix-installer.log \
    "${manifest}" 2>/dev/null || tar -czf "${out}" "${ca_dir}" "${CONFIG_FILE}" "${manifest}"
  rm -rf "${tmp}"
  read -rp "Encrypt backup with OpenSSL AES-256? (y/n): " enc
  if [[ "${enc}" == "y" || "${enc}" == "Y" ]]; then
    read -rsp "Backup encryption password: " pass; echo
    openssl enc -aes-256-cbc -salt -pbkdf2 -in "${out}" -out "${out}.enc" -pass "pass:${pass}"
    chmod 600 "${out}.enc"
    rm -f "${out}"
    out="${out}.enc"
  fi
  echo "Backup created: ${out}"
  pause
}

pki_restore_menu() {
  print_header
  echo "=== Restore PKI Backup ==="
  local backup_dir="/root/matrix-pki-backups" file restore_file tmp pass
  ls -1 "${backup_dir}"/*.tar.gz "${backup_dir}"/*.tar.gz.enc 2>/dev/null || { echo "No PKI backups found."; pause; return 1; }
  read -rp "Enter full path to PKI backup: " file
  [[ -f "${file}" ]] || { echo "Backup not found."; pause; return 1; }
  read -rp "Restore this backup, validate configs, reload services, and verify health? (y/n): " yn
  [[ "${yn}" == "y" || "${yn}" == "Y" ]] || { pause; return 0; }
  tmp="$(mktemp -d)"
  restore_file="${file}"
  if [[ "${file}" == *.enc ]]; then
    read -rsp "Backup encryption password: " pass; echo
    restore_file="${tmp}/restore.tar.gz"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "${file}" -out "${restore_file}" -pass "pass:${pass}"
  fi
  rollback_begin "restore"
  rollback_capture_standard_paths
  tar -xzf "${restore_file}" -C /
  validate_configs
  restart_services
  pki_verify_certificate "${CA_DIR:-${CA_DIR_DEFAULT}}" || true
  pki_health_checks || true
  rollback_commit
  rm -rf "${tmp}"
  echo "PKI restore complete and validated."
  pause
}

pki_status_menu() {
  print_header
  echo "=== Status Dashboard ==="
  load_config || true
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" root_cert int_cert server_cert root_key
  root_cert="$(get_root_cert_path "${ca_dir}")"
  int_cert="$(get_intermediate_cert_path "${ca_dir}")"
  server_cert="$(get_server_leaf_cert_path "${ca_dir}")"
  root_key="$(pki_root_dir "${ca_dir}")/private/rootCA.key.pem"
  echo "Version: ${VERSION}"
  echo "Root CA: $([[ -f "${root_cert}" ]] && echo present || echo missing)"
  echo "Root Private Key: $([[ -f "${root_key}" ]] && echo online || echo offline)"
  echo "Intermediate CA: $([[ -f "${int_cert}" ]] && echo present || echo missing)"
  echo "Server Certificate: $([[ -f "${server_cert}" ]] && echo present || echo missing)"
  for label_cert in "Root CA:${root_cert}" "Intermediate:${int_cert}" "Server:${server_cert}"; do
    local label="${label_cert%%:*}" cert="${label_cert#*:}" days
    days="$(pki_cert_days_left "${cert}")"
    if [[ "${days}" -ge 0 ]]; then echo "${label} Expiration: ${days} days"; else echo "${label} Expiration: not found"; fi
  done
  echo
  echo "Services:"
  systemctl is-active --quiet matrix-synapse && echo "Synapse: active" || echo "Synapse: NOT active"
  systemctl is-active --quiet nginx && echo "Nginx: active" || echo "Nginx: NOT active"
  systemctl is-active --quiet coturn && echo "Coturn: active" || echo "Coturn: NOT active"
  echo
  echo "Disk:"
  df -h / | awk 'NR==1 || NR==2'
  echo
  echo "Memory:"
  free -h
  pause
}

validate_configs() {
  local failed=0
  echo "nginx -t:"
  nginx -t || failed=1
  echo "turnserver configuration:"
  if command -v turnserver >/dev/null 2>&1; then
    turnserver -c /etc/turnserver.conf --check-config 2>/dev/null || grep -Eq '^(listening-port|tls-listening-port|realm|cert|pkey|static-auth-secret)=' /etc/turnserver.conf || failed=1
  else
    grep -Eq '^(listening-port|tls-listening-port|realm|cert|pkey|static-auth-secret)=' /etc/turnserver.conf || failed=1
  fi
  echo "Synapse config validation:"
  if command -v python3 >/dev/null 2>&1 && [[ -d /etc/matrix-synapse ]]; then
    python3 - <<'PY' || failed=1
import os, sys
base='/etc/matrix-synapse'
try:
    import yaml
except Exception:
    sys.exit(0)
for root, _, files in os.walk(base):
    for name in files:
        if name.endswith(('.yaml','.yml')):
            with open(os.path.join(root, name), encoding='utf-8') as fh:
                yaml.safe_load(fh)
PY
  fi
  return "${failed}"
}

post_install_validation() {
  local failed=0
  echo "=== Post Install Validation ==="
  pki_verify_certificate "${CA_DIR:-${CA_DIR_DEFAULT}}" || failed=1
  validate_configs || failed=1
  systemctl is-active --quiet matrix-synapse && echo "Synapse service OK" || { echo "Synapse service FAILED"; failed=1; }
  systemctl is-active --quiet nginx && echo "Nginx service OK" || { echo "Nginx service FAILED"; failed=1; }
  systemctl is-active --quiet coturn && echo "Coturn service OK" || { echo "Coturn service FAILED"; failed=1; }
  [[ -n "${HS_DOMAIN:-}" ]] && curl -kfsS "https://${HS_DOMAIN}/_matrix/client/versions" >/dev/null && echo "HTTPS/Synapse OK" || failed=1
  [[ -n "${ELEMENT_DOMAIN:-}" ]] && curl -kfsSI "https://${ELEMENT_DOMAIN}" >/dev/null && echo "Element HTTPS OK" || failed=1
  if ss -lntup | grep -Eq ':(3478|5349)\b'; then echo "TURN ports listening"; else echo "TURN ports not listening"; failed=1; fi
  if [[ "${failed}" -eq 0 ]]; then
    echo "FINAL RESULT: OK"
  else
    echo "FINAL RESULT: FAILED"
  fi
  return "${failed}"
}

pki_health_checks() {
  local ca_dir="${CA_DIR:-${CA_DIR_DEFAULT}}" server_cert root_cert int_cert failed=0
  server_cert="$(get_server_leaf_cert_path "${ca_dir}")"
  root_cert="$(get_root_cert_path "${ca_dir}")"
  int_cert="$(get_intermediate_cert_path "${ca_dir}")"
  echo "Certificate Chain / SAN / Expire / Key Match / Trust:"
  pki_verify_certificate "${ca_dir}" "${server_cert}" "$(get_server_key_path "${ca_dir}")" || failed=1
  echo
  validate_configs || failed=1
  echo
  echo "Open ports 443, 8448, 3478, 5349:"
  for port in 443 8448 3478 5349; do
    if ss -lntup | grep -Eq ":${port}\b"; then echo "Port ${port}: open/listening"; else echo "Port ${port}: NOT listening"; failed=1; fi
  done
  echo
  echo "Internal DNS:"
  for host in "${HS_DOMAIN:-}" "${ELEMENT_DOMAIN:-}" "${BASE_DOMAIN:-}"; do
    [[ -z "${host}" ]] && continue
    getent hosts "${host}" >/dev/null && echo "${host}: resolves" || { echo "${host}: DNS FAILED"; failed=1; }
  done
  echo
  echo "Disk:"
  df -h /
  echo
  echo "Memory:"
  free -h
  return "${failed}"
}
#############################################
# Install / Reinstall
#############################################

install_stack() {
  print_header
  echo "=== Matrix + Element + TURN Installer (Local Custom CA Mode) ==="
  echo

  read -rp "Enter Matrix homeserver local domain (e.g. chat.lan): " HS_DOMAIN
  read -rp "Enter Element Web local domain (e.g. element.lan): " ELEMENT_DOMAIN
  read -rp "Enter base local domain for .well-known (e.g. lan): " BASE_DOMAIN
  read -rp "Enter server LAN IP / MikroTik DNS target (e.g. 192.168.88.10): " PUBLIC_IP
  read -rp "Enter local CA storage path [${CA_DIR_DEFAULT}]: " CA_DIR
  CA_DIR="${CA_DIR:-${CA_DIR_DEFAULT}}"
  read -rp "Enter Root CA validity in years [20]: " CA_VALID_YEARS
  CA_VALID_YEARS="${CA_VALID_YEARS:-20}"
  read -rp "Enter Server certificate validity in days [730]: " SERVER_CERT_DAYS
  SERVER_CERT_DAYS="${SERVER_CERT_DAYS:-730}"
  read -rp "Extra DNS/IP SANs, comma-separated (optional): " EXTRA_SANS

  if [[ -z "${HS_DOMAIN}" || -z "${ELEMENT_DOMAIN}" || -z "${BASE_DOMAIN}" || -z "${PUBLIC_IP}" || -z "${CA_DIR}" ]]; then
    echo "Required fields are missing. Aborting install."
    pause
    return 0
  fi
  if ! validate_domain "${HS_DOMAIN}" || ! validate_domain "${ELEMENT_DOMAIN}" || ! validate_domain "${BASE_DOMAIN}" || ! validate_ip_or_host "${PUBLIC_IP}"; then
    echo "One or more domain/IP values are invalid. Aborting install."
    pause
    return 0
  fi
  if ! validate_positive_int "${SERVER_CERT_DAYS}" 3650; then
    echo "Server certificate days must be a number between 1 and 3650."
    pause
    return 0
  fi

  if ! validate_ca_years "${CA_VALID_YEARS}"; then
    echo "Root CA validity must be a number between 1 and 20 years."
    pause
    return 0
  fi

  echo
  echo "===== INSTALL CONFIGURATION SUMMARY ====="
  echo "Matrix Homeserver:    ${HS_DOMAIN}"
  echo "Element Web:          ${ELEMENT_DOMAIN}"
  echo "Base Domain:          ${BASE_DOMAIN}"
  echo "Server LAN IP:        ${PUBLIC_IP}"
  echo "Custom CA path:       ${CA_DIR}"
  echo "Root CA validity:     ${CA_VALID_YEARS} years"
  echo "Intermediate validity: 10 years"
  echo "Server cert validity: ${SERVER_CERT_DAYS} days"
  echo "Extra SANs:           ${EXTRA_SANS:-none}"
  echo "========================================="
  echo
  read -rp "Continue with installation? (y/n): " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Install aborted."
    pause
    return 0
  fi

  rollback_begin "install/update"
  rollback_capture_standard_paths

  save_config "${HS_DOMAIN}" "${ELEMENT_DOMAIN}" "${BASE_DOMAIN}" "${PUBLIC_IP}" "${CA_DIR}" "${CA_VALID_YEARS}" "${EXTRA_SANS}"
  {
    echo "SERVER_IP=${PUBLIC_IP}"
    echo "TURN_PORT=3478"
    echo "CA_YEARS=${CA_VALID_YEARS}"
    echo "SERVER_CERT_DAYS=${SERVER_CERT_DAYS}"
    echo "ENABLE_FEDERATION=false"
    echo "RENEW_THRESHOLD_DAYS=${RENEW_THRESHOLD_DAYS_DEFAULT}"
  } >> "${CONFIG_FILE}"

  export DEBIAN_FRONTEND=noninteractive

  echo
  echo "[1/12] Updating system & installing dependencies..."
  run_cmd "apt update" apt update
  run_cmd "install dependencies" apt install -y \
    ca-certificates curl wget gnupg lsb-release \
    nginx openssl \
    coturn debconf-utils sqlite3 jq zip

  echo "[2/12] Adding Matrix Synapse repository..."
  if [[ ! -f /usr/share/keyrings/matrix-org-archive-keyring.gpg ]]; then
    wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg \
      https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
  fi

  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/matrix-org.list

  run_cmd "apt update after Matrix repository" apt update

  echo "[3/12] Pre-configuring Synapse (debconf)..."
  echo "matrix-synapse matrix-synapse/server-name string ${HS_DOMAIN}" | debconf-set-selections
  echo "matrix-synapse matrix-synapse/report-stats boolean false"      | debconf-set-selections

  echo "[4/12] Installing Synapse..."
  run_cmd "install Matrix Synapse" apt install -y matrix-synapse-py3

  echo "[5/12] Creating local custom CA and server certificates..."
  create_custom_ca_and_server_cert \
    "${HS_DOMAIN}" \
    "${ELEMENT_DOMAIN}" \
    "${BASE_DOMAIN}" \
    "${PUBLIC_IP}" \
    "${CA_DIR}" \
    "${CA_VALID_YEARS}" \
    "${EXTRA_SANS}"

  SERVER_CERT_PATH="$(get_server_cert_path "${CA_DIR}")"
  SERVER_KEY_PATH="$(get_server_key_path "${CA_DIR}")"

echo "[5.5/12] Generating Synapse homeserver.yaml..."

mkdir -p /etc/matrix-synapse

if [[ ! -f /etc/matrix-synapse/homeserver.yaml ]]; then
    /opt/venvs/matrix-synapse/bin/python \
      -m synapse.app.homeserver \
      --generate-config \
      --report-stats=no \
      -H "${HS_DOMAIN}" \
      -c /etc/matrix-synapse/homeserver.yaml
fi


echo "[5.6/12] Fixing Synapse storage paths..."

mkdir -p /var/lib/matrix-synapse/media_store

sed -i \
  "s|/home/matrix/MatrixServer/homeserver.db|/var/lib/matrix-synapse/homeserver.db|g" \
  /etc/matrix-synapse/homeserver.yaml

sed -i \
  "s|/home/matrix/MatrixServer/media_store|/var/lib/matrix-synapse/media_store|g" \
  /etc/matrix-synapse/homeserver.yaml


echo "[5.7/12] Fixing Synapse log path..."

mkdir -p /var/log/matrix-synapse

sed -i \
  "s|/home/matrix/MatrixServer/homeserver.log|/var/log/matrix-synapse/homeserver.log|g" \
  /etc/matrix-synapse/chat.*.log.config


echo "[5.8/12] Adding local hostname mappings..."

grep -qE "[[:space:]]${HS_DOMAIN}([[:space:]]|$)" /etc/hosts || \
echo "${PUBLIC_IP} ${HS_DOMAIN}" >> /etc/hosts

grep -qE "[[:space:]]${ELEMENT_DOMAIN}([[:space:]]|$)" /etc/hosts || \
echo "${PUBLIC_IP} ${ELEMENT_DOMAIN}" >> /etc/hosts


echo "[5.9/12] Fixing Synapse ownership..."

chown -R matrix-synapse:matrix-synapse \
  /etc/matrix-synapse \
  /var/lib/matrix-synapse \
  /var/log/matrix-synapse
  
  echo "[6/12] Configuring Synapse registration..."
  mkdir -p /etc/matrix-synapse/conf.d
  REG_SECRET=$(openssl rand -hex 32)
  cat > /etc/matrix-synapse/conf.d/registration.yaml <<EOF
enable_registration: true
enable_registration_without_verification: true
registration_shared_secret: "${REG_SECRET}"
EOF

  echo "[6.1/12] Configuring Synapse media defaults (upload size)..."
  cat > /etc/matrix-synapse/conf.d/media.yaml <<EOF
max_upload_size: 50M
EOF

  echo "[7/12] Configuring TURN for Synapse..."
  TURN_SECRET=$(openssl rand -hex 32)
  cat > /etc/matrix-synapse/conf.d/turn.yaml <<EOF
turn_uris:
  - "turn:${HS_DOMAIN}:3478?transport=udp"
  - "turns:${HS_DOMAIN}:5349?transport=tcp"

turn_shared_secret: "${TURN_SECRET}"
turn_user_lifetime: 86400000
turn_allow_guests: true
EOF

  echo "[8/12] Configuring coturn..."
  if grep -q "^TURNSERVER_ENABLED" /etc/default/coturn 2>/dev/null; then
    sed -i 's/^TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  else
    echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn
  fi

  cat > /etc/turnserver.conf <<EOF
syslog
no-rfc5780
no-stun-backward-compatibility
response-origin-only-with-rfc5780

listening-port=3478
tls-listening-port=5349

listening-ip=${PUBLIC_IP}
relay-ip=${PUBLIC_IP}
external-ip=${PUBLIC_IP}

realm=${HS_DOMAIN}
server-name=${HS_DOMAIN}
fingerprint

cert=${SERVER_CERT_PATH}
pkey=${SERVER_KEY_PATH}

use-auth-secret
static-auth-secret=${TURN_SECRET}

min-port=49160
max-port=49200

total-quota=100
bps-capacity=0

no-loopback-peers
no-multicast-peers

verbose
EOF

  if command -v ufw >/dev/null 2>&1; then
    echo "Opening firewall ports (UFW)..."
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 3478/udp || true
    ufw allow 3478/tcp || true
    ufw allow 5349/tcp || true
    ufw allow 49160:49200/udp || true
  fi

  echo "[9/12] Restarting TURN and Synapse..."
  systemctl restart coturn
  systemctl restart matrix-synapse

  echo "[10/12] Installing Element Web..."
  mkdir -p /var/www
  cd /var/www

  ELEMENT_VERSION="1.12.7"
  wget -O element.tar.gz "https://github.com/element-hq/element-web/releases/download/v${ELEMENT_VERSION}/element-v${ELEMENT_VERSION}.tar.gz"
  rm -rf element || true
  tar -xvf element.tar.gz
  mv "element-v${ELEMENT_VERSION}" element
  rm element.tar.gz

  echo "[11/12] Creating Element config.json..."
  cat > /var/www/element/config.json <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${HS_DOMAIN}",
      "server_name": "${HS_DOMAIN}"
    }
  },
  "disable_custom_urls": false,
  "disable_guests": true,
  "brand": "Element"
}
EOF

  echo "[12/12] Creating Nginx virtual hosts..."

  cat > /etc/nginx/sites-available/matrix.conf <<EOF
server {
    listen 80;
    server_name ${HS_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${HS_DOMAIN};

    ssl_certificate ${SERVER_CERT_PATH};
    ssl_certificate_key ${SERVER_KEY_PATH};

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/matrix.conf

  cat > /etc/nginx/sites-available/element.conf <<EOF
server {
    listen 80;
    server_name ${ELEMENT_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${ELEMENT_DOMAIN};

    ssl_certificate ${SERVER_CERT_PATH};
    ssl_certificate_key ${SERVER_KEY_PATH};

    root /var/www/element;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/element.conf

  cat > /etc/nginx/sites-available/wellknown.conf <<EOF
server {
    listen 80;
    server_name ${BASE_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${BASE_DOMAIN};

    ssl_certificate ${SERVER_CERT_PATH};
    ssl_certificate_key ${SERVER_KEY_PATH};

    location = /.well-known/matrix/client {
        add_header Content-Type application/json;
        return 200 '{"m.homeserver":{"base_url":"https://${HS_DOMAIN}"}}';
    }

    location = /.well-known/matrix/server {
        add_header Content-Type application/json;
        return 200 '{"m.server":"${HS_DOMAIN}:443"}';
    }

    location / {
        return 404;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/wellknown.conf /etc/nginx/sites-enabled/wellknown.conf

  rm -f /etc/nginx/sites-enabled/default || true

  run_cmd "nginx config test" nginx -t
  run_cmd "reload nginx" systemctl reload nginx

  post_install_validation
  rollback_commit

  echo
  echo "========================================="
  echo "INSTALLATION COMPLETE"
  echo "-----------------------------------------"
  echo "Matrix Server: https://${HS_DOMAIN}"
  echo "Element Web:   https://${ELEMENT_DOMAIN}"
  echo "Well-known:    https://${BASE_DOMAIN}"
  echo "Local CA file: ${CA_DIR}/rootCA.pem"
  echo
  echo "Registration Secret: ${REG_SECRET}"
  echo "TURN Secret:        ${TURN_SECRET}"
  echo "Log file:           ${LOG_FILE}"
  echo "Arch:               $(detect_arch)"
  echo "========================================="
  echo

  pause
}

#############################################
# User Management
#############################################

create_admin_user() {
  print_header
  echo "👑 === Create ADMIN user ==="
  echo "Command:"
  echo "  register_new_matrix_user -c /etc/matrix-synapse/conf.d/registration.yaml -a http://localhost:8008"
  echo
  register_new_matrix_user \
    -c /etc/matrix-synapse/conf.d/registration.yaml \
    -a \
    http://localhost:8008
  pause
}

create_normal_user() {
  print_header
  echo "👤 === Create NORMAL user ==="
  echo "Command:"
  echo "  register_new_matrix_user -c /etc/matrix-synapse/conf.d/registration.yaml --no-admin http://localhost:8008"
  echo
  register_new_matrix_user \
    -c /etc/matrix-synapse/conf.d/registration.yaml \
    --no-admin \
    http://localhost:8008
  pause
}

create_user_random_password() {
  print_header
  echo "🎲 === Create user with RANDOM password ==="
  echo "This will generate a strong password and print it at the end."
  echo
  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. Run Install first."
    pause
    return 1
  fi

  read -rp "Enter username (localpart, e.g. vahid): " LOCALPART
  if [[ -z "${LOCALPART}" ]]; then
    echo "❌ Username is required."
    pause
    return 1
  fi

  echo "Choose role:"
  echo "1) Normal user"
  echo "2) Admin user"
  read -rp "Choose [1-2]: " ROLE

  local PASS
  PASS="$(openssl rand -base64 18 | tr -d '\n' | tr -d '=' | tr '/+' 'Aa')"

  # Use temp password file to avoid exposing password in process list
  local TMPPASS
  TMPPASS="$(mktemp)"
  printf "%s" "${PASS}" > "${TMPPASS}"

  if [[ "${ROLE}" == "2" ]]; then
    register_new_matrix_user \
      -u "${LOCALPART}" \
      --password-file "${TMPPASS}" \
      -a \
      -c /etc/matrix-synapse/conf.d/registration.yaml \
      http://localhost:8008
    echo
    echo "✅ Created ADMIN user:"
  else
    register_new_matrix_user \
      -u "${LOCALPART}" \
      --password-file "${TMPPASS}" \
      --no-admin \
      -c /etc/matrix-synapse/conf.d/registration.yaml \
      http://localhost:8008
    echo
    echo "✅ Created NORMAL user:"
  fi

  rm -f "${TMPPASS}" || true

  echo "MXID:     @${LOCALPART}:${HS_DOMAIN}"
  echo "Password: ${PASS}"
  echo
  echo "Tip: Save this password now."
  pause
}

reactivate_user() {
  print_header
  echo "♻️  === Reactivate existing user (set new password) ==="
  echo "Tip: If the user was deactivated, this will re-enable it."
  echo "Command uses --exists-ok."
  echo
  echo "Choose reactivation type:"
  echo "1) Reactivate as NORMAL user"
  echo "2) Reactivate as ADMIN user"
  echo "3) Back"
  read -rp "Choose [1-3]: " ROPT

  case "${ROPT}" in
    1)
      register_new_matrix_user \
        --exists-ok \
        -c /etc/matrix-synapse/conf.d/registration.yaml \
        --no-admin \
        http://localhost:8008
      ;;
    2)
      register_new_matrix_user \
        --exists-ok \
        -c /etc/matrix-synapse/conf.d/registration.yaml \
        -a \
        http://localhost:8008
      ;;
    3) ;;
    *) echo "Invalid option." ;;
  esac

  pause
}

#############################################
# User Listing / Deactivation
#############################################

list_users() {
  print_header
  echo "📋 === List users (SQLite) ==="
  ensure_sqlite_installed

  if [[ -f /var/lib/matrix-synapse/homeserver.db ]]; then
    echo "Format: MXID | admin(1/0) | deactivated(1/0)"
    echo "-------------------------------------------"
    sqlite3 /var/lib/matrix-synapse/homeserver.db \
      "SELECT name || ' | ' || admin || ' | ' || deactivated FROM users ORDER BY name;"
  else
    echo "❌ Database not found at /var/lib/matrix-synapse/homeserver.db"
    echo "If you use Postgres, you need psql-based listing."
    pause
    return 1
  fi

  pause
}

deactivate_user() {
  print_header
  echo "🚫 === Deactivate user (safe) ==="
  echo "This will:"
  echo " - Set deactivated=1"
  echo " - Clear password_hash"
  echo "It does NOT hard-delete messages/rooms (recommended)."
  echo
  read -rp "Enter full MXID (e.g. @user:example.com): " MXID

  if [[ -z "${MXID}" ]]; then
    echo "❌ MXID is required."
    pause
    return 1
  fi

  ensure_sqlite_installed
  if [[ ! -f /var/lib/matrix-synapse/homeserver.db ]]; then
    echo "❌ Database not found at /var/lib/matrix-synapse/homeserver.db"
    pause
    return 1
  fi

  read -rp "Are you sure you want to deactivate ${MXID}? (y/n): " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Cancelled."
    pause
    return 0
  fi

  sqlite3 /var/lib/matrix-synapse/homeserver.db \
    "UPDATE users SET deactivated=1, password_hash=NULL WHERE name='${MXID}';"

  echo "✅ User ${MXID} has been deactivated."
  echo "Tip: Use Reactivate to enable it again and set a new password."
  pause
}

#############################################
# Upload limits management
#############################################

set_upload_limits() {
  print_header
  echo "📦 === Upload Limits Manager ==="
  echo "This option will set BOTH:"
  echo " - Nginx client_max_body_size (Matrix vhost)"
  echo " - Synapse max_upload_size"
  echo
  echo "Enter size in MB (e.g. 500, 2000, 5000)."
  read -rp "Upload limit (MB): " LIMIT_MB

  if [[ -z "${LIMIT_MB}" || ! "${LIMIT_MB}" =~ ^[0-9]+$ ]]; then
    echo "❌ Please enter a numeric value (MB)."
    pause
    return 1
  fi

  local LIMIT_NGINX="${LIMIT_MB}M"
  local LIMIT_SYNAPSE="${LIMIT_MB}M"

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}."
    echo "Run Install first so domains are known."
    pause
    return 1
  fi

  echo "✅ Setting Nginx upload limit to: ${LIMIT_NGINX}"
  if [[ -f /etc/nginx/sites-available/matrix.conf ]]; then
    if grep -q "client_max_body_size" /etc/nginx/sites-available/matrix.conf; then
      sed -i "s/client_max_body_size.*/client_max_body_size ${LIMIT_NGINX};/g" /etc/nginx/sites-available/matrix.conf
    else
      sed -i "/ssl_certificate_key/a\\
\\
    client_max_body_size ${LIMIT_NGINX};\\
" /etc/nginx/sites-available/matrix.conf
    fi
  else
    echo "❌ /etc/nginx/sites-available/matrix.conf not found."
    pause
    return 1
  fi

  echo "✅ Setting Synapse upload limit to: ${LIMIT_SYNAPSE}"
  mkdir -p /etc/matrix-synapse/conf.d
  cat > /etc/matrix-synapse/conf.d/media.yaml <<EOF
max_upload_size: ${LIMIT_SYNAPSE}
EOF

  echo "🔄 Reloading services..."
  run_cmd "nginx config test" nginx -t
  run_cmd "reload nginx" systemctl reload nginx
  systemctl restart matrix-synapse

  echo "🎉 Done! Upload limits updated."
  echo "Nginx:   client_max_body_size ${LIMIT_NGINX}"
  echo "Synapse: max_upload_size ${LIMIT_SYNAPSE}"
  echo
  echo "Tip: Hard refresh Element Web (Ctrl+Shift+R) if you still see old limits."
  pause
}

#############################################
# Toggle registration ON/OFF
#############################################

toggle_registration() {
  print_header
  echo "🧾 === Toggle Registration (ON/OFF) ==="
  echo "If OFF: users cannot sign up in Element (web/mobile)."
  echo "You can still create users via this script."
  echo

  if [[ ! -f /etc/matrix-synapse/conf.d/registration.yaml ]]; then
    echo "❌ /etc/matrix-synapse/conf.d/registration.yaml not found."
    pause
    return 1
  fi

  local current="unknown"
  if grep -q "^enable_registration:" /etc/matrix-synapse/conf.d/registration.yaml; then
    current="$(grep "^enable_registration:" /etc/matrix-synapse/conf.d/registration.yaml | awk '{print $2}' | tr -d '\r')"
  fi

  echo "Current enable_registration: ${current}"
  echo
  echo "1) Turn ON registration"
  echo "2) Turn OFF registration"
  echo "3) Back"
  read -rp "Choose [1-3]: " opt

  case "${opt}" in
    1)
      if grep -q "^enable_registration:" /etc/matrix-synapse/conf.d/registration.yaml; then
        sed -i 's/^enable_registration:.*/enable_registration: true/' /etc/matrix-synapse/conf.d/registration.yaml
      else
        printf "\nenable_registration: true\n" >> /etc/matrix-synapse/conf.d/registration.yaml
      fi
      ;;
    2)
      if grep -q "^enable_registration:" /etc/matrix-synapse/conf.d/registration.yaml; then
        sed -i 's/^enable_registration:.*/enable_registration: false/' /etc/matrix-synapse/conf.d/registration.yaml
      else
        printf "\nenable_registration: false\n" >> /etc/matrix-synapse/conf.d/registration.yaml
      fi
      ;;
    3) ;;
    *) echo "Invalid option." ;;
  esac

  systemctl restart matrix-synapse || true
  echo "✅ Updated. Synapse restarted."
  pause
}

#############################################
# Call Diagnostics (TURN/WebRTC troubleshooting)
#############################################

call_diagnostics() {
  print_header
  echo "📞 === Call Diagnostics (TURN/WebRTC) ==="
  echo

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. Some checks will be limited."
  fi

  ensure_pkg coturn
  ensure_pkg curl
  ensure_pkg iproute2

  echo "🧠 Services:"
  systemctl is-active --quiet coturn && echo "✅ coturn: active" || echo "❌ coturn: NOT active"
  systemctl is-active --quiet matrix-synapse && echo "✅ matrix-synapse: active" || echo "❌ matrix-synapse: NOT active"
  echo

  echo "🧷 TURN ports listening (server-side):"
  ss -lunpt | grep -E ':(3478|5349)\b' || echo "❌ Not listening on 3478/5349 (check coturn config/service)."
  echo

  echo "🧾 TURN configuration summary:"
  if [[ -f /etc/turnserver.conf ]]; then
    echo "----- /etc/turnserver.conf (important lines) -----"
    grep -E '^(listening-port|tls-listening-port|listening-ip|relay-ip|external-ip|realm|server-name|min-port|max-port|use-auth-secret|static-auth-secret|cert=|pkey=)' /etc/turnserver.conf || true
    echo "--------------------------------------------------"
  else
    echo "❌ /etc/turnserver.conf not found."
  fi
  echo

  echo "🔥 Firewall quick check (UFW if available):"
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
    echo
    echo "Expected UFW rules (at minimum):"
    echo " - 3478/udp, 3478/tcp, 5349/tcp"
    echo " - 49160:49200/udp (TURN relay ports)"
  else
    echo "⚠️  UFW not installed. If you use cloud firewall, check it there."
    echo "Required ports:"
    echo " - UDP 3478"
    echo " - TCP 3478"
    echo " - TCP 5349"
    echo " - UDP 49160-49200 (relay ports)"
  fi
  echo

  echo "🌐 Public reachability (informational):"
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    echo "Public IP set in config: ${PUBLIC_IP}"
  else
    echo "Public IP not loaded from config."
  fi
  echo

  echo "🧪 Synapse TURN config file:"
  if [[ -f /etc/matrix-synapse/conf.d/turn.yaml ]]; then
    cat /etc/matrix-synapse/conf.d/turn.yaml
  else
    echo "❌ /etc/matrix-synapse/conf.d/turn.yaml not found."
  fi
  echo

  echo "🧪 Matrix client endpoint (if domain known):"
  if [[ -n "${HS_DOMAIN:-}" ]]; then
    if curl -fsS "https://${HS_DOMAIN}/_matrix/client/versions" >/dev/null 2>&1; then
      echo "✅ https://${HS_DOMAIN}/_matrix/client/versions OK"
    else
      echo "❌ Cannot reach https://${HS_DOMAIN}/_matrix/client/versions"
      echo "   This can also break call setup in clients."
    fi
  else
    echo "⚠️  HS_DOMAIN not known (run Install first)."
  fi
  echo

  echo "📜 Recent coturn logs (last 80 lines):"
  journalctl -u coturn -n 80 --no-pager || true
  echo

  echo "📌 If calls stay on 'Connecting', the most common cause is:"
  echo " - UDP relay ports are blocked (49160-49200/udp) in server firewall OR cloud firewall."
  echo " - Or external-ip is wrong (NAT scenario)."
  echo
  echo "Tip: Try a test call, then immediately run this diagnostics and check for:"
  echo " - 'allocation timeout' in coturn logs."
  echo

  pause
}

#############################################
# Health Check
#############################################

health_check() {
  print_header
  echo "=== Enterprise Health Check ==="
  echo

  if ! load_config; then
    echo "Config not found at ${CONFIG_FILE}. Some URL checks will be skipped."
  fi

  echo "Service Status:"
  systemctl is-active --quiet matrix-synapse && echo "Synapse: active" || echo "Synapse: NOT active"
  systemctl is-active --quiet nginx && echo "Nginx: active" || echo "Nginx: NOT active"
  systemctl is-active --quiet coturn && echo "Coturn: active" || echo "Coturn: NOT active"
  echo

  echo "Nginx config test:"
  if nginx -t >/dev/null 2>&1; then
    echo "nginx -t OK"
  else
    echo "nginx -t FAILED"
    nginx -t || true
  fi
  echo

  if [[ -n "${HS_DOMAIN:-}" ]]; then
    echo "Synapse client API:"
    curl -fsS "https://${HS_DOMAIN}/_matrix/client/versions" >/dev/null 2>&1 && echo "Synapse HTTPS OK" || echo "Synapse HTTPS check failed"
    echo
  fi

  if [[ -n "${ELEMENT_DOMAIN:-}" ]]; then
    echo "Element Web:"
    curl -fsSI "https://${ELEMENT_DOMAIN}" >/dev/null 2>&1 && echo "Element HTTPS OK" || echo "Element HTTPS check failed"
    echo
  fi

  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    echo ".well-known:"
    curl -fsS "https://${BASE_DOMAIN}/.well-known/matrix/client" >/dev/null 2>&1 && echo ".well-known OK" || echo ".well-known check failed"
    echo
  fi

  echo "Listening ports:"
  ss -lntup | grep -E '(:80|:443|:8008|:3478|:5349)\b' || echo "No expected ports found (or ss output restricted)."
  echo

  echo "PKI / Certificate Health:"
  pki_health_checks || true

  pause
}
#############################################
# Fix Wizard (common issues)
#############################################

fix_wizard() {
  print_header
  echo "🧰 === Fix Wizard (common issues) ==="
  echo "This tries to fix:"
  echo " - Missing Nginx symlinks"
  echo " - Default site enabled"
  echo " - coturn disabled"
  echo " - Reload/restart services"
  echo

  if grep -q "^TURNSERVER_ENABLED" /etc/default/coturn 2>/dev/null; then
    sed -i 's/^TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  else
    echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn
  fi

  [[ -f /etc/nginx/sites-available/matrix.conf ]] && ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/matrix.conf || true
  [[ -f /etc/nginx/sites-available/element.conf ]] && ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/element.conf || true
  [[ -f /etc/nginx/sites-available/wellknown.conf ]] && ln -sf /etc/nginx/sites-available/wellknown.conf /etc/nginx/sites-enabled/wellknown.conf || true

  rm -f /etc/nginx/sites-enabled/default || true

  echo "✅ Running nginx -t ..."
  nginx -t || true

  echo "🔄 Restarting services..."
  systemctl restart coturn || true
  systemctl restart matrix-synapse || true
  systemctl reload nginx || true

  echo "✅ Fix Wizard done."
  pause
}

#############################################
# Backup / Restore
#############################################

backup_server() {
  print_header
  echo "💾 === Backup Server ==="
  echo

  local backup_dir="/root/matrix-backups"
  mkdir -p "${backup_dir}"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local out="${backup_dir}/matrix-backup-${ts}.tar.gz"

  echo "Include local custom CA directory in backup?"
  echo "1) Yes"
  echo "2) No"
  read -rp "Choose [1-2]: " inc

  local paths=(
    "/etc/matrix-synapse"
    "/etc/nginx/sites-available"
    "/etc/nginx/sites-enabled"
    "/etc/turnserver.conf"
    "/var/lib/matrix-synapse"
    "${CONFIG_FILE}"
  )

  if [[ "${inc}" == "1" ]]; then
    paths+=("${CA_DIR:-${CA_DIR_DEFAULT}}")
  fi

  echo "Creating backup: ${out}"
  tar -czf "${out}" "${paths[@]}" 2>/dev/null || tar -czf "${out}" "${paths[@]}"

  echo "✅ Backup created:"
  echo "${out}"
  pause
}

restore_backup() {
  print_header
  echo "♻️  === Restore Backup ==="
  echo

  local backup_dir="/root/matrix-backups"
  if [[ ! -d "${backup_dir}" ]]; then
    echo "❌ Backup directory not found: ${backup_dir}"
    pause
    return 1
  fi

  echo "Available backups:"
  ls -1 "${backup_dir}"/*.tar.gz 2>/dev/null || { echo "❌ No backups found."; pause; return 1; }
  echo
  read -rp "Enter full path to backup file: " file

  if [[ -z "${file}" || ! -f "${file}" ]]; then
    echo "❌ Backup file not found."
    pause
    return 1
  fi

  echo "⚠️  This will overwrite current config/files."
  read -rp "Are you sure you want to restore? (y/n): " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Cancelled."
    pause
    return 0
  fi

  echo "Stopping services..."
  systemctl stop matrix-synapse || true
  systemctl stop coturn || true
  systemctl stop nginx || true

  echo "Extracting backup..."
  tar -xzf "${file}" -C /

  echo "Testing nginx config..."
  nginx -t || true

  echo "Starting services..."
  systemctl start nginx || true
  systemctl restart coturn || true
  systemctl restart matrix-synapse || true

  echo "✅ Restore complete."
  pause
}

#############################################
# Update Element Web
#############################################

update_element_web() {
  print_header
  echo "⬆️  === Update Element Web ==="
  echo

  if ! load_config; then
    echo "⚠️  Config not found at ${CONFIG_FILE}. You can still update Element files."
  fi

  ensure_pkg jq
  ensure_pkg curl
  ensure_pkg wget

  echo "Choose Element version:"
  echo "1) Enter version manually (recommended)"
  echo "2) Use latest (GitHub API)"
  echo "3) Back"
  read -rp "Choose [1-3]: " opt

  local ver=""
  case "${opt}" in
    1)
      read -rp "Enter version (example: 1.12.7): " ver
      ;;
    2)
      echo "Fetching latest version..."
      local tag
      tag="$(curl -fsS https://api.github.com/repos/element-hq/element-web/releases/latest | jq -r '.tag_name')"
      if [[ -z "${tag}" || "${tag}" == "null" ]]; then
        echo "❌ Could not fetch latest version."
        pause
        return 1
      fi
      ver="${tag#v}"
      echo "Latest: ${ver}"
      ;;
    3) return 0 ;;
    *) echo "Invalid option."; pause; return 1 ;;
  esac

  if [[ -z "${ver}" ]]; then
    echo "❌ Version is required."
    pause
    return 1
  fi

  local url="https://github.com/element-hq/element-web/releases/download/v${ver}/element-v${ver}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  echo "Downloading: ${url}"
  if ! wget -O "${tmp}/element.tar.gz" "${url}"; then
    echo "❌ Download failed. Check version exists or try manual version."
    rm -rf "${tmp}" || true
    pause
    return 1
  fi

  echo "Extracting..."
  tar -xvf "${tmp}/element.tar.gz" -C "${tmp}" >/dev/null

  local extracted="${tmp}/element-v${ver}"
  if [[ ! -d "${extracted}" ]]; then
    echo "❌ Unexpected archive content. Folder not found: ${extracted}"
    rm -rf "${tmp}" || true
    pause
    return 1
  fi

  echo "Preserving existing config.json (if any)..."
  if [[ -f /var/www/element/config.json ]]; then
    cp /var/www/element/config.json "${tmp}/config.json.backup"
  fi

  echo "Replacing /var/www/element..."
  rm -rf /var/www/element
  mv "${extracted}" /var/www/element

  if [[ -f "${tmp}/config.json.backup" ]]; then
    mv "${tmp}/config.json.backup" /var/www/element/config.json
  fi

  rm -rf "${tmp}" || true

  systemctl reload nginx || true
  echo "✅ Element updated to v${ver}."
  pause
}

#############################################
# Full Uninstall / Purge
#############################################

full_uninstall() {
  print_header
  echo "🧨 === FULL UNINSTALL / PURGE ==="
  echo "This will REMOVE:"
  echo " - Synapse"
  echo " - Nginx"
  echo " - coturn"
  echo " - Element files"
  echo " - Matrix configs and database"
  echo
  echo "⚠️  This is destructive."
  read -rp "Type DELETE to continue: " confirm
  if [[ "${confirm}" != "DELETE" ]]; then
    echo "Cancelled."
    pause
    return 0
  fi

  echo "Stopping services..."
  systemctl stop matrix-synapse || true
  systemctl stop coturn || true
  systemctl stop nginx || true

  echo "Removing packages..."
  apt purge -y matrix-synapse-py3 coturn nginx || true
  apt autoremove -y || true

  echo "Removing temporary files..."

   rm -rf /etc/matrix-synapse /var/lib/matrix-synapse || true

  rm -f /etc/turnserver.conf /etc/default/coturn || true
  rm -rf /var/www/element || true

  rm -f /etc/nginx/sites-available/matrix.conf \
      /etc/nginx/sites-available/element.conf \
      /etc/nginx/sites-available/wellknown.conf || true

  rm -f /etc/nginx/sites-enabled/matrix.conf \
      /etc/nginx/sites-enabled/element.conf \
      /etc/nginx/sites-enabled/wellknown.conf || true

  rm -f "${CONFIG_FILE}" || true

  load_config || true
  echo "Optional: remove local custom CA directory?"
  echo "1) Yes (delete ${CA_DIR:-${CA_DIR_DEFAULT}})"
  echo "2) No"
  read -rp "Choose [1-2]: " opt
  if [[ "${opt}" == "1" ]]; then
    rm -rf "${CA_DIR:-${CA_DIR_DEFAULT}}" || true
  fi

  echo "✅ Uninstall complete."
  pause
}

#############################################
# PKI Management Menu
#############################################

pki_management_menu() {
  while true; do
    print_header
    echo "====== PKI Management ======"
    echo "1)  Generate Root"
    echo "2)  Generate Intermediate"
    echo "3)  Issue Server Certificate"
    echo "3a) Export Root Certificate"
    echo "3b) Remove Root Private Key From Server"
    echo "3c) Temporarily Import Root Private Key"
    echo "3d) Rotate Intermediate + Reissue Server Certificate"
    echo "4)  Renew Certificate"
    echo "5)  Reissue Certificate"
    echo "6)  Revoke Certificate"
    echo "7)  Export Certificates"
    echo "8)  Verify Certificate"
    echo "9)  Certificate Viewer"
    echo "10) Backup PKI"
    echo "11) Restore PKI"
    echo "12) PKI Status"
    echo "13) Back"
    echo "============================"
    read -rp "Choose an option [1-13]: " PKI_CHOICE
    case "${PKI_CHOICE}" in
      1)  pki_generate_root_menu || true ;;
      2)  pki_generate_intermediate_menu || true ;;
      3)  pki_issue_menu || true ;;
      3a) pki_export_root_certificate_menu || true ;;
      3b) pki_remove_root_private_key_menu || true ;;
      3c) pki_import_root_private_key_menu || true ;;
      3d) pki_rotate_intermediate_menu || true ;;
      4)  pki_renew_menu || true ;;
      5)  pki_reissue_menu || true ;;
      6)  pki_revoke_menu || true ;;
      7)  pki_export_menu || true ;;
      8)  pki_verify_menu || true ;;
      9)  pki_certificate_viewer_menu || true ;;
      10) pki_backup_menu || true ;;
      11) pki_restore_menu || true ;;
      12) pki_status_menu || true ;;
      13) return 0 ;;
      *)  echo "Invalid option."; sleep 1 ;;
    esac
  done
}
#############################################
# Main menu
#############################################

main_menu() {
  while true; do
    print_header
    echo "====== Matrix Stack Manager ======"
    echo "1)  🧩 Install / Reinstall Matrix + Element + TURN"
    echo "2)  👑 Create admin user (interactive)"
    echo "3)  👤 Create normal user (interactive)"
    echo "4)  🎲 Create user with RANDOM password (auto)"
    echo "5)  ♻️ Reactivate user (exists-ok)"
    echo "6)  📋 List users"
    echo "7)  🚫 Deactivate user (safe)"
    echo "8)  📦 Set upload limits (Nginx + Synapse)"
    echo "9)  🧾 Toggle registration ON/OFF"
    echo "10) 🔎 Health Check"
    echo "11) 🧰 Fix Wizard (auto-fix common issues)"
    echo "12) 💾 Backup server"
    echo "13) ♻️ Restore backup"
    echo "14) 📞 Call Diagnostics (TURN/WebRTC)"
    echo "15) ⬆️  Update Element Web"
    echo "16) Full uninstall / purge"
    echo "17) PKI Management"
    echo "18) Exit"
    echo "=================================="
    read -rp "Choose an option [1-18]: " CHOICE

    case "${CHOICE}" in
      1)  install_stack ;;
      2)  create_admin_user || true ;;
      3)  create_normal_user || true ;;
      4)  create_user_random_password || true ;;
      5)  reactivate_user || true ;;
      6)  list_users || true ;;
      7)  deactivate_user || true ;;
      8)  set_upload_limits || true ;;
      9)  toggle_registration || true ;;
      10) health_check || true ;;
      11) fix_wizard || true ;;
      12) backup_server || true ;;
      13) restore_backup || true ;;
      14) call_diagnostics || true ;;
      15) update_element_web || true ;;
      16) full_uninstall || true ;;
      17) pki_management_menu || true ;;
      18) echo "Bye."; exit 0 ;;
      *)  echo "Invalid option."; sleep 1 ;;
    esac
  done
}

require_root
acquire_lock
main_menu



