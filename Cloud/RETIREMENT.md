# Worker retirement — 2026-10-24

The production entry remains Cloudflare → Nginx → Go API. The removed Worker is
no longer a recovery target. The current development release policy permits clearing incompatible test data
and rebuilding the current schema without a backup or restore rehearsal, as
described in [api/README.md](api/README.md). Review recovery requirements before
accepting real user data.

## Verified resources and actions

| Resource | Observed state and action |
|---|---|
| Worker `upasswords-sync` | No custom domains or routes; workers.dev disabled; no Cron, queue or email triggers; no invocations in the displayed 24-hour period. Removed from Workers & Pages. |
| Worker binding `DB` | Pointed to Hyperdrive `upasswords-db`; removed with the Worker. |
| Hyperdrive `upasswords-db` | Inactive and no queries in the displayed 24-hour period. Dedicated configuration deleted. |
| Worker binding `VAULTS` | Pointed to R2 `upasswords`; binding removed with the Worker, bucket retained for Go API attachments and catalog icons. |
| Tunnel `upasswords-db` | Only published `dbt.upasswords.com`. The connector on `database-server` was stopped, restart policy set to `no`, and its Compose service put behind the `retired-worker` profile. Tunnel configuration and Access protection retained for recovery. |
| D1 `upasswords-sync` | Retained: read-only counts found 2 users, 2 email codes, 4 sessions, 1 vault and 56 audit records. This is historical data and must not be treated as an empty database. |
| DNS, TLS/WAF and other projects | Production API protection and unrelated resources retained. |

The dedicated connector is managed in
`database-server:/home/administrator/self-hosts/cloudflare/docker-compose.yml`.
Its prior Compose file is saved beside it with the suffix `.before-worker-retirement`.
Re-enabling this retired path requires deliberately enabling the `retired-worker`
profile and starting the connector; it is not part of normal API rollback.

After stopping the connector, `/v1/` returned the expected capability document and
the running Go image's `check` command passed database TLS/schema, existing key
compatibility, R2 read access and SMTP authentication without sending mail.
These checks do not deploy a new Go image.

## Repository and server worktree

The Worker source, npm lockfile, Wrangler configuration and Worker-only CI job are
removed. Database files live in `Cloud/database/`. [TESTING.md](TESTING.md) maps the
retired behavioral tests to Go regression tests and records the plain-text email
implementation boundary.

The follow-up profile integration brings the profile-capable Go handlers into
version control with the canonical `0002_user_profiles.sql` migration. Tests apply
the numbered migration sequence directly. The duplicate embedded SQL and temporary
runtime migration command have been removed. A rollout requires an explicit database migration and matching Go image deployment.
The production database is not disposable. Any reset requires separate explicit
authorization, a verified backup, and a recovery rehearsal appropriate to the change.
Current backup jobs and the small-data restore smoke test do not by themselves prove
the production-scale RTO target.
