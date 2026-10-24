# Database schema and migrations

`0001_init.sql` is the canonical initializer for the current MariaDB schema. The Go
API does not create or migrate production tables at startup; database administrators
apply SQL from this directory using a privileged deployment account. The API's
runtime account must remain limited to application data operations.

`0002_user_profiles.sql` adds the dedicated kind=3 ciphertext table and the
`vault_sync_items` view used by Go handlers for snapshots, deltas, quotas and
rekey. Apply both scripts in order for a new database. An existing database with
`0001` already applied needs only `0002` before starting this API version.
The API never executes DDL; its `check` command requires the table and view.

Add future changes as ordered files such as `0003_add_example.sql`. Once a migration
has been applied to a shared or production database, treat it as immutable and add a
new migration for corrections. Before applying a migration, verify it against a
backup and the API version that will consume the resulting schema. Never put database
credentials or production data in this directory.

The isolated Go integration tests apply all numbered SQL files in lexical order
from this directory. They replay the sequence on disposable databases and verify
that existing encrypted rows survive. Keep four-digit prefixes to preserve order.
