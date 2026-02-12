#!/bin/bash

# exit as soon as any of these commands fail, this prevents starting a database without certificates or with the wrong volume mount path
set -e

EXPECTED_VOLUME_MOUNT_PATH="/var/lib/postgresql/data"

# check if the Railway volume is mounted to the correct path
# we do this by checking the current mount path (RAILWAY_VOLUME_MOUNT_PATH) agiant the expected mount path
# if the paths are different, we print an error message and exit
# only perform this check if this image is deployed to Railway by checking for the existence of the RAILWAY_ENVIRONMENT variable
if [ -n "$RAILWAY_ENVIRONMENT" ] && [ "$RAILWAY_VOLUME_MOUNT_PATH" != "$EXPECTED_VOLUME_MOUNT_PATH" ]; then
  echo "Railway volume not mounted to the correct path, expected $EXPECTED_VOLUME_MOUNT_PATH but got $RAILWAY_VOLUME_MOUNT_PATH"
  echo "Please update the volume mount path to the expected path and redeploy the service"
  exit 1
fi

# check if PGDATA starts with the expected volume mount path
# this ensures data files are stored in the correct location
# if not, print error and exit to prevent data loss or access issues
if [[ ! "$PGDATA" =~ ^"$EXPECTED_VOLUME_MOUNT_PATH" ]]; then
  echo "PGDATA variable does not start with the expected volume mount path, expected to start with $EXPECTED_VOLUME_MOUNT_PATH"
  echo "Please update the PGDATA variable to start with the expected volume mount path and redeploy the service"
  exit 1
fi

# Set up needed variables
SSL_DIR="/var/lib/postgresql/data/certs"
INIT_SSL_SCRIPT="/docker-entrypoint-initdb.d/init-ssl.sh"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

# Regenerate if the certificate is not a x509v3 certificate
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -noout -text -in "$SSL_DIR/server.crt" | grep -q "DNS:localhost"; then
  echo "Did not find a x509v3 certificate, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Regenerate if the certificate has expired or will expire
# 2592000 seconds = 30 days
if [ -f "$SSL_DIR/server.crt" ] && ! openssl x509 -checkend 2592000 -noout -in "$SSL_DIR/server.crt"; then
  echo "Certificate has or will expire soon, regenerating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Generate a certificate if the database was initialized but is missing a certificate
# Useful when going from the base postgres image to this ssl image
if [ -f "$POSTGRES_CONF_FILE" ] && [ ! -f "$SSL_DIR/server.crt" ]; then
  echo "Database initialized without certificate, generating certificates..."
  bash "$INIT_SSL_SCRIPT"
fi

# Adds pg_stat_statements to shared_preload_libraries in a config file
# Usage: add_pg_stat_statements <config_file>
add_pg_stat_statements() {
  local config_file="$1"
  local current_libs
  # Extract value - handles quoted ('val', "val") and unquoted (val) formats
  current_libs=$(grep -E "^[[:space:]]*shared_preload_libraries" "$config_file" 2>/dev/null | tail -1 | sed "s/.*=[[:space:]]*//; s/^['\"]//; s/['\"].*$//; s/[[:space:]]*$//")
  if [ -n "$current_libs" ]; then
    echo "shared_preload_libraries = '${current_libs},pg_stat_statements'" >> "$config_file"
  else
    echo "shared_preload_libraries = 'pg_stat_statements'" >> "$config_file"
  fi
}

# Ensure pg_stat_statements is in shared_preload_libraries for existing databases
# This handles databases created before this setting was added
AUTO_CONF_FILE="$PGDATA/postgresql.auto.conf"
if [ -f "$POSTGRES_CONF_FILE" ] && ! grep -q "pg_stat_statements" "$POSTGRES_CONF_FILE"; then
  echo "Adding pg_stat_statements to shared_preload_libraries..."
  add_pg_stat_statements "$POSTGRES_CONF_FILE"
  # Only update auto.conf if it has shared_preload_libraries set (which would override postgresql.conf)
  # and doesn't already have pg_stat_statements
  if grep -q "^[[:space:]]*shared_preload_libraries" "$AUTO_CONF_FILE" 2>/dev/null && ! grep -q "pg_stat_statements" "$AUTO_CONF_FILE" 2>/dev/null; then
    add_pg_stat_statements "$AUTO_CONF_FILE"
  fi
fi

# unset PGHOST to force psql to use Unix socket path
# this is specific to Railway and allows
# us to use PGHOST after the init
unset PGHOST

## unset PGPORT also specific to Railway
## since postgres checks for validity of
## the value in PGPORT we unset it in case
## it ends up being empty
unset PGPORT

# JSON log file location (created by logging_collector)
JSON_LOG_FILE="$PGDATA/log/postgresql.json"

# Ensure JSON logging is configured in postgresql.conf (for existing databases)
# init-ssl.sh only runs on first init, so we need to add config for existing DBs
# Check for our specific config marker (log_filename = 'postgresql' without .json)
if [ -f "$POSTGRES_CONF_FILE" ] && ! grep -q "^log_filename = 'postgresql'$" "$POSTGRES_CONF_FILE"; then
    echo "Adding JSON logging configuration to postgresql.conf..."
    cat >> "$POSTGRES_CONF_FILE" <<'LOGGING_EOF'

# JSON structured logging (added by wrapper.sh for Railway)
logging_collector = on
log_destination = 'jsonlog'
log_directory = 'log'
log_filename = 'postgresql'
log_rotation_age = 0
log_rotation_size = 1MB
log_truncate_on_rotation = on
log_min_duration_statement = 300

# Auto-disconnect idle sessions to allow serverless sleep
idle_session_timeout = '10min'
LOGGING_EOF
fi

# Add idle_session_timeout for existing databases that have logging but not timeout
if [ -f "$POSTGRES_CONF_FILE" ] && ! grep -q "^idle_session_timeout" "$POSTGRES_CONF_FILE"; then
    echo "Adding idle_session_timeout to postgresql.conf..."
    cat >> "$POSTGRES_CONF_FILE" <<'IDLE_EOF'

# Auto-disconnect idle sessions to allow serverless sleep (added by wrapper.sh)
idle_session_timeout = '10min'
IDLE_EOF
fi

# Clear old log file to start fresh (may contain old text-format logs)
if [ -f "$JSON_LOG_FILE" ]; then
    echo "Clearing old log file for fresh JSON logging..."
    > "$JSON_LOG_FILE"
fi

# Start PostgreSQL in background, then tail logs in foreground
# This ensures tail output is captured by Railway as the main process
/usr/local/bin/docker-entrypoint.sh "$@" &
POSTGRES_PID=$!

# Wait for log file to be created, then tail it
echo "Waiting for PostgreSQL log file..."
while [ ! -f "$JSON_LOG_FILE" ]; do
    # Check if postgres is still running
    if ! kill -0 $POSTGRES_PID 2>/dev/null; then
        echo "PostgreSQL process exited unexpectedly"
        wait $POSTGRES_PID
        exit $?
    fi
    sleep 1
done

echo "Tailing JSON logs from $JSON_LOG_FILE"

# Tail in foreground - forward signals to postgres
trap "kill $POSTGRES_PID 2>/dev/null; wait $POSTGRES_PID; exit" SIGTERM SIGINT SIGQUIT

# Tail log file, suppress "file truncated" messages
tail -F "$JSON_LOG_FILE" 2>/dev/null &
TAIL_PID=$!

# Wait for postgres to exit
wait $POSTGRES_PID
POSTGRES_EXIT=$?

# Clean up tail
kill $TAIL_PID 2>/dev/null

exit $POSTGRES_EXIT