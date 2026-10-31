#!/usr/bin/env bash
set -euo pipefail

# --- Usage ---
# ./clone_db.sh [--dry-run]

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "🧪 Running in DRY-RUN mode — no actual changes will be made."
  echo
fi

echo "🔧 Preparing environment for PostgreSQL clone..."

# --- Function: prompt if variable is missing ---
prompt_if_unset() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-false}"
  local default_value="${4:-}"
  local value

  while [ -z "${!var_name:-}" ]; do
    if [ "$secret" = "true" ]; then
      if ! read -r -s -p "$prompt_text: " value; then
        echo "Input ended; exiting." >&2
        exit 1
      fi
      echo
    else
      if ! read -r -p "$prompt_text: " value; then
        echo "Input ended; exiting." >&2
        exit 1
      fi
    fi
    value="${value:-$default_value}"
    if [ -z "$value" ]; then
      echo "$var_name is required."
      continue
    fi
    export "$var_name"="$value"
  done
}

# --- Collect environment variables ---
prompt_if_unset "PGHOST" "Enter PostgreSQL host (e.g. dmmg-ckan-db-202205.postgres.database.azure.com)"
prompt_if_unset "PGUSER" "Enter PostgreSQL user (e.g. ckan)"
prompt_if_unset "PGPASSWORD" "Enter PostgreSQL password" true
prompt_if_unset "PGDATABASE" "Enter source database name [postgres]" false postgres
export PGSSLMODE="require"

MAINTENANCE_DB=postgres
if [[ "$PGDATABASE" == "postgres" ]]; then
  MAINTENANCE_DB=template1
fi
TIMESTAMP=$(date +"%Y%m%d_%H%M")
TARGET_DB="${PGDATABASE}_clone_${TIMESTAMP}"

echo
echo "🔗 Host:        $PGHOST"
echo "👤 User:        $PGUSER"
echo "📦 Source DB:   $PGDATABASE"
echo "🎯 Target DB:   $TARGET_DB"
echo "🚫 Dry Run:     ${DRY_RUN}"
echo

# --- Helper to execute or print commands ---
PG_CLIENT_IMAGE="${PG_CLIENT_IMAGE:-postgres:14}"
PG_WORKDIR=""
pg14() {
  docker run --rm --network host --user "$(id -u):$(id -g)" \
    -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGSSLMODE \
    -v "${PG_WORKDIR}:/work" -w /work \
    "$PG_CLIENT_IMAGE" "$@"
}

run_cmd() {
  local desc="$1"
  shift
  echo "▶️  ${desc}"
  if [ "$DRY_RUN" = true ]; then
    printf '   → '
  printf '%q ' docker run --rm --network host --user "$(id -u):$(id -g)" -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGSSLMODE -v '<temporary-directory>:/work' -w /work "$PG_CLIENT_IMAGE" "$@"
    printf '\n'
  else
    pg14 "$@"
  fi
}

# Dump first: a failed dump must not leave an empty target database.
# No source connections are terminated. The dump is a consistent snapshot.
DUMP_FILE="/tmp/ckan-clone-dry-run.dump"
RESTORE_LIST="${DUMP_FILE}.list"
PG_DUMP_FILE="$DUMP_FILE"
PG_RESTORE_LIST="$RESTORE_LIST"
if [ "$DRY_RUN" = false ]; then
  command -v docker >/dev/null 2>&1 || { echo "Required command missing: docker" >&2; exit 1; }
  docker image inspect "$PG_CLIENT_IMAGE" >/dev/null 2>&1 || docker pull "$PG_CLIENT_IMAGE"
  SERVER_VERSION=$(docker run --rm --network host -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGSSLMODE "$PG_CLIENT_IMAGE" psql -X -v ON_ERROR_STOP=1 -At -d "$PGDATABASE" -c 'SHOW server_version_num;')
  SERVER_MAJOR=$((SERVER_VERSION / 10000))
  PG_CLIENT_IMAGE="postgres:${SERVER_MAJOR}"
  docker image inspect "$PG_CLIENT_IMAGE" >/dev/null 2>&1 || docker pull "$PG_CLIENT_IMAGE"
  DUMP_FILE=$(mktemp "${TMPDIR:-/tmp}/ckan-clone.XXXXXXXX.dump")
  PG_WORKDIR=$(dirname "$DUMP_FILE")
  RESTORE_LIST="${DUMP_FILE}.list"
  PG_DUMP_FILE="/work/$(basename "$DUMP_FILE")"
  PG_RESTORE_LIST="/work/$(basename "$RESTORE_LIST")"
  trap 'rm -f -- "$DUMP_FILE" "$RESTORE_LIST"' EXIT
fi

# PostgreSQL 14 has no --exclude-extension option. Exclude scheduler data
# during dumping, then omit pg_cron and the Azure-managed extensions from
# the restore list, including metadata for the excluded cron schema.
# Other extensions and application permissions remain included.
prepare_restore_list() {
  pg14 pg_restore --list "$PG_DUMP_FILE" > "$RESTORE_LIST"
  sed -i -E '/ EXTENSION - (pg_cron|azure|pgaadauth)([[:space:]]|$)/d; / COMMENT - EXTENSION (pg_cron|azure|pgaadauth)([[:space:]]|$)/d' "$RESTORE_LIST"
  sed -i -E '/ (ACL|COMMENT|SECURITY LABEL) (- )?SCHEMA cron([[:space:]]|$)/d; / (ACL|DEFAULT ACL|COMMENT|SECURITY LABEL) cron /d' "$RESTORE_LIST"
}

# --- Step 1: Dump the source database ---
echo "Excluding pg_cron and the cron schema (scheduler jobs are not part of this clone)."
echo "Skipping CREATE EXTENSION and COMMENT for the Azure-managed azure and pgaadauth extensions."
run_cmd "Dumping '${PGDATABASE}' (existing connections can remain open)..." \
  pg_dump --format=custom --exclude-schema=cron --exclude-table-data='cron.*' \
  --file="$PG_DUMP_FILE" --dbname="$PGDATABASE"
if [ "$DRY_RUN" = true ]; then
  echo "▶️  Preparing restore list without pg_cron, azure and pgaadauth extension entries..."
  printf '   → docker run ... %q\n' "postgres:14 pg_restore --list <dump>"
else
  echo "▶️  Preparing restore list without pg_cron, azure and pgaadauth extension entries..."
  prepare_restore_list
fi

# --- Step 2: Create and restore the target database ---
run_cmd "Creating '${TARGET_DB}'..." \
  createdb --maintenance-db="$MAINTENANCE_DB" --template=template0 --owner="$PGUSER" "$TARGET_DB"
run_cmd "Restoring into '${TARGET_DB}'..." \
  pg_restore --no-owner --no-acl --exit-on-error --single-transaction --use-list="$PG_RESTORE_LIST" \
  --dbname="$TARGET_DB" "$PG_DUMP_FILE"

# --- Step 3: Inspect the restored database ---
run_cmd "Listing restored extensions and tables..." \
  psql -X -v ON_ERROR_STOP=1 -d "$TARGET_DB" -c '\dx' \
  -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY schemaname, tablename;"

# --- Step 4: Optional cleanup of older clones ---
echo
DELETE_OLD_CLONES=""
read -r -p "Delete older clones? [y/N]: " DELETE_OLD_CLONES || DELETE_OLD_CLONES=""
case "$DELETE_OLD_CLONES" in
  y|Y|yes|YES)
    prompt_if_unset "KEEP_CLONES" "Enter number of clones to keep [1]" false 1
    KEEP_CLONES=${KEEP_CLONES:-1}
    if [[ ! "$KEEP_CLONES" =~ ^[1-9][0-9]*$ ]]; then
      echo "KEEP_CLONES must be a positive integer; no clones deleted." >&2
      exit 1
    fi
    if [ "$DRY_RUN" = true ]; then
      echo "Would check older clones and keep the latest ${KEEP_CLONES}; no database queries or deletions performed."
    else
      OLDER_CLONES=$(psql -X -v ON_ERROR_STOP=1 -tA -d "$MAINTENANCE_DB" \
        -v source="$PGDATABASE" -v keep="$KEEP_CLONES" -v target="$TARGET_DB" <<'SQL'
SELECT datname
FROM (
  SELECT datname FROM pg_database
  WHERE left(datname, length(:'source') + 7) = :'source' || '_clone_'
    AND substring(datname FROM length(:'source') + 8) ~ '^[0-9]{8}_[0-9]{4}$'
  ORDER BY datname DESC
  OFFSET :keep
) AS older
WHERE datname <> :'target';
SQL
)
      if [ -n "$OLDER_CLONES" ]; then
        echo "Deleting older clones:"
        echo "$OLDER_CLONES"
        while IFS= read -r db; do
          [ -z "$db" ] && continue
          # Separate statements run in separate transactions (no -1 / --single-transaction).
          psql -X -v ON_ERROR_STOP=1 -d "$MAINTENANCE_DB" -v clone="$db" <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'clone';
DROP DATABASE :"clone";
SQL
        done <<< "$OLDER_CLONES"
      else
        echo "No old clones to delete."
      fi
    fi
    ;;
  *) echo "Keeping all clones; no databases deleted." ;;
esac

echo
if [ "$DRY_RUN" = true ]; then
  echo "🧪 DRY-RUN complete. No changes were made."
else
  echo "🎉 Done! Clone '${TARGET_DB}' created successfully."
fi
