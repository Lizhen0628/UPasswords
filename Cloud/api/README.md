# Go API Deployment

UPasswords project documentation uses development version v1. API path versions and
the row-sync capability version are separate protocol identifiers.

The canonical and only public API prefix is `/v1/`; `/v2/` returns 404. Production and
current clients use row-sync capability version 5. Authenticated item, change,
attachment, conflict and rekey routes require `X-UPW-Sync-Protocol: 5`; old protocol
requests are rejected before reading or modifying sync data. Nginx runs in the existing
`nginxui` container and forwards requests to the API over the existing Docker network.
MariaDB remains on the private network and encrypted attachments remain in Cloudflare R2.

## Production Configuration

Create `.env` from `.env.example` and set mode `0600`. Reuse the existing `APP_KEK`
exactly; changing it would make existing encrypted email and vault envelopes unreadable.
Production uses `DB_TLS=pinned` and `DB_CA_FILE=/run/secrets/mariadb.pem`; the PEM file
may contain up to four trusted database certificates. For planned rotation, verify the
new public-key fingerprint through a trusted database administration channel, add its
certificate alongside the current one before rotating the server certificate, and run
`docker compose run --rm --no-deps api check` after rotation. Remove the old pin only
after the new certificate has been verified. Do not adopt a certificate solely from an
unauthenticated failed connection. Keep the environment file and all files under
`secrets/` out of version control.

The configured 163 SMTP account sends registration and verification mail. Its
`SMTP_FROM` address must be authorized by 163. `SMTP_REGISTER_REPLY_TO` and
`SMTP_VERIFY_REPLY_TO` route replies to the corresponding product addresses.

## Schema prerequisite

This API requires `Cloud/database/0001_init.sql` followed by
`0002_user_profiles.sql`, `0003_conflict_candidates.sql`,
`0004_conflict_candidate_fingerprint.sql`, `0005_conflict_resolution.sql`,
`0006_conflict_resolution_change_events.sql`, `0007_composed_conflict_resolutions.sql`,
`0008_attachment_versions.sql`, `0009_attachment_purge_state.sql`, and
`0010_rekey_conflict_candidates.sql`. The migrations add encrypted profile rows,
retained conflict candidates, keyed retry fingerprints, durable item tombstones,
conflict resolution metadata, versioned attachment retention, and rekey candidate staging.
Migration 0005 can backfill only deletion events still present in `item_changes`; expired history
cannot be reconstructed. For an initialized database, apply only missing migrations
in order with a privileged deployment account:

```sh
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0002_user_profiles.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0003_conflict_candidates.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0004_conflict_candidate_fingerprint.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0005_conflict_resolution.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0006_conflict_resolution_change_events.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0007_composed_conflict_resolutions.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0008_attachment_versions.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0009_attachment_purge_state.sql
mariadb --defaults-extra-file=/secure/path/mariadb-client.cnf upasswords < ../database/0010_rekey_conflict_candidates.sql
```

The resolver appends one `op=resolve` event in the same transaction as the row or
tombstone update, head sequence update, and 30-day retention of all candidate ciphertexts.
Restoring a winner after source deletion requires a new UUID and ciphertext re-encrypted
for that identity. Whole-candidate resolution can atomically activate the winner's complete
attachment-version reference set; composed resolution is limited to reliable no-attachment
candidates. macOS, iOS and the four browser extensions register, review and resolve
candidates. Rekey snapshots include open
and 30-day retained candidate ciphertexts; candidate IDs, selected-candidate references
and retained resolution-event references migrate atomically with the vault rows. Rekey
abort removes the candidate staging manifest without changing live data.

Change events are retained for `CHANGE_RETENTION_DAYS` (90 days by default). If a native
client's cursor expires while it has pending local data or a conflict marker, it blocks
automatic full rebuild to preserve that data. macOS and iOS expose a protected recovery
flow that first publishes a self-contained backup and adopts the cloud snapshot only after
that backup succeeds. The production database is not disposable; any reset requires separate
explicit authorization and a verified backup. Backup and restore jobs are configured, but
the completed smoke drill does not prove the four-hour RTO at production scale.

Run this from `Cloud/api`. The running API and its `check` command never create or
alter tables; the application account keeps data permissions only. Apply the
additive migration before starting the matching image. Once profiles, conflict candidates
or versioned attachments exist, recovery must use a protocol-5 image and scheduler that
understand the complete schema. Do not restart an older maintenance scheduler or pre-
protocol-5 API against the current production database.

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
