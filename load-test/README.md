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
0085 needs `auth.users.email_confirmed_at`, which the bare image lacks: add it as
`supabase_admin` first. After the migrations, split the month partition into days
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

## Stop

```bash
docker rm -f solar-loadtest-db solar-loadtest-client
docker network rm solar-loadtest-net
```
