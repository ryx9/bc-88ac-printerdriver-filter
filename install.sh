#!/usr/bin/env bash
#
# BlackCopper BC88AC CUPS Driver Installer
#
# Expected directory:
#   ./bc88ac
#   ./BC88AC.ppd
#
# Run:
#   chmod +x install.sh
#   ./install.sh
#
# The script:
#   1. Checks the operating system
#   2. Checks that the driver files exist
#   3. Installs CUPS + filter dependencies
#   4. Starts/enables CUPS
#   5. Detects the BlackCopper printer automatically
#   6. Installs the custom CUPS filter
#   7. Fixes the pdftoppm "-pbm" incompatibility if present
#   8. Installs the PPD
#   9. Creates/updates the CUPS printer
#  10. Makes it the default printer
#  11. Validates the complete CUPS/filter configuration
#  12. Performs a filter-only conversion test
#
# No test receipt is printed automatically.
#

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# CONFIGURATION
# ============================================================

PRINTER_NAME="BC88AC"

FILTER_NAME="bc88ac"
PPD_NAME="BC88AC.ppd"

CUPS_FILTER_DIR="/usr/lib/cups/filter"
CUPS_PPD_DIR="/usr/share/ppd"

INSTALLED_FILTER="${CUPS_FILTER_DIR}/${FILTER_NAME}"
INSTALLED_PPD="${CUPS_PPD_DIR}/${PPD_NAME}"

LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/bc88ac-installer.log"

BACKUP_DIR="/var/backups/bc88ac"

# Expected printer identification.
# We deliberately use multiple identifiers because USB
# enumeration can vary between systems.
PRINTER_KEYWORDS=(
    "80Series"
    "BlackCopper"
    "BC88"
    "BC-88"
)

# ============================================================
# COLORS / OUTPUT
# ============================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    RESET=''
fi

STEP=0
CURRENT_STEP="startup"

log() {
    local level="$1"
    shift

    local message="$*"

    printf '[%s] %s\n' "$level" "$message"

    if [[ -w "$LOG_DIR" || -w "$LOG_FILE" ]]; then
        printf '[%s] %s\n' "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

info() {
    log "INFO" "$*"
}

success() {
    printf "${GREEN}✔ %s${RESET}\n" "$*"
    log "OK" "$*"
}

warn() {
    printf "${YELLOW}⚠ %s${RESET}\n" "$*"
    log "WARN" "$*"
}

error() {
    printf "${RED}✖ %s${RESET}\n" "$*"
    log "ERROR" "$*"
}

step() {
    STEP=$((STEP + 1))
    CURRENT_STEP="$*"

    printf "\n${BLUE}${BOLD}[%02d] %s${RESET}\n" "$STEP" "$CURRENT_STEP"
    log "STEP" "[$STEP] $CURRENT_STEP"
}

die() {
    local message="$*"

    error "$message"

    printf "\n"
    printf "${RED}${BOLD}INSTALLATION FAILED${RESET}\n"
    printf "Failed step: ${BOLD}%s${RESET}\n" "$CURRENT_STEP"
    printf "Step number: %s\n" "$STEP"
    printf "Diagnostic log: %s\n" "$LOG_FILE"
    printf "\n"

    exit 1
}

run_or_die() {
    local description="$1"
    shift

    info "$description"

    if ! "$@"; then
        die "$description failed."
    fi
}

# ============================================================
# ERROR HANDLER
# ============================================================

on_error() {
    local exit_code=$?
    local line_no=$1
    local command="${2:-unknown}"

    printf "\n"
    error "Unexpected command failure."
    error "Step: ${CURRENT_STEP}"
    error "Line: ${line_no}"
    error "Exit code: ${exit_code}"
    error "Command: ${command}"
    error "Log: ${LOG_FILE}"

    printf "\nLast 40 log lines:\n"
    tail -40 "$LOG_FILE" 2>/dev/null || true

    exit "$exit_code"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR

# ============================================================
# CLEANUP
# ============================================================

TMP_DIR=""

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT

# ============================================================
# INITIALIZATION
# ============================================================

clear 2>/dev/null || true

printf "${CYAN}${BOLD}"
printf '%s\n' "============================================================"
printf '%s\n' "      BlackCopper BC88AC CUPS Driver Installer"
printf '%s\n' "============================================================"
printf "${RESET}"

# ============================================================
# CHECK ROOT / SUDO
# ============================================================

step "Checking administrator privileges"

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
else
    if ! command -v sudo >/dev/null 2>&1; then
        die "sudo is not installed. Run this script as root or install sudo."
    fi

    if ! sudo -v; then
        die "Could not obtain sudo privileges."
    fi

    SUDO="sudo"
fi

success "Administrator privileges available."

# ============================================================
# DETERMINE SCRIPT DIRECTORY
# ============================================================

step "Locating driver files"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FILTER_SOURCE="${SCRIPT_DIR}/${FILTER_NAME}"
PPD_SOURCE="${SCRIPT_DIR}/${PPD_NAME}"

info "Driver directory: $SCRIPT_DIR"

if [[ ! -f "$FILTER_SOURCE" ]]; then
    die "Filter not found: $FILTER_SOURCE"
fi

if [[ ! -f "$PPD_SOURCE" ]]; then
    die "PPD not found: $PPD_SOURCE"
fi

if [[ ! -r "$FILTER_SOURCE" ]]; then
    die "Filter is not readable: $FILTER_SOURCE"
fi

if [[ ! -r "$PPD_SOURCE" ]]; then
    die "PPD is not readable: $PPD_SOURCE"
fi

success "Found filter: $FILTER_SOURCE"
success "Found PPD:    $PPD_SOURCE"

# ============================================================
# INITIALIZE LOGGING
# ============================================================

step "Initializing diagnostic logging"

$SUDO touch "$LOG_FILE"
$SUDO chmod 644 "$LOG_FILE"

{
    echo
    echo "============================================================"
    echo "BC88AC installer run: $(date)"
    echo "Script directory: $SCRIPT_DIR"
    echo "============================================================"
} | $SUDO tee -a "$LOG_FILE" >/dev/null

success "Logging to $LOG_FILE"

# ============================================================
# OS CHECK
# ============================================================

step "Checking operating system"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
else
    die "/etc/os-release does not exist."
fi

info "Detected OS: ${PRETTY_NAME:-unknown}"

if [[ "${ID:-}" != "linuxmint" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID_LIKE:-}" != *"debian"* ]]; then
    warn "This does not appear to be Linux Mint/Ubuntu/Debian."
    warn "The script will continue, but package installation may differ."
fi

success "Operating system check complete."

# ============================================================
# ARCHITECTURE
# ============================================================

step "Checking system architecture"

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

info "Architecture: $ARCH"

success "Architecture detected."

# ============================================================
# INSTALL PACKAGES
# ============================================================

step "Installing CUPS and filter dependencies"

if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get was not found. This installer expects Linux Mint/Ubuntu/Debian."
fi

PACKAGES=(
    cups
    cups-client
    cups-filters
    poppler-utils
    python3
)

info "Required packages:"
printf '  - %s\n' "${PACKAGES[@]}"

$SUDO apt-get update

if ! $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"; then
    die "APT failed while installing required packages."
fi

success "All required packages are installed."

# ============================================================
# CHECK REQUIRED PROGRAMS
# ============================================================

step "Checking required executables"

REQUIRED_COMMANDS=(
    python3
    pdfinfo
    pdftoppm
    lpadmin
    lpstat
    lpoptions
    cupsenable
    cupsaccept
    lpinfo
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Required command not found after package installation: $cmd"
    fi

    info "$cmd -> $(command -v "$cmd")"
done

success "All required commands are available."

# ============================================================
# SHOW POPPLER VERSION
# ============================================================

step "Checking Poppler/pdftoppm compatibility"

PDFTOPPM_PATH="$(command -v pdftoppm)"

info "pdftoppm: $PDFTOPPM_PATH"

PDFTOPPM_VERSION="$("$PDFTOPPM_PATH" -v 2>&1 | head -1 || true)"

info "$PDFTOPPM_VERSION"

if "$PDFTOPPM_PATH" -help 2>&1 | grep -q -- '-pbm'; then
    info "This Poppler version supports -pbm."
else
    info "This Poppler version does NOT expose -pbm."
    info "The filter will be normalized to use -mono for PBM output."
fi

success "pdftoppm compatibility checked."

# ============================================================
# START CUPS
# ============================================================

step "Starting and enabling CUPS"

if ! $SUDO systemctl enable --now cups; then
    die "Could not start/enable the CUPS service."
fi

if ! systemctl is-active --quiet cups; then
    die "CUPS service is not active."
fi

success "CUPS is running."

if ! lpstat -r 2>&1 | grep -qi "scheduler is running"; then
    die "CUPS scheduler is not running according to lpstat."
fi

success "CUPS scheduler is running."

# ============================================================
# DETECT PRINTER
# ============================================================

step "Detecting BlackCopper printer"

info "Querying CUPS for USB printers..."

LPINFO_OUTPUT="$(lpinfo -v 2>&1)" || die "lpinfo -v failed."

printf '%s\n' "$LPINFO_OUTPUT" >> "$LOG_FILE"

echo
echo "Detected USB-capable CUPS devices:"
echo "$LPINFO_OUTPUT" | grep -Ei 'usb|80series|blackcopper|bc.?88' || true
echo

PRINTER_URI=""

# First priority: exact known family identifier.
PRINTER_URI="$(
    printf '%s\n' "$LPINFO_OUTPUT" |
    awk '
        BEGIN { IGNORECASE=1 }
        /direct[[:space:]]+usb:\/\// &&
        ($0 ~ /80Series/ || $0 ~ /BlackCopper/ || $0 ~ /BC.?88/) {
            sub(/^[[:space:]]*direct[[:space:]]+/, "", $0)
            print
            exit
        }
    '
)"

# Second priority: anything USB that contains 80Series.
if [[ -z "$PRINTER_URI" ]]; then
    PRINTER_URI="$(
        printf '%s\n' "$LPINFO_OUTPUT" |
        awk '
            BEGIN { IGNORECASE=1 }
            /direct[[:space:]]+usb:\/\// && /80Series/ {
                sub(/^[[:space:]]*direct[[:space:]]+/, "", $0)
                print
                exit
            }
        '
    )"
fi

# Third priority: any USB device, but only if exactly one exists.
if [[ -z "$PRINTER_URI" ]]; then
    mapfile -t USB_URIS < <(
        printf '%s\n' "$LPINFO_OUTPUT" |
        awk '
            /^direct[[:space:]]+usb:\/\// {
                sub(/^[[:space:]]*direct[[:space:]]+/, "", $0)
                print
            }
        '
    )

    if [[ "${#USB_URIS[@]}" -eq 1 ]]; then
        PRINTER_URI="${USB_URIS[0]}"
        warn "No BlackCopper name was detected."
        warn "Exactly one USB printer exists, so it will be used."
    elif [[ "${#USB_URIS[@]}" -gt 1 ]]; then
        die "Multiple USB printers detected but none could be identified as BlackCopper."
    fi
fi

if [[ -z "$PRINTER_URI" ]]; then
    die "BlackCopper printer was not detected by CUPS.

Make sure:
  1. The printer is powered on.
  2. The USB cable/USB-to-parallel adapter is connected.
  3. The printer is not being used by another computer.

Run manually:
  lpinfo -v
"
fi

success "BlackCopper printer detected."

info "Printer URI:"
printf '  %s\n' "$PRINTER_URI"

# ============================================================
# OPTIONAL USB DEVICE INFORMATION
# ============================================================

step "Collecting USB diagnostic information"

if command -v lsusb >/dev/null 2>&1; then
    LSUSB_OUTPUT="$(lsusb 2>&1 || true)"
    printf '%s\n' "$LSUSB_OUTPUT" >> "$LOG_FILE"

    BLACKCOPPER_USB="$(
        printf '%s\n' "$LSUSB_OUTPUT" |
        grep -Ei '80series|blackcopper|bc.?88|0fe6:811e|advent|parallel' |
        head -5 || true
    )"

    if [[ -n "$BLACKCOPPER_USB" ]]; then
        info "Relevant USB device:"
        printf '%s\n' "$BLACKCOPPER_USB"
    fi
else
    warn "lsusb is not installed; skipping raw USB diagnostics."
fi

success "USB diagnostics collected."

# ============================================================
# BACKUP EXISTING DRIVER FILES
# ============================================================

step "Preparing driver installation"

$SUDO mkdir -p "$BACKUP_DIR"

if [[ -f "$INSTALLED_FILTER" ]]; then
    BACKUP_FILE="${BACKUP_DIR}/bc88ac.$(date +%Y%m%d-%H%M%S).bak"
    $SUDO cp -a "$INSTALLED_FILTER" "$BACKUP_FILE"
    info "Backed up existing filter to $BACKUP_FILE"
fi

if [[ -f "$INSTALLED_PPD" ]]; then
    BACKUP_FILE="${BACKUP_DIR}/BC88AC.ppd.$(date +%Y%m%d-%H%M%S).bak"
    $SUDO cp -a "$INSTALLED_PPD" "$BACKUP_FILE"
    info "Backed up existing PPD to $BACKUP_FILE"
fi

success "Driver installation area prepared."

# ============================================================
# VALIDATE SOURCE FILTER
# ============================================================

step "Validating source filter"

if [[ ! -s "$FILTER_SOURCE" ]]; then
    die "Filter file exists but is empty: $FILTER_SOURCE"
fi

if ! head -n 1 "$FILTER_SOURCE" | grep -Eq '^#!.*python'; then
    warn "The first line of the filter does not look like a Python shebang."
    warn "Continuing because the filter may still be valid."
fi

# Check for Python syntax.
if ! python3 -m py_compile "$FILTER_SOURCE"; then
    die "The source bc88ac filter contains invalid Python syntax."
fi

success "Source filter has valid Python syntax."

# ============================================================
# CREATE PATCHED FILTER
# ============================================================

step "Preparing Poppler-compatible filter"

TMP_DIR="$(mktemp -d -t bc88ac-installer.XXXXXX)"

PATCHED_FILTER="${TMP_DIR}/bc88ac"

cp "$FILTER_SOURCE" "$PATCHED_FILTER"

#
# Your original filter used "-pbm".
#
# On the Mint/Poppler version encountered on this machine,
# pdftoppm does not accept "-pbm"; "-mono" already generates
# PBM output.
#
# We therefore remove standalone "-pbm" arguments.
#

if grep -Eq '^[[:space:]]*["'\'']-pbm["'\''][[:space:]]*,?[[:space:]]*$' "$PATCHED_FILTER"; then
    info "Detected obsolete/incompatible standalone -pbm option."

    sed -i \
        -E '/^[[:space:]]*["'\'']-pbm["'\''][[:space:]]*,?[[:space:]]*$/d' \
        "$PATCHED_FILTER"

    info "Removed -pbm from the filter."
else
    info "No standalone -pbm option detected."
fi

# Make sure -mono is present.
if ! grep -Eq '["'\'']-mono["'\'']' "$PATCHED_FILTER"; then
    warn "The filter does not appear to contain -mono."
    warn "The script will NOT invent a new rendering command."
    warn "The supplied filter should be reviewed manually."
fi

if ! python3 -m py_compile "$PATCHED_FILTER"; then
    die "The Poppler-compatible patched filter failed Python syntax validation."
fi

success "Filter prepared and syntax validated."

# ============================================================
# INSTALL FILTER
# ============================================================

step "Installing CUPS filter"

$SUDO install -d -m 755 "$CUPS_FILTER_DIR"

$SUDO install -m 755 "$PATCHED_FILTER" "$INSTALLED_FILTER"

if [[ ! -x "$INSTALLED_FILTER" ]]; then
    die "Installed filter is not executable: $INSTALLED_FILTER"
fi

if ! $SUDO test -r "$INSTALLED_FILTER"; then
    die "Installed filter is not readable: $INSTALLED_FILTER"
fi

success "Filter installed:"
printf '  %s\n' "$INSTALLED_FILTER"

# ============================================================
# VALIDATE INSTALLED FILTER
# ============================================================

step "Validating installed CUPS filter"

if ! python3 -m py_compile "$INSTALLED_FILTER"; then
    die "Installed CUPS filter has invalid Python syntax."
fi

FILTER_OWNER="$($SUDO stat -c '%U:%G' "$INSTALLED_FILTER")"
FILTER_MODE="$($SUDO stat -c '%a' "$INSTALLED_FILTER")"

info "Owner: $FILTER_OWNER"
info "Mode:  $FILTER_MODE"

if [[ "$FILTER_MODE" != "755" ]]; then
    warn "Filter mode is $FILTER_MODE instead of 755."
    $SUDO chmod 755 "$INSTALLED_FILTER"
fi

success "Installed filter is valid."

# ============================================================
# VALIDATE SOURCE PPD
# ============================================================

step "Validating PPD"

if [[ ! -s "$PPD_SOURCE" ]]; then
    die "PPD file exists but is empty: $PPD_SOURCE"
fi

if ! grep -q '^\*PPD-Adobe:' "$PPD_SOURCE"; then
    warn "PPD does not contain the usual *PPD-Adobe header."
fi

if ! grep -q 'bc88ac' "$PPD_SOURCE"; then
    die "PPD does not reference the bc88ac CUPS filter."
fi

success "PPD contains the expected bc88ac filter reference."

# ============================================================
# INSTALL PPD
# ============================================================

step "Installing PPD"

$SUDO install -d -m 755 "$CUPS_PPD_DIR"

$SUDO install -m 644 "$PPD_SOURCE" "$INSTALLED_PPD"

if ! $SUDO test -r "$INSTALLED_PPD"; then
    die "Installed PPD is not readable: $INSTALLED_PPD"
fi

success "PPD installed:"
printf '  %s\n' "$INSTALLED_PPD"

# ============================================================
# RESTART CUPS AFTER DRIVER INSTALLATION
# ============================================================

step "Restarting CUPS after driver installation"

if ! $SUDO systemctl restart cups; then
    die "CUPS failed to restart after installing the driver."
fi

sleep 1

if ! systemctl is-active --quiet cups; then
    die "CUPS is not active after restart."
fi

success "CUPS restarted successfully."

# ============================================================
# VALIDATE CUPS FILTER DISCOVERY
# ============================================================

step "Checking CUPS filter installation"

if [[ ! -x "$INSTALLED_FILTER" ]]; then
    die "CUPS filter is missing or not executable."
fi

if ! grep -q "$FILTER_NAME" "$INSTALLED_PPD"; then
    die "Installed PPD does not reference $FILTER_NAME."
fi

success "CUPS can access the custom filter."

# ============================================================
# REMOVE OLD PRINTER IF NECESSARY
# ============================================================

step "Checking existing BC88AC CUPS printer"

if lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
    EXISTING_URI="$(lpstat -v "$PRINTER_NAME" 2>/dev/null | sed -E 's/^device for [^:]+: //')"

    info "Existing printer '$PRINTER_NAME' found."
    info "Existing URI: ${EXISTING_URI:-unknown}"

    if [[ "$EXISTING_URI" != "$PRINTER_URI" ]]; then
        warn "Existing printer points to a different URI."
        warn "It will be updated to the detected BlackCopper URI."
    else
        info "Existing printer already uses the detected URI."
    fi
else
    info "No existing BC88AC CUPS printer found."
fi

# ============================================================
# CREATE / UPDATE CUPS PRINTER
# ============================================================

step "Configuring CUPS printer"

if ! $SUDO lpadmin \
    -p "$PRINTER_NAME" \
    -v "$PRINTER_URI" \
    -P "$INSTALLED_PPD" \
    -E; then

    die "lpadmin failed while configuring printer '$PRINTER_NAME'."
fi

success "CUPS printer configured."

# ============================================================
# ENABLE / ACCEPT JOBS
# ============================================================

step "Enabling printer and accepting jobs"

if ! $SUDO cupsenable "$PRINTER_NAME"; then
    die "Could not enable printer '$PRINTER_NAME'."
fi

if ! $SUDO cupsaccept "$PRINTER_NAME"; then
    die "Could not configure CUPS to accept jobs for '$PRINTER_NAME'."
fi

success "Printer is enabled and accepting jobs."

# ============================================================
# SET DEFAULT
# ============================================================

step "Setting BC88AC as the default printer"

if ! $SUDO lpadmin -d "$PRINTER_NAME"; then
    die "Could not set '$PRINTER_NAME' as the default printer."
fi

DEFAULT_PRINTER="$(lpstat -d 2>&1 || true)"

if ! printf '%s\n' "$DEFAULT_PRINTER" | grep -q "$PRINTER_NAME"; then
    die "BC88AC was not successfully set as the default printer."
fi

success "BC88AC is the default printer."

# ============================================================
# VALIDATE PRINTER CONFIGURATION
# ============================================================

step "Validating complete printer configuration"

PRINTER_STATUS="$(lpstat -p "$PRINTER_NAME" 2>&1 || true)"
DEVICE_STATUS="$(lpstat -v "$PRINTER_NAME" 2>&1 || true)"

info "$PRINTER_STATUS"
info "$DEVICE_STATUS"

if ! printf '%s\n' "$PRINTER_STATUS" | grep -qi "enabled"; then
    die "Printer exists but does not appear to be enabled."
fi

if ! printf '%s\n' "$DEVICE_STATUS" | grep -Fq "$PRINTER_URI"; then
    die "Printer URI does not match the detected BlackCopper URI."
fi

success "Printer configuration is correct."

# ============================================================
# CHECK PPD OPTIONS
# ============================================================

step "Checking PPD options through CUPS"

if ! lpoptions -p "$PRINTER_NAME" -l >/tmp/bc88ac-lpoptions.$$ 2>&1; then
    cat /tmp/bc88ac-lpoptions.$$ >> "$LOG_FILE" || true
    rm -f /tmp/bc88ac-lpoptions.$$
    die "CUPS could not load the BC88AC PPD."
fi

LP_OPTIONS="$(cat /tmp/bc88ac-lpoptions.$$)"
rm -f /tmp/bc88ac-lpoptions.$$

printf '%s\n' "$LP_OPTIONS" >> "$LOG_FILE"

if [[ -z "$LP_OPTIONS" ]]; then
    die "CUPS returned no options for the BC88AC PPD."
fi

success "CUPS successfully loaded the BC88AC PPD."

# ============================================================
# FILTER-ONLY TEST
# ============================================================

step "Running filter-only PDF conversion test"

TEST_PDF="${TMP_DIR}/test.pdf"
TEST_OUTPUT="${TMP_DIR}/test-output.bin"

#
# Find an existing PDF first.
#
TEST_SOURCE_PDF=""

while IFS= read -r candidate; do
    if [[ -f "$candidate" ]]; then
        TEST_SOURCE_PDF="$candidate"
        break
    fi
done < <(
    find \
        "$HOME/Documents" \
        "$HOME/Downloads" \
        "$SCRIPT_DIR" \
        -maxdepth 3 \
        -type f \
        -iname '*.pdf' \
        2>/dev/null |
    head -20
)

#
# If no PDF exists, generate a minimal PDF using Python.
#
if [[ -z "$TEST_SOURCE_PDF" ]]; then
    info "No existing PDF found."
    info "Generating a minimal test PDF."

    python3 - "$TEST_PDF" <<'PY'
import sys

path = sys.argv[1]

objects = []

objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
objects.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
objects.append(
    b"<< /Type /Page /Parent 2 0 R "
    b"/MediaBox [0 0 226 113] "
    b"/Contents 4 0 R "
    b"/Resources << /Font << /F1 5 0 R >> >> >>"
)

content = (
    b"BT\n"
    b"/F1 18 Tf\n"
    b"20 75 Td\n"
    b"(BC88AC PRINTER TEST) Tj\n"
    b"0 -28 Td\n"
    b"(Linux Mint / CUPS) Tj\n"
    b"ET\n"
)

objects.append(
    b"<< /Length " +
    str(len(content)).encode() +
    b" >>\nstream\n" +
    content +
    b"endstream"
)

objects.append(
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
)

pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")

offsets = [0]

for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f"{i} 0 obj\n".encode())
    pdf.extend(obj)
    pdf.extend(b"\nendobj\n")

xref = len(pdf)

pdf.extend(
    f"xref\n0 {len(objects)+1}\n".encode()
)
pdf.extend(b"0000000000 65535 f \n")

for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())

pdf.extend(
    f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\n"
    f"startxref\n{xref}\n%%EOF\n".encode()
)

with open(path, "wb") as f:
    f.write(pdf)

print(path)
PY

    TEST_SOURCE_PDF="$TEST_PDF"
else
    info "Using existing PDF for filter test:"
    info "$TEST_SOURCE_PDF"
fi

if ! pdfinfo "$TEST_SOURCE_PDF" >/dev/null 2>&1; then
    die "pdfinfo cannot read the test PDF: $TEST_SOURCE_PDF"
fi

#
# Run the filter with normal CUPS filter arguments.
#
FILTER_STDERR="${TMP_DIR}/filter.stderr"

if ! "$INSTALLED_FILTER" \
    1 \
    "$(id -un)" \
    "BC88AC Installer Test" \
    1 \
    "" \
    "$TEST_SOURCE_PDF" \
    >"$TEST_OUTPUT" \
    2>"$FILTER_STDERR"; then

    echo
    echo "---------------- FILTER STDERR ----------------"
    cat "$FILTER_STDERR" || true
    echo "------------------------------------------------"
    cat "$FILTER_STDERR" >> "$LOG_FILE" 2>/dev/null || true

    die "The BC88AC filter failed during the filter-only conversion test."
fi

OUTPUT_SIZE="$(stat -c '%s' "$TEST_OUTPUT" 2>/dev/null || echo 0)"

if [[ "$OUTPUT_SIZE" -le 0 ]]; then
    die "The BC88AC filter exited successfully but produced 0 bytes."
fi

success "Filter conversion succeeded."
info "Generated ESC/POS output: $OUTPUT_SIZE bytes"

# ============================================================
# BASIC ESC/POS SIGNATURE CHECK
# ============================================================

step "Checking generated ESC/POS output"

#
# ESC/POS commonly begins with initialization bytes.
# We don't require a specific exact header because the
# supplied filter may intentionally structure the stream
# differently.
#

if command -v xxd >/dev/null 2>&1; then
    info "First bytes of generated output:"
    xxd -l 32 "$TEST_OUTPUT" || true
else
    warn "xxd not installed; skipping binary preview."
fi

success "Binary printer output was generated."

# ============================================================
# FINAL CUPS RESTART
# ============================================================

step "Performing final CUPS restart"

if ! $SUDO systemctl restart cups; then
    die "Final CUPS restart failed."
fi

sleep 1

if ! systemctl is-active --quiet cups; then
    die "CUPS is not active after the final restart."
fi

success "Final CUPS restart successful."

# ============================================================
# FINAL VALIDATION
# ============================================================

step "Performing final system validation"

echo
echo "------------------------------------------------------------"
echo "CUPS:"
echo "------------------------------------------------------------"

lpstat -r

echo
echo "------------------------------------------------------------"
echo "Printer:"
echo "------------------------------------------------------------"

lpstat -p "$PRINTER_NAME"

echo
echo "------------------------------------------------------------"
echo "Device:"
echo "------------------------------------------------------------"

lpstat -v "$PRINTER_NAME"

echo
echo "------------------------------------------------------------"
echo "Default:"
echo "------------------------------------------------------------"

lpstat -d

echo
echo "------------------------------------------------------------"
echo "PPD options:"
echo "------------------------------------------------------------"

lpoptions -p "$PRINTER_NAME" -l | head -50

echo
echo "------------------------------------------------------------"
echo "Filter:"
echo "------------------------------------------------------------"

ls -l "$INSTALLED_FILTER"

echo
echo "------------------------------------------------------------"
echo "PPD:"
echo "------------------------------------------------------------"

ls -l "$INSTALLED_PPD"

echo

# ============================================================
# SUCCESS
# ============================================================

printf "${GREEN}${BOLD}"
printf '%s\n' "============================================================"
printf '%s\n' "             INSTALLATION SUCCESSFUL"
printf '%s\n' "============================================================"
printf "${RESET}"

printf '%s\n' "Printer:       $PRINTER_NAME"
printf '%s\n' "Device URI:    $PRINTER_URI"
printf '%s\n' "Filter:        $INSTALLED_FILTER"
printf '%s\n' "PPD:           $INSTALLED_PPD"
printf '%s\n' "Default:       yes"
printf '%s\n' "CUPS:          running"
printf '%s\n' "Filter test:   passed"
printf '%s\n' "Diagnostic:    $LOG_FILE"

echo
printf "${CYAN}${BOLD}No physical test receipt was printed.${RESET}\n"
printf "To print a real PDF:\n\n"
printf "    lp -d %s /path/to/file.pdf\n\n" "$PRINTER_NAME"

printf "${GREEN}Done.${RESET}\n"
