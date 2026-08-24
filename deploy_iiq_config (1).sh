#!/usr/bin/env bash
#
# deploy_iiq_config.sh
#
# Batch-imports an IdentityIQ config export (one subfolder per object class,
# as produced by the Object Exporter plugin) into a target environment via
# `iiq console`, in a dependency-safe order.
#
# Usage:
#   ./deploy_iiq_config.sh -i <iiq-bin-dir> -d <export-base-dir> [options]
#
# Required:
#   -i <dir>   Path to the IdentityIQ WEB-INF/bin directory (where ./iiq lives)
#   -d <dir>   Base directory of the export (contains one subfolder per class)
#
# Options:
#   -u <user>          IIQ username to authenticate the console with (default: spadmin)
#                       You will be prompted for the password interactively.
#   --keep-ids         Do NOT strip object IDs on import (default: strips them with -noids)
#   --no-role-events   Pass -noroleevents when importing Bundle (role) files
#   --dry-run          Build and show the import plan/command file, but don't run iiq console
#   -h, --help         Show this help
#
# Example:
#   ./deploy_iiq_config.sh -i /opt/tomcat/webapps/identityiq/WEB-INF/bin \
#                           -d /home/me/export -u spadmin

set -uo pipefail

# ---------------------------------------------------------------------------
# Known dependency order. Classes are imported in this order when their
# folder is present in the export. Any folder found that ISN'T in this list
# is imported LAST, alphabetically, with a warning -- review those manually.
# ---------------------------------------------------------------------------
ORDER=(
  DynamicScope
  Rule
  ObjectConfig
  Configuration
  UIConfig
  EmailTemplate
  MessageTemplate
  AdaptiveCardNotificationTemplate
  Form
  TimePeriod
  Category
  Classification
  ManagedAttribute
  Policy
  PasswordPolicy
  CorrelationConfig
  Capability
  Scope
  Workflow
  TaskDefinition
  RequestDefinition
  IntegrationConfig
  CertificationDefinition
  GroupDefinition
  QuickLink
  QuickLinkOptions
  Bundle
)

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
IIQ_BIN_DIR=""
BASE_DIR=""
IIQ_USER="spadmin"
NOIDS="-noids"
NOROLEEVENTS=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) IIQ_BIN_DIR=${2:-}; shift 2 ;;
    -d) BASE_DIR=${2:-}; shift 2 ;;
    -u) IIQ_USER=${2:-}; shift 2 ;;
    --keep-ids) NOIDS=""; shift ;;
    --no-role-events) NOROLEEVENTS="-noroleevents"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -z "$IIQ_BIN_DIR" || -z "$BASE_DIR" ]] && usage

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ ! -d "$IIQ_BIN_DIR" ]]; then
  echo "ERROR: IIQ bin directory not found: $IIQ_BIN_DIR" >&2
  exit 1
fi
if [[ ! -x "$IIQ_BIN_DIR/iiq" ]]; then
  echo "ERROR: iiq executable not found (or not executable) in: $IIQ_BIN_DIR" >&2
  exit 1
fi
if [[ ! -d "$BASE_DIR" ]]; then
  echo "ERROR: export base directory not found: $BASE_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect class subfolders that actually contain .xml files
# ---------------------------------------------------------------------------
declare -A DIR_BY_CLASS
while IFS= read -r -d '' d; do
  class_name=$(basename "$d")
  if compgen -G "$d"/*.xml > /dev/null 2>&1; then
    DIR_BY_CLASS["$class_name"]="$d"
  fi
done < <(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

if [[ ${#DIR_BY_CLASS[@]} -eq 0 ]]; then
  echo "No class subfolders containing .xml files were found under: $BASE_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build the ordered class list: known order first, then leftovers
# ---------------------------------------------------------------------------
ORDERED_CLASSES=()
declare -A SEEN

for class in "${ORDER[@]}"; do
  if [[ -n "${DIR_BY_CLASS[$class]:-}" ]]; then
    ORDERED_CLASSES+=("$class")
    SEEN["$class"]=1
  fi
done

LEFTOVER_CLASSES=()
for class in "${!DIR_BY_CLASS[@]}"; do
  [[ -z "${SEEN[$class]:-}" ]] && LEFTOVER_CLASSES+=("$class")
done
if [[ ${#LEFTOVER_CLASSES[@]} -gt 0 ]]; then
  IFS=$'\n' LEFTOVER_CLASSES=($(sort <<< "${LEFTOVER_CLASSES[*]}"))
  unset IFS
  echo "WARNING: these folders aren't in the known dependency order and will"
  echo "be imported LAST, alphabetically. Confirm that's safe before proceeding:"
  printf '  - %s\n' "${LEFTOVER_CLASSES[@]}"
  echo
fi
ORDERED_CLASSES+=("${LEFTOVER_CLASSES[@]}")

# ---------------------------------------------------------------------------
# Build the command file (cleaned up automatically on exit, always)
# ---------------------------------------------------------------------------
CMD_FILE=$(mktemp /tmp/iiq_import_commands.XXXXXX.txt)
cleanup() { rm -f "$CMD_FILE"; }
trap cleanup EXIT INT TERM

TOTAL_FILES=0
for class in "${ORDERED_CLASSES[@]}"; do
  dir="${DIR_BY_CLASS[$class]}"
  flag="$NOIDS"
  [[ "$class" == "Bundle" && -n "$NOROLEEVENTS" ]] && flag="$flag $NOROLEEVENTS"
  while IFS= read -r -d '' f; do
    if [[ -n "$flag" ]]; then
      echo "import $flag $f" >> "$CMD_FILE"
    else
      echo "import $f" >> "$CMD_FILE"
    fi
    TOTAL_FILES=$((TOTAL_FILES + 1))
  done < <(find "$dir" -maxdepth 1 -type f -name '*.xml' -print0 | sort -z)
done

# Note: file paths containing spaces aren't quoted above, since the IIQ
# console's own docs don't confirm quoted-argument support. Avoid spaces
# in your export path/filenames to be safe.

# ---------------------------------------------------------------------------
# Show the plan
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "IdentityIQ Config Deploy"
echo "  IIQ bin dir : $IIQ_BIN_DIR"
echo "  Export dir  : $BASE_DIR"
echo "  IIQ user    : $IIQ_USER"
echo "  Strip IDs   : $([[ -n "$NOIDS" ]] && echo yes || echo no)"
echo "  Total files : $TOTAL_FILES"
echo "===================================================================="
echo "Import order:"
i=1
for class in "${ORDERED_CLASSES[@]}"; do
  count=$(find "${DIR_BY_CLASS[$class]}" -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d ' ')
  printf '  %2d. %-28s (%s file(s))\n' "$i" "$class" "$count"
  i=$((i + 1))
done
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[--dry-run] Generated command file preview:"
  echo "--------------------------------------------------------------------"
  cat "$CMD_FILE"
  echo "--------------------------------------------------------------------"
  echo "[--dry-run] No import was run. Command file will now be cleaned up."
  exit 0
fi

read -rp "Proceed with import into this environment? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted. No changes made."
  exit 0
fi

# ---------------------------------------------------------------------------
# Run the import (prompts for password interactively -- never stored)
# ---------------------------------------------------------------------------
echo "Running import via iiq console..."
( cd "$IIQ_BIN_DIR" && ./iiq console -u "$IIQ_USER" -f "$CMD_FILE" )
STATUS=$?

if [[ $STATUS -eq 0 ]]; then
  echo "Import completed. Cleaning up the generated command file."
else
  echo "iiq console exited with status $STATUS. Review the output above." >&2
fi

exit $STATUS
