// k6 load test: customers browsing the ServiceHub catalog.
//
// Each virtual user (VU) repeats a browse journey:
//   categories → services in a category → providers for a service (2 pages)
//   → service details
//
// Run through Docker Compose (see loadtest/README.md):
//   docker compose --profile loadtest run --rm k6 run -e RUN_NAME=1-instance /scripts/browse.js
//
// Options (pass with -e NAME=value):
//   VUS       peak concurrent users          (default 200)
//   HOLD      how long to hold the peak       (default 2m)
//   THINK_MS  pause between requests, in ms   (default 0 = measure max capacity)
//   RUN_NAME  label for the results file      (default "run")

import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://lb';
const VUS      = Number(__ENV.VUS || 200);
const HOLD     = __ENV.HOLD || '2m';
const THINK_MS = Number(__ENV.THINK_MS || 0);
const RUN_NAME = __ENV.RUN_NAME || 'run';

// '90s' / '2m' → milliseconds
const toMs = (d) => Number.parseFloat(d) * (d.endsWith('m') ? 60000 : 1000);
const RAMP_UP = '30s';
const HOLD_START_MS = toMs(RAMP_UP);
const HOLD_END_MS   = HOLD_START_MS + toMs(HOLD);

// "Sustained" metrics only count requests made while holding peak load,
// so the ramp-up and ramp-down don't drag the averages down.
const sustainedReqs     = new Counter('sustained_reqs');
const sustainedDuration = new Trend('sustained_req_duration', true);
const sustainedFailed   = new Rate('sustained_req_failed');

const inHoldWindow = () => {
  const t = exec.instance.currentTestRunDuration;
  return t >= HOLD_START_MS && t < HOLD_END_MS;
};

const CATEGORY_IDS = [1, 2, 3, 4];
// Fallback if a services response is empty: one service per category.
const FALLBACK_SERVICE_IDS = { 1: 102, 2: 201, 3: 301, 4: 401 };

export const options = {
  scenarios: {
    browse: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: RAMP_UP, target: VUS }, // ramp up
        { duration: HOLD,  target: VUS },   // sustain peak load
        { duration: '15s', target: 0 },     // ramp down
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_failed:   ['rate==0'],     // zero failed requests
    http_req_duration: ['p(95)<500'],   // 95% of requests under 500 ms
    checks:            ['rate==1'],     // every response was correct
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const pick = (list) => list[Math.floor(Math.random() * list.length)];
const think = () => { if (THINK_MS > 0) sleep(THINK_MS / 1000); };

// `name` tags group URLs with different IDs into one row in the results.
const get = (path, name) => {
  const res = http.get(`${BASE_URL}${path}`, { tags: { name } });
  if (inHoldWindow()) {
    sustainedReqs.add(1);
    sustainedDuration.add(res.timings.duration);
    sustainedFailed.add(res.status === 0 || res.status >= 400);
  }
  return res;
};

export default function () {
  const categories = get('/api/categories', 'GET /api/categories');
  check(categories, { 'categories 200': (r) => r.status === 200 });
  think();

  const categoryId = pick(CATEGORY_IDS);
  const services = get(`/api/services?category=${categoryId}`, 'GET /api/services?category');
  check(services, { 'services 200': (r) => r.status === 200 });
  think();

  let serviceId = FALLBACK_SERVICE_IDS[categoryId];
  if (services.status === 200) {
    const list = services.json('data') || [];
    if (list.length > 0) serviceId = pick(list).id;
  }

  const providers = get(`/api/providers/by-service/${serviceId}?limit=20`, 'GET /api/providers/by-service');
  check(providers, {
    'providers 200':      (r) => r.status === 200,
    'providers has rows': (r) => r.status === 200 && (r.json('count') || 0) > 0,
  });
  think();

  const nextPage = get(`/api/providers/by-service/${serviceId}?limit=20&page=2`, 'GET /api/providers/by-service');
  check(nextPage, { 'providers page 2 200': (r) => r.status === 200 });
  think();

  const detail = get(`/api/services/${serviceId}`, 'GET /api/services/:id');
  check(detail, { 'service detail 200': (r) => r.status === 200 });
  think();
}

// Print the normal k6 summary, save the raw numbers, and print the four
// numbers the resume bullet needs.
export function handleSummary(data) {
  const m = data.metrics;
  const holdSeconds   = toMs(HOLD) / 1000;
  const sustainedRps  = (m.sustained_reqs?.values.count ?? 0) / holdSeconds;
  const sustainedP95  = m.sustained_req_duration?.values['p(95)'] ?? NaN;
  const failedAll     = m.http_req_failed.values.rate;
  const failedCount   = m.http_req_failed.values.passes;   // "passes" = requests that failed
  const peakVus       = m.vus_max.values.max;
  const requests      = m.http_reqs.values.count;

  const headline = [
    '',
    `── ${RUN_NAME} ────────────────────────────────────────`,
    `sustained requests/sec (at peak): ${sustainedRps.toFixed(1)}`,
    `sustained p95 response time:      ${sustainedP95.toFixed(1)} ms`,
    `peak concurrent users:            ${peakVus}`,
    `total requests (whole run):       ${requests}`,
    `failed requests (whole run):      ${failedCount} (${(failedAll * 100).toFixed(2)}%)`,
    '',
  ].join('\n');

  return {
    stdout: textSummary(data, { indent: ' ', enableColors: true }) + headline,
    [`/scripts/results/${RUN_NAME}.json`]: JSON.stringify(data, null, 2),
  };
}
