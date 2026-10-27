# Load test (SOLAR-209)

How many inverters the database carries before it struggles. Runs against a
throwaway Postgres in Docker, capped like Supabase Micro. Never prod: the
database container sits on a Docker network with no internet.

## Start

```bash
docker network create --internal solar-loadtest-net
docker run -d --name solar-loadtest-db --network solar-loadtest-net --memory=1g --memory-swap=2g --cpus=2 -e POSTGRES_PASSWORD=loadtest public.ecr.aws/supabase/postgres:17.6.1.155 postgres -c config_file=/etc/postgresql/postgresql.conf -c shared_buffers=256MB -c max_connections=60 -c effective_cache_size=768MB -c work_mem=2184kB -c maintenance_work_mem=64MB
docker run -d --name solar-loadtest-client --network solar-loadtest-net -e PGPASSWORD=loadtest --entrypoint sleep public.ecr.aws/supabase/postgres:17.6.1.155 infinity
```

Then apply `supabase/migrations/*.sql` in order with
`docker exec -i solar-loadtest-db psql -U postgres -v ON_ERROR_STOP=1 < file`.
The bare image's `auth.users` lacks `email_confirmed_at`, `deleted_at`,
`is_anonymous` and `banned_until` (0085, 0092): add them as `supabase_admin` first. After the migrations, split the month partition into days
(`call private.rollup_old_days(31)`), then load `load-test/setup.sql`.

## Run

```bash
load-test/step.sh 50 10 /path/to/results
```

`step.sh` grows the fake fleet to N inverters (two per plant, one login per plant),
fills today so far for every fake plant, then `run.mjs` writes one minute per
inverter per minute through the same RPCs `poll` calls, with 2 shards and 10
connections. Each minute it logs batch time, page reader times for plant 900001
(31 days of history) and the container's CPU, memory and swap.

Struggling = a minute batch over 30 s, a page reader over 1 s, or any swap.

## Part 2: poll function and many owners (SOLAR-210)

Adds the web API (PostgREST), the real function runtime and a fake SunSynk.

1. Make a JWT secret, then a service key: `node load-test/jwt.mjs <secret> service_role`.
2. Replace `auth.uid()` (as `supabase_admin`) so it also reads `request.jwt.claims`,
   which PostgREST sets.
3. `docker network create solar-loadtest-edge`, then run
   `public.ecr.aws/supabase/postgrest:v14.15` on it with `-p 127.0.0.1:54401:3000`,
   `PGRST_DB_URI=postgres://authenticator:<pw>@solar-loadtest-db:5432/postgres`,
   `PGRST_JWT_SECRET`, `PGRST_DB_POOL=10`, and connect it to `solar-loadtest-net`.
   Give `authenticator` that password first.
4. `LATENCY_MS=300 node load-test/stack.mjs`: fake SunSynk on :4400, `/rest/v1`
   proxy on :54400.
5. Run `public.ecr.aws/supabase/edge-runtime:v1.77.1 start --main-service
   /home/deno/main -p 9000` on `solar-loadtest-edge`, `-p 127.0.0.1:54402:9000`,
   with `supabase/functions` mounted at `/home/deno/functions`, `edge-main.ts` at
   `/home/deno/main/index.ts`, `SUPABASE_URL=http://host.docker.internal:54400`,
   `SUPABASE_SERVICE_ROLE_KEY`, `SUNSYNK_API_BASE=http://host.docker.internal:4400`,
   `CPU_LIMIT_MS=2000`. Point SunSynk, PostHog, Resend and the prod project's host
   names at 127.0.0.1 with `--add-host`, so nothing can reach them.

Then:

```bash
load-test/poll-cpu.sh <service-key-file> 50 100 250 500 1000
node load-test/pages.mjs <jwt-secret-file> 10 50 100 250   # while step.sh runs
```

## Stop

```bash
docker rm -f solar-loadtest-db solar-loadtest-client solar-loadtest-rest solar-loadtest-edge
docker network rm solar-loadtest-net solar-loadtest-edge
```
