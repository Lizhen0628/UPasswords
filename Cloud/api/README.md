# Go API Deployment

UPasswords project documentation uses development version v1. API path versions and
the row-sync capability version are separate protocol identifiers.

The canonical API prefix is `/v1/`; `/v2/` remains available as a compatibility alias
for already-installed clients. Both prefixes expose the same row-sync protocol
(capability version 2), handlers, and data. Nginx runs in the existing `nginxui`
container and forwards requests to the API over the existing Docker network. MariaDB
remains on the private network and encrypted attachments remain in the Cloudflare R2
bucket.

## Production Configuration

Create `.env` from `.env.example` and set mode `0600`. Reuse the existing `APP_KEK`
exactly; changing it would make existing encrypted email and vault envelopes unreadable.
The database certificate is pinned by its public key in `secrets/mariadb.pem`. Keep
the environment file and all files under `secrets/` out of version control.

The configured 163 SMTP account sends registration and verification mail. Its
`SMTP_FROM` address must be authorized by 163. `SMTP_REGISTER_REPLY_TO` and
`SMTP_VERIFY_REPLY_TO` route replies to the corresponding product addresses.

## Run and Verify

Run the isolated MariaDB integration suite with `docker compose -f compose.test.yaml up
--abort-on-container-exit --exit-code-from test`. The test database uses temporary
storage and the test code refuses database names that do not end in `_test`.

Run `docker compose run --rm --no-deps api check` to verify the production schema,
existing APP_KEK compatibility, R2 access, and SMTP authentication without sending
mail or changing user data. Start the API and daily maintenance scheduler with
`docker compose up -d --build`. The API listens on loopback port `18080`; Nginx
connects to it on the Docker network. `/health/ready` is only for local health checks
and is hidden at the public proxy.

The scheduler runs maintenance at 04:00 UTC and uses a MariaDB named lock to avoid
duplicate runs. Database `GET_LOCK` values are scoped to their owning connection.
Production maintenance must only be enabled on one deployment.

Cloudflare's zone SSL mode must remain Full (strict), with the API origin certificate
installed in Nginx. The Cloudflare proxy continues to provide DNS, TLS and WAF; the
API origin remains the Go service.

## Release Backup and Rollback

Before deploying a release, preserve the current Go image and take a verified MariaDB
backup before any schema change. Keep database credentials in a protected client option
file rather than on the command line:

```sh
docker image tag upasswords-api:local upasswords-api:rollback
mariadb-dump --defaults-extra-file=/secure/path/mariadb-client.cnf \
  --single-transaction --routines --events upasswords \
  > /secure/backups/upasswords-before-release.sql
```

For an application-only failure, restore the saved image. Restore the matching database
backup only when the release changed the schema or wrote data that the old image cannot
read. Database restoration requires downtime and discards database writes made after
that backup:

```sh
docker compose stop api maintenance
docker image tag upasswords-api:rollback upasswords-api:local
docker compose up -d --no-build api maintenance
docker compose run --rm --no-deps api check
```

If database recovery is required, keep both services stopped while restoring the
verified backup, then start and check the saved image:

```sh
docker compose stop api maintenance
docker image tag upasswords-api:rollback upasswords-api:local
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords \
  < /secure/backups/upasswords-before-release.sql
docker compose up -d --no-build api maintenance
docker compose run --rm --no-deps api check
```

For migrations that add tables, importing a dump into the existing database does
not remove those extra tables. Rehearse recovery into an empty database and compare
the restored schema before switching production to it. Preserve database grants,
TLS settings and the protected client option file separately.

Keep `APP_KEK` unchanged when restoring. MariaDB backups do not include R2 objects;
R2 recovery is a separate operation, and the production bucket must not be deleted as
part of Worker retirement or database rollback.
