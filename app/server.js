const express = require("express");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");

const SCHEMA_LOCK_KEY = 84729103;

function buildSslConfig() {
  if (process.env.DB_SSL === "false") {
    return false;
  }
  const caPath = process.env.DB_SSL_CA_PATH;
  if (caPath && fs.existsSync(caPath)) {
    return {
      ca: fs.readFileSync(caPath, "utf8"),
      rejectUnauthorized: true,
    };
  }
  return { rejectUnauthorized: false };
}

function createPgPool() {
  if (!process.env.DATABASE_URL) {
    return null;
  }
  const { Pool } = require("pg");
  const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: buildSslConfig(),
    max: 10,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 3000,
  });
  pool.on("error", (err) => {
    console.error("Unexpected PostgreSQL pool error:", err.message);
  });
  return pool;
}

function httpRequest(options, body = null) {
  return new Promise((resolve, reject) => {
    const req = http.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, data }));
    });
    req.setTimeout(500, () => req.destroy(new Error("timeout")));
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function fetchImdsMetadata() {
  try {
    const tokenRes = await httpRequest({
      host: "169.254.169.254",
      path: "/latest/api/token",
      method: "PUT",
      headers: { "X-aws-ec2-metadata-token-ttl-seconds": "60" },
    });
    const token = tokenRes.data;
    const headers = { "X-aws-ec2-metadata-token": token };
    const [idRes, azRes, typeRes] = await Promise.all([
      httpRequest({ host: "169.254.169.254", path: "/latest/meta-data/instance-id", method: "GET", headers }),
      httpRequest({ host: "169.254.169.254", path: "/latest/meta-data/placement/availability-zone", method: "GET", headers }),
      httpRequest({ host: "169.254.169.254", path: "/latest/meta-data/instance-type", method: "GET", headers }),
    ]);
    return {
      instanceId: idRes.data || os.hostname(),
      availabilityZone: azRes.data || process.env.AWS_AZ || "us-east-1a (local)",
      instanceType: typeRes.data || "t3.micro",
      imdsVersion: "IMDSv2",
    };
  } catch {
    return {
      instanceId: process.env.INSTANCE_ID || os.hostname(),
      availabilityZone: process.env.AWS_AZ || "us-east-1a (local)",
      instanceType: process.env.INSTANCE_TYPE || "t3.micro",
      imdsVersion: "local-fallback",
    };
  }
}

function createApp(options = {}) {
  const app = express();
  const startTime = Date.now();
  const pgPool = options.pgPool !== undefined ? options.pgPool : createPgPool();
  const metadataFetcher = options.metadataFetcher || fetchImdsMetadata;

  let dbInitialized = false;
  let schemaPromise = null;
  let memoryVisits = 0;

  async function ensureSchema() {
    if (!pgPool || dbInitialized) return;
    if (schemaPromise) return schemaPromise;

    schemaPromise = (async () => {
      const client = await pgPool.connect();
      try {
        // Serialize DDL across concurrent ASG instances booting simultaneously
        await client.query("SELECT pg_advisory_lock($1)", [SCHEMA_LOCK_KEY]);
        await client.query(`
          CREATE TABLE IF NOT EXISTS page_visits (
            id SERIAL PRIMARY KEY,
            instance_id TEXT NOT NULL,
            availability_zone TEXT NOT NULL,
            visited_at TIMESTAMPTZ DEFAULT NOW()
          );
        `);
        dbInitialized = true;
      } finally {
        await client.query("SELECT pg_advisory_unlock($1)", [SCHEMA_LOCK_KEY]).catch(() => {});
        client.release();
      }
    })().finally(() => {
      schemaPromise = null;
    });

    return schemaPromise;
  }

  async function initDbWithRetry(retries = 10, delayMs = 3000) {
    if (!pgPool) return;
    for (let attempt = 1; attempt <= retries; attempt++) {
      try {
        await ensureSchema();
        console.log("RDS PostgreSQL connected and schema verified.");
        return;
      } catch (err) {
        console.warn(`RDS connection attempt ${attempt}/${retries} failed: ${err.message}`);
        if (attempt < retries) {
          await new Promise((r) => setTimeout(r, delayMs));
        }
      }
    }
  }

  app.use(express.json());
  app.use(
    "/static",
    express.static(path.join(__dirname, "public"), {
      maxAge: "1d",
      immutable: true,
    })
  );

  // ALB Target Group health check — verifies actual PostgreSQL connectivity without exposing internals
  app.get("/health", async (_req, res) => {
    let dbStatus = "in-memory-fallback";
    if (pgPool) {
      try {
        await ensureSchema();
        await pgPool.query("SELECT 1");
        dbStatus = "connected";
      } catch (err) {
        console.error("Health check database failure:", err.message);
        return res.status(503).json({ status: "unhealthy", database: "unavailable" });
      }
    }
    res.status(200).json({
      status: "healthy",
      database: dbStatus,
      uptimeSeconds: Math.floor((Date.now() - startTime) / 1000),
    });
  });

  app.get("/api/status", async (_req, res) => {
    const meta = await metadataFetcher();
    let totalVisits = memoryVisits;
    let dbMode = "In-Memory Fallback";

    if (pgPool) {
      try {
        await ensureSchema();
        await pgPool.query(
          "INSERT INTO page_visits (instance_id, availability_zone) VALUES ($1, $2)",
          [meta.instanceId, meta.availabilityZone]
        );
        const countRes = await pgPool.query("SELECT COUNT(*)::int AS total FROM page_visits");
        totalVisits = countRes.rows[0].total;
        dbMode = "Amazon RDS PostgreSQL (Multi-AZ)";
      } catch (err) {
        console.error("Status endpoint database failure:", err.message);
        dbMode = "RDS unavailable";
      }
    } else {
      memoryVisits += 1;
      totalVisits = memoryVisits;
    }

    res.json({
      service: "CloudPulse Web App",
      ...meta,
      database: dbMode,
      totalVisits,
      uptimeSeconds: Math.floor((Date.now() - startTime) / 1000),
      timestamp: new Date().toISOString(),
    });
  });

  app.get("/", (_req, res) => {
    res.sendFile(path.join(__dirname, "public", "index.html"));
  });

  return { app, pgPool, initDbWithRetry };
}

if (require.main === module) {
  const PORT = parseInt(process.env.PORT || "8080", 10);
  const { app, pgPool, initDbWithRetry } = createApp();
  const server = app.listen(PORT, "0.0.0.0", () => {
    console.log(`CloudPulse listening on port ${PORT}`);
    initDbWithRetry().catch((err) => console.error("DB init error:", err.message));
  });

  function shutdown(signal) {
    console.log(`Received ${signal}; draining HTTP connections...`);
    server.close(async () => {
      if (pgPool) await pgPool.end().catch(() => {});
      process.exit(0);
    });
  }

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

module.exports = { createApp };
