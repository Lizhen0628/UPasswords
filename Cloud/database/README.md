# Database schema and migrations

`0001_init.sql` is the canonical initializer for the current MariaDB schema. The Go
API does not create or migrate production tables at startup; database administrators
apply SQL from this directory using a privileged deployment account. The API's
runtime account must remain limited to application data operations.

`0002_user_profiles.sql` preserves the additive encrypted-profile migration from
the server worktree. It creates a dedicated kind=3 table and a combined sync view.
The profile-capable Go handlers are separate, uncommitted server work; this file
does not mean those handlers have been released. Apply it only with the matching
API release and a verified backup.

Add future changes as ordered files such as `0003_add_example.sql`. Once a migration
has been applied to a shared or production database, treat it as immutable and add a
new migration for corrections. Before applying a migration, verify it against a
backup and the API version that will consume the resulting schema. Never put database
credentials or production data in this directory.

The isolated Go integration test creates its disposable `_test` database from
`0001_init.sql`. If a later migration becomes required by application code, update
the test bootstrap to apply the migration sequence before relying on it in production.
