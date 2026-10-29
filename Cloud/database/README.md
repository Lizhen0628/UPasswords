# Database schema and migrations

`0001_init.sql` is the canonical initializer for the current MariaDB schema. The Go
API does not create or migrate production tables at startup; database administrators
apply SQL from this directory using a privileged deployment account. The API's
runtime account must remain limited to application data operations.

`0002_user_profiles.sql` adds the dedicated kind=3 ciphertext table and the
`vault_sync_items` view used by Go handlers for snapshots, deltas, quotas and
rekey. Migrations through `0010_rekey_conflict_candidates.sql` are present in this
repository and were already applied to production on 2026-10-27. Verify the remote
migration directory and live schema before planning any later operation.
`0003_conflict_candidates.sql` adds encrypted conflict candidate storage
and immutable item-origin snapshots. `0004_conflict_candidate_fingerprint.sql`
adds the VEK-derived HMAC fingerprint used for idempotent retries.
`0005_conflict_resolution.sql` adds permanent item tombstones, conflict resolution
state, and 30-day retention metadata for unselected candidates. It backfills only
delete events still retained in `item_changes`; expired historical events are
unrecoverable. `0006_conflict_resolution_change_events.sql` adds the metadata needed
to publish one atomic `op=resolve` change event, including the source UUID, resolved
UUID, common revision, and selected candidate identity. `0007_composed_conflict_resolutions.sql`
adds the `resolution_type` discriminator for candidate selection versus client-composed
results. `0008_attachment_versions.sql` adds immutable encrypted attachment versions
and retained conflict references, `0009_attachment_purge_state.sql` adds retryable
object deletion, and `0010_rekey_conflict_candidates.sql` adds encrypted conflict
candidate staging during vault rekey. Apply available migrations in lexical order for
a new database. An existing database needs only migrations not already applied. There
is no separate migration ledger, so record the applied range in the deployment record
and verify the schema before applying changes. The API never executes DDL; its `check`
command requires the schema for its build. Production does not auto-migrate and must
never be reset without a new, explicit authorization.

Add future changes as ordered files such as `0011_add_example.sql`. Once a migration
has been applied to a shared or production database, treat it as immutable and add a
new migration for corrections. Verify migrations against the API version that will
consume the resulting schema. Only isolated `_test` databases are disposable. Production
backups live outside this repository; never put database credentials or production data
in this directory.

The isolated Go integration tests apply the numbered SQL files present in their
worktree in lexical order. They replay the sequence on disposable databases and
verify that existing encrypted rows survive. Keep four-digit prefixes to preserve
order; check whether the service-admin worktree is ahead of the local test worktree.

## service-admin database operations

Use the `service-admin` SSH host alias for routine database access. The MariaDB host
is private-network-only; routine SQL is issued from the service-admin host, not by
SSHing to `database-server`.

| Setting | Value or location |
|---|---|
| SSH entry point | `ssh service-admin` |
| Server worktree | `/home/administrator/UPasswords` |
| Database endpoint | `10.0.3.198:6033` (private network) |
| Schema | `upasswords` |
| Client option file | `/home/administrator/UPasswords/Cloud/database/upasswords-deploy.my.cnf` |
| CA file | `/home/administrator/UPasswords/Cloud/database/mariadb-ca.pem` |
| Backup directory | `/home/administrator/.local/share/upasswords-db-backups` |

The deployment account is `upasswords_deploy`, requires SSL, and is scoped to
`upasswords.*`; it is not a global DBA account. The option file, environment file,
and CA file are server-side secrets with mode `0600`. Never print their contents,
copy them into the local repository, or commit them. Pass the option file with
`--defaults-file` as the first MariaDB client option so the password is not exposed
in shell history or process arguments.

Confirm the target schema and encrypted transport before issuing SQL:

~~~sh
cd /home/administrator/UPasswords
mariadb --defaults-file=Cloud/database/upasswords-deploy.my.cnf \
  --ssl-ca=Cloud/database/mariadb-ca.pem --ssl-verify-server-cert \
  --batch --skip-column-names \
  -e "SELECT DATABASE(), CURRENT_USER(), VERSION(); SHOW STATUS LIKE 'Ssl_cipher';"
~~~

Confirm that `DATABASE()` is exactly `upasswords` and `Ssl_cipher` is non-empty. The
current self-signed server certificate has an IP SAN for `10.0.3.198`. `--ssl-ca`
validates the certificate chain against the provisioned certificate, while
`--ssl-verify-server-cert` also verifies that its name matches the database endpoint;
keep both options. A wrong-CA connection must fail.

MariaDB 11.4's automatically generated server certificate is held in memory and changes
when the server restarts. The database therefore uses persistent files on the
`database-server` host, not in the container writable layer:
`/data/mariadb/data/upasswords-server-cert.pem` and
`/data/mariadb/data/upasswords-server-key.pem`. Docker bind-mounts the host directory
`/data/mariadb/data` to `/var/lib/mysql`, where MariaDB reads those files. The private
key is mode `0600`, owned by the container's `mysql` user. Restarting or recreating the
container preserves these host files. The Go API uses
`DB_TLS=pinned` and validates the certificate SPKI against
`/run/secrets/mariadb.pem`. The service-admin client trust file and API pin must both
be updated for a key rotation; recreate the API container after replacing its mounted
pin file. Coordinate certificate changes with the API because a mismatched pin prevents
new database connections.

### Backup and migration sequence

Before schema changes, record the target schema and stop both API and maintenance
services from the server worktree:

~~~sh
cd /home/administrator/UPasswords/Cloud/api
docker compose stop api maintenance
~~~

Keep database backups outside the repository in the protected backup directory.
Production backups are run from `service-admin` with the installed
`/home/administrator/.local/bin/upasswords-db-backup` helper. The restricted SSH key
can invoke only fixed binlog, full-dump, TLS-material, and recovery-config operations on
`database-server`; it cannot open a shell or run arbitrary SQL. Full dumps use
`--single-transaction --master-data=2`, are gzip-tested before publication, and embed
the exact binlog recovery coordinate. The deployment account remains scoped to
`upasswords.*`; no global privilege was added for backups.

The schedule is versioned in `backup-production.crontab` and uses the service-admin
host's UTC+08:00 timezone. Full dumps run daily at 02:00 UTC, recovery key material
at 02:30 UTC, R2 object mirroring hourly, and closed binlogs every 15 minutes. Full
dump, binlog, R2, and key jobs have independent locks; R2 also shares the binlog lock
while it records its recovery coordinate and archives the covering logs. A long dump
cannot suppress the RPO-critical binlog job. Backups are retained locally for 30 days in the protected
backup root. MariaDB source binlogs expire after 10 days; the independent service-admin
archive retains them for 30 days. R2 deleted/replaced object versions are retained in
the mirror manifest for 30 days. Logs and backup files are private to the administrator.

The MariaDB TLS key remains at
`/data/mariadb/data/upasswords-server-key.pem` on the database host, mode `0600`,
inside the persistent host bind mount. The daily key job also verifies and stores the
matching certificate and private key under the protected service-admin backup root;
both files are mode `0600` and retained for 30 days.

Every R2 mirror writes `r2/current/database-checkpoint.tsv` only after the mirror and
all binlogs needed to reach its MariaDB coordinate are archived. The monthly
`restore-drill` cron job selects a full dump no newer than that checkpoint and replays
only through the checkpoint in an isolated, network-disabled temporary MariaDB using
tmpfs storage. The drill removes its temporary container and files on exit. It is a
smoke test, not proof of the four-hour RTO at production data volume; record the
checkpoint, selected dump, log coverage, integrity result, and elapsed time.

For a new or explicitly reset schema, apply the numbered SQL files from the
`service-admin` worktree in lexical order. For an existing schema, first determine
which migrations are already applied; do not blindly replay the entire directory or
assume that a successful SQL command is a migration record. The normal API process
does not run DDL. After applying migrations, verify the expected tables, columns and
views, run `CHECK TABLE`, then use the API image that matches those migrations:

~~~sh
cd /home/administrator/UPasswords/Cloud/api
docker compose run --rm --no-deps api check
docker compose up -d --no-build api
curl --fail --silent --show-error http://127.0.0.1:18080/health/ready
docker compose ps --all
~~~

Start `maintenance` only after confirming its image includes cleanup and retention
logic compatible with the schema. In particular, an older scheduler that only knows
`vault_items` must not run against profile data; the current schema also has versioned
attachments, conflict candidates and tombstones. Maintenance is single-deployment
only. Database reset/drop operations are destructive and require explicit user
authorization for that operation; prior authorization must not be treated as standing
permission. A reset applies only to `upasswords` and never implies deleting R2 objects
or unrelated databases.

### Operation record: 2026-10-27

With explicit authorization, `upasswords` was reset and migrations `0001` through
`0010` were applied from the service-admin worktree. The resulting schema has 22 base
tables and the `vault_sync_items` view; table checks passed. The database is currently
empty. The verified pre-reset dump is
`/home/administrator/.local/share/upasswords-db-backups/upasswords-pre-reset-final-20261027T052359Z.sql.gz`
(mode `0600`). R2 was not changed.

The API container was started and reported healthy; `/health/ready` returned HTTP 200
and the API `check` passed database/TLS, R2-read and SMTP checks. The maintenance
container remains stopped: its deployed image predates the current attachment-version
and conflict-retention maintenance logic. Before enabling maintenance, deploy and
verify a matching image. The deployed image at the time of this record was
`sha256:db73dedac4266ca3e254528038884e0a2566f77fa9201066a1a57d0bec76a72e`.

### Operation record: 2026-10-28

Replaced MariaDB's restart-generated in-memory TLS certificate with a persistent
self-signed certificate whose IP SAN is `10.0.3.198`. The private key is stored only in
the host bind-mounted file `/data/mariadb/data/upasswords-server-key.pem` with mode
`0600`; Docker exposes it to MariaDB at `/var/lib/mysql/upasswords-server-key.pem`.
The public certificate is installed as the service-admin CLI trust file and API SPKI
pin. The server configuration backup is
`/home/administrator/self-hosts/databases/mariadb/server.cnf.before-upw-tls-20261028T024003Z`.
Previous public pins are preserved in
`/home/administrator/.local/share/upasswords-db-backups/tls-rotation-20261028T024003Z`
(directory mode `0700`). No database rows, schema, or R2 objects were changed.

After recreating only the MariaDB and API containers, MariaDB reported healthy, the
CLI connected with both CA-chain and endpoint-name verification, and a wrong-CA test
failed as expected. API `check` verified database schema/TLS, R2 read access, and SMTP
TLS/authentication; `/health/ready` returned HTTP 200.

The service-admin API was rebuilt from its current worktree and deployed as image
`sha256:2f2ce3a6a267bcb3aac96f3234bb385733f8cd9ce9a4b261df2edc9579b90d4e`. The
previous image is retained as `upasswords-api:protocol5-before-r2-backup-20261028`.
The live `/v1/` capability endpoint reports sync protocol 5 and `/v2/` returns 404.
No production migration or database reset was run. The maintenance service was then
recreated from the same image and its 04:00 UTC scheduler started.

The production backup schedule is installed. A full dump at
`mysql-bin.000013:385`, all 18 subsequent archived binlog files through the latest
closed log, the R2 mirror manifest, and matching MariaDB TLS recovery material were
verified. An isolated restore drill restored the dump, replayed the archived binlogs,
checked 23 schema objects, and passed `mariadb-check` in 11 seconds. This was a
low-volume smoke test; it does not establish RTO at a representative production
dataset size. No production rows, schema, or R2 objects were changed by the rehearsal.

The checkpoint-aware backup helper, restricted binlog-coordinate command, and monthly
restore-drill schedule were installed on 2026-10-28. The R2 mirror published checkpoint
`mysql-bin.000022:385`; a subsequent isolated rehearsal selected the full dump at
`mysql-bin.000013`, replayed 10 archived binlogs through that checkpoint, verified 23
schema objects, and passed `mariadb-check` in 10 seconds. This verifies database
recovery through the R2 mirror coordinate for the current low-volume dataset. It does
not establish the four-hour RTO for production-scale data or a full service recovery.
