# Load test results — catalog & search API

Run on 2026-10-27 with `browse.js` (k6 1.0.0). Raw k6 output for each run is in `results/`.

## Setup

| | |
|---|---|
| Machine | Laptop, AMD Ryzen 5 5625U (6 cores / 12 threads), 32 GB RAM, Windows 11 + Docker Desktop |
| API | Production backend image (Node 24), **1 CPU and 512 MB per instance** |
| Load balancer | nginx 1.28, retries failed requests on another instance |
| Database | PostgreSQL 18, 5,005 providers, 16,028 offers (≈1,000 providers per service) |
| Load | 200 concurrent virtual users, no think time: 30 s ramp-up, **2 min at peak**, 15 s ramp-down |
| Journey | categories → services in a category → providers for a service (pages 1 and 2) → service details |

Everything ran on the same machine, including k6 itself.

## Results

"Sustained" = requests made during the 2 minutes at peak load.

| Run | Instances | Sustained req/s | Sustained p95 | Total requests | Failed |
|---|---|---|---|---|---|
| `1-instance` | 1 | **1,204.9** | 220.3 ms | 195,700 | **0** |
| `3-instances` | 3 | **1,982.4** | 252.5 ms | 323,430 | **0** |
| `failover` | 3 → 2 | 1,884.1 | 239.4 ms | 307,645 | **0** |

- **Scaling:** 3 instances served **1.65x** the throughput of 1 instance.
- **Failover:** 65 s into the run, at peak load, `api-2` was stopped with `docker stop`. Its
  graceful shutdown didn't finish within Docker's 10 s grace period, so it was force-killed
  (exit 137). nginx retried the affected requests on the remaining instances:
  **0 of 307,645 requests failed** and every check passed.

## Where the bottleneck is

CPU per container during the runs (`docker stats`, 100% = one core):

| Container | 1 instance | 3 instances |
|---|---|---|
| api (each) | 99% (at its 1-CPU limit) | 74–88% |
| postgres | 280% | **664%** |
| nginx | 32% | 56% |
| k6 | 86% | 135% |

With one instance, the API was the limit. With three, **PostgreSQL became the
bottleneck** (about 6.6 cores), so throughput didn't triple. Not profiled yet; the
likely cost is the per-service offer aggregates in `GET /api/services`. Next steps: cache the catalog
responses (they change rarely), precompute offer counts and price ranges, then
re-test.

## Known issue found

The API's graceful shutdown waits for nginx's idle keep-alive connections to close, so
`docker stop` hits its 10 s timeout and force-kills the container. Requests didn't fail
(nginx retried them), but the shutdown should close idle connections right away.
