const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { createApp } = require("../server");

function startTestServer(options) {
  const { app } = createApp(options);
  return new Promise((resolve) => {
    const server = app.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({ server, baseUrl: `http://127.0.0.1:${port}` });
    });
  });
}

function createMockPool({ healthy = true } = {}) {
  let visits = 0;
  const queries = [];
  const client = {
    async query(sql, params) {
      queries.push({ sql: sql.trim(), params });
      if (!healthy && sql.includes("CREATE TABLE")) {
        throw new Error("password authentication failed for user secret_leak");
      }
      return { rows: [] };
    },
    release() {},
  };
  return {
    queries,
    async connect() {
      if (!healthy) {
        throw new Error("connection refused to internal-rds-host:5432");
      }
      return client;
    },
    async query(sql, params) {
      queries.push({ sql: sql.trim(), params });
      if (!healthy) {
        throw new Error("connection refused to internal-rds-host:5432");
      }
      if (sql.startsWith("INSERT INTO page_visits")) {
        visits += 1;
        return { rows: [] };
      }
      if (sql.includes("COUNT(*)")) {
        return { rows: [{ total: visits }] };
      }
      return { rows: [{ "?column?": 1 }] };
    },
    async end() {},
  };
}

const mockMeta = async () => ({
  instanceId: "i-test12345",
  availabilityZone: "us-east-1a",
  instanceType: "t3.micro",
  imdsVersion: "IMDSv2",
});

test("GET /health returns 200 in fallback mode when DATABASE_URL is unset", async () => {
  const { server, baseUrl } = await startTestServer({ pgPool: null, metadataFetcher: mockMeta });
  try {
    const res = await fetch(`${baseUrl}/health`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, "healthy");
    assert.equal(body.database, "in-memory-fallback");
  } finally {
    server.close();
  }
});

test("GET /health uses advisory lock and returns 200 connected with healthy pool", async () => {
  const pool = createMockPool({ healthy: true });
  const { server, baseUrl } = await startTestServer({ pgPool: pool, metadataFetcher: mockMeta });
  try {
    const res = await fetch(`${baseUrl}/health`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, "healthy");
    assert.equal(body.database, "connected");
    assert.ok(pool.queries.some((q) => q.sql.includes("pg_advisory_lock")));
    assert.ok(pool.queries.some((q) => q.sql.includes("pg_advisory_unlock")));
  } finally {
    server.close();
  }
});

test("GET /health returns 503 without leaking raw DB errors when database fails", async () => {
  const pool = createMockPool({ healthy: false });
  const { server, baseUrl } = await startTestServer({ pgPool: pool, metadataFetcher: mockMeta });
  try {
    const res = await fetch(`${baseUrl}/health`);
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.status, "unhealthy");
    assert.equal(body.database, "unavailable");
    assert.ok(!JSON.stringify(body).includes("internal-rds-host"));
  } finally {
    server.close();
  }
});

test("GET /api/status persists visits in PostgreSQL and queries total", async () => {
  const pool = createMockPool({ healthy: true });
  const { server, baseUrl } = await startTestServer({ pgPool: pool, metadataFetcher: mockMeta });
  try {
    const r1 = await (await fetch(`${baseUrl}/api/status`)).json();
    const r2 = await (await fetch(`${baseUrl}/api/status`)).json();
    assert.equal(r1.totalVisits, 1);
    assert.equal(r2.totalVisits, 2);
    assert.equal(r2.database, "Amazon RDS PostgreSQL (Multi-AZ)");
    assert.equal(r2.instanceId, "i-test12345");
    assert.equal(r2.imdsVersion, "IMDSv2");
  } finally {
    server.close();
  }
});

test("GET / and /static/styles.css serve frontend assets with cache headers", async () => {
  const { server, baseUrl } = await startTestServer({ pgPool: null, metadataFetcher: mockMeta });
  try {
    const htmlRes = await fetch(`${baseUrl}/`);
    assert.equal(htmlRes.status, 200);
    const html = await htmlRes.text();
    assert.ok(html.includes("CloudPulse"));

    const cssRes = await fetch(`${baseUrl}/static/styles.css`);
    assert.equal(cssRes.status, 200);
    assert.ok((cssRes.headers.get("cache-control") || "").includes("max-age="));
  } finally {
    server.close();
  }
});
