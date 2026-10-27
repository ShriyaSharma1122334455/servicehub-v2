# Load testing

k6 load test of the ServiceHub **catalog and search API** (the browse journey every
customer starts with), running against the production backend image behind an nginx
load balancer.

```
k6 ──► nginx (lb, :8080) ──► api × N (production image, 1 CPU each) ──► PostgreSQL
```

| File | What it is |
|---|---|
| `browse.js` | k6 scenario: categories → services in a category → providers for a service (2 pages) → service details |
| `nginx.conf` | Load balancer: spreads requests over every `api` container, retries on another one if an instance fails |
| `results/` | One JSON file per run (`<RUN_NAME>.json`) with every metric k6 recorded |

The `api`, `lb` and `k6` services are in `compose.yaml` under the `loadtest` profile,
so a normal `docker compose up` doesn't start them.

Latest numbers: [RESULTS.md](RESULTS.md).

## Running it

From the project root, in PowerShell (Git Bash rewrites `/scripts/...` paths; prefix
commands with `MSYS_NO_PATHCONV=1` there).

1. Database with the load-test data:
   ```powershell
   docker compose up -d postgres
   cd backend; npm run db:reset; npm run db:seed:loadtest; cd ..
   ```
2. Stop the dev backend so it doesn't compete for CPU: `docker compose stop backend`
3. Start N API instances behind nginx (here 1), then run k6:
   ```powershell
   docker compose --profile loadtest up -d --build --scale api=1 lb
   docker compose --profile loadtest run --rm --no-deps k6 run -e RUN_NAME=1-instance /scripts/browse.js
   ```
4. Repeat with `--scale api=3` and `RUN_NAME=3-instances`.
5. Failover: start a run with `RUN_NAME=failover` and, about a minute in, run
   `docker stop servicehub-api-2` in a second terminal.
6. Clean up: `docker compose --profile loadtest down`

**Always pass `--no-deps` to `docker compose run`.** Without it, Compose restarts the
services k6 depends on and quietly scales `api` back to 1 instance mid-test.

## What's measured

At the end of each run k6 prints its full summary, followed by:

```
── 3-instances ─────────────────────────────
sustained requests/sec (at peak): …
sustained p95 response time:      … ms
peak concurrent users:            …
total requests (whole run):       …
failed requests (whole run):      … (…%)
```

- **Sustained** numbers only count requests made while holding peak load (after the
  30 s ramp-up, before the ramp-down).
- **Failed requests** count the whole run: any status ≥ 400 or a connection error.
- Each VU repeats the journey with no pause (`THINK_MS=0`), which measures the
  maximum capacity of the setup. Use `-e THINK_MS=500` for a more human pace.
- Thresholds: zero failed requests, p95 under 500 ms, every check passing. k6
  exits with an error if any threshold is crossed.

## Environment notes

Everything (k6, nginx, the API instances and PostgreSQL) runs on one machine, so the
load generator competes with the system under test for CPU. Absolute numbers are
lower than on separate servers; report the machine you ran on alongside them.
Each `api` instance is limited to 1 CPU so that 1 vs 3 instances is a fair comparison.
The damage-assessment, AI and payment services are not part of this test.
