# Go API Deployment

The `/v2` API runs on the Hong Kong origin. Nginx runs in the existing `nginxui`
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
installed in Nginx. To roll back, point the proxied API DNS record back to its previous
Worker target, restore the Worker custom-domain route in Cloudflare, and re-enable its
04:00 UTC schedule before stopping this Compose stack.
