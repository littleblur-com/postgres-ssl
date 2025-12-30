# SSL-enabled Postgres DB image with JSON Logging

This is a fork of [railwayapp-templates/postgres-ssl](https://github.com/railwayapp-templates/postgres-ssl) that adds **structured JSON logging** support (PostgreSQL 15+).

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/postgres)

## What's Different in This Fork?

This fork adds JSON structured logging configuration to PostgreSQL (15+), making logs easier to parse and analyze. **Logs are automatically piped to stderr for Railway compatibility.**

### How It Works

1. PostgreSQL's `logging_collector` writes JSON logs to `$PGDATA/log/postgresql.json`
2. A background `tail -F` process pipes the JSON log file to stderr
3. Railway captures stderr and displays the structured JSON logs

### JSON Logging Configuration

The following settings are applied for JSON logging with minimal useful visibility:

```ini
logging_collector = on          # Required for jsonlog destination
log_destination = 'jsonlog'     # Output JSON format
log_directory = 'log'           # Log file directory
log_filename = 'postgresql'     # PostgreSQL appends .json automatically
log_rotation_age = 0            # No time-based rotation
log_rotation_size = 1MB         # Truncate at 1MB
log_truncate_on_rotation = on   # Overwrite on rotation
log_min_duration_statement = 1000  # Log queries taking >1 second
```

### JSON Log Output

Each log entry is a JSON object with fields like:
- `timestamp`, `pid`, `user`, `dbname`
- `error_severity`, `message`, `detail`, `hint`
- `statement`, `application_name`, `backend_type`

Example log entry:
```json
{"timestamp":"2025-01-15 10:23:45.123 UTC","pid":1234,"user":"postgres","dbname":"mydb","error_severity":"LOG","message":"connection authorized: user=postgres database=mydb"}
```

---

## Original README Content

### Why SSL?

The official Postgres image in Docker hub does not come with SSL baked in.

Since this could pose a problem for applications or services attempting to
connect to Postgres services, we decided to roll our own Postgres image with SSL
enabled right out of the box.

### How does it work?

The Dockerfiles contained in this repository start with the official Postgres
image as base. Then the `init-ssl.sh` script is copied into the
`docker-entrypoint-initdb.d/` directory to be executed upon initialization.

### Certificate expiry

By default, the cert expiry is set to 820 days. You can control this by
configuring the `SSL_CERT_DAYS` environment variable as needed.

### Certificate renewal

When a redeploy or restart is done the certificates expiry is checked, if it has
expired or will expire in 30 days a new certificate is automatically generated.

### Available image tags

Images are automatically built weekly and tagged with multiple version levels
for flexibility:

- **Major version tags** (e.g., `:17`, `:16`, `:15`): Always points to the
  latest minor version for that major release
- **Minor version tags** (e.g., `:17.6`, `:16.10`): Pins to specific minor
  version for stability
- **Latest tag** (`:latest`): Currently points to PostgreSQL 16

Example usage:

```bash
# Auto-update to latest minor versions (recommended for development)
docker run ghcr.io/railwayapp-templates/postgres-ssl:17

# Pin to specific minor version (recommended for production)
docker run ghcr.io/railwayapp-templates/postgres-ssl:17.6
```

### A note about ports

By default, this image is hardcoded to listen on port `5432` regardless of what
is set in the `PGPORT` environment variable. We did this to allow connections
to the postgres service over the `RAILWAY_TCP_PROXY_PORT`. If you need to
change this behavior, feel free to build your own image without passing the
`--port` parameter to the `CMD` command in the Dockerfile.
