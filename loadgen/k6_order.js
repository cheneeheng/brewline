import http from "k6/http";
import { check } from "k6";

// Two scenarios, selected via -e SCENARIO=steady|spike (ITER_04).
//   steady : constant-arrival-rate baseline
//   spike  : ramping-arrival-rate, used by experiment #3 (collector backpressure)
const SCENARIO = __ENV.SCENARIO || "steady";
const BASE = __ENV.STOREFRONT_URL || "http://localhost:8000";

const SKUS = [
  { sku: "ESP-001", name: "Espresso", price: "3.00" },
  { sku: "LAT-001", name: "Latte", price: "4.50" },
  { sku: "CAP-001", name: "Cappuccino", price: "4.25" },
  { sku: "AME-001", name: "Americano", price: "3.50" },
  { sku: "MOC-001", name: "Mocha", price: "5.00" },
  { sku: "COL-001", name: "Cold Brew", price: "4.75" },
];

const scenarios = {
  steady: {
    executor: "constant-arrival-rate",
    rate: 10,
    timeUnit: "1s",
    duration: "5m",
    preAllocatedVUs: 20,
    maxVUs: 100,
  },
  spike: {
    executor: "ramping-arrival-rate",
    startRate: 5,
    timeUnit: "1s",
    preAllocatedVUs: 50,
    maxVUs: 400,
    stages: [
      { target: 5, duration: "30s" },
      { target: 250, duration: "1m" },
      { target: 5, duration: "30s" },
    ],
  },
};

export const options = {
  scenarios: { [SCENARIO]: scenarios[SCENARIO] },
};

export default function () {
  const item = SKUS[Math.floor(Math.random() * SKUS.length)];
  const qty = 1 + Math.floor(Math.random() * 3);
  const payload = JSON.stringify({
    items: [{ sku: item.sku, name: item.name, qty, unit_price: item.price }],
  });
  const res = http.post(`${BASE}/orders`, payload, {
    headers: { "Content-Type": "application/json" },
  });
  check(res, { "order accepted (202)": (r) => r.status === 202 });
}
