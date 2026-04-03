# Industream CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Node.js CLI (`industream`) that installs, monitors, and manages the Industream platform with a live terminal UI.

**Architecture:** CLI + Repo pattern — the CLI binary orchestrates the `industream-swarm` repo (cloned to `~/industream-platform/`) via shell commands (`execa`) and Docker APIs. Distributed as a Node SEA binary.

**Tech Stack:** TypeScript, Ink (React TUI), Commander, execa, jose (JWT), semver

**Spec:** `docs/specs/2026-04-03-industream-cli-design.md`

**Repo:** `industream/industream-cli` (to be created on GitHub)

---

## Phase 1: Project Scaffold + Core Libraries

### Task 1: Initialize project and install dependencies

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `src/index.ts`
- Create: `.gitignore`
- Create: `CLAUDE.md`

- [ ] **Step 1: Create GitHub repo and clone**

```bash
gh repo create industream/industream-cli --public --clone
cd industream-cli
```

- [ ] **Step 2: Initialize Node.js project**

```bash
npm init -y
```

- [ ] **Step 3: Install dependencies**

```bash
npm install ink ink-table react commander execa jose semver
npm install -D typescript @types/react @types/node tsx vitest
```

- [ ] **Step 4: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "jsxImportSource": "react",
    "strict": true,
    "esModuleInterop": true,
    "outDir": "dist",
    "rootDir": "src",
    "declaration": true,
    "sourceMap": true,
    "resolveJsonModule": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

- [ ] **Step 5: Create entry point src/index.ts**

```typescript
#!/usr/bin/env node
import { Command } from "commander";

const program = new Command();

program
  .name("industream")
  .description("Industream Platform CLI")
  .version("0.1.0");

program.parse();
```

- [ ] **Step 6: Update package.json scripts and bin**

Add to `package.json`:
```json
{
  "type": "module",
  "bin": {
    "industream": "./dist/index.js"
  },
  "scripts": {
    "dev": "tsx src/index.ts",
    "build": "tsc",
    "test": "vitest run",
    "test:watch": "vitest"
  }
}
```

- [ ] **Step 7: Create .gitignore**

```
node_modules/
dist/
*.license
.industream/
```

- [ ] **Step 8: Create CLAUDE.md**

```markdown
# CLAUDE.md — Industream CLI

## Stack
- TypeScript + Ink (React TUI) + Commander
- Tests: Vitest
- Build: Node SEA (Single Executable Application)

## Commands
- `npm run dev -- <command>` to run in dev mode
- `npm test` to run tests
- `npm run build` to compile TypeScript

## Code Style
- All code in English
- Use `const` by default, early returns, max 30 lines per function
- Follow existing patterns in src/lib/ for new modules
```

- [ ] **Step 9: Verify it runs**

Run: `npm run dev -- --help`
Expected: Shows "Industream Platform CLI" with version 0.1.0

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: initialize industream-cli project with TypeScript + Ink"
git push -u origin main
```

---

### Task 2: Config module (`src/lib/config.ts`)

**Files:**
- Create: `src/lib/config.ts`
- Create: `src/lib/config.test.ts`

- [ ] **Step 1: Write failing test for config module**

```typescript
// src/lib/config.test.ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig, saveConfig, getConfigDir, type IndustreamConfig } from "./config.js";

describe("config", () => {
  let tempDir: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "industream-test-"));
  });

  afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
  });

  it("returns default config when no file exists", async () => {
    const config = await loadConfig(tempDir);
    expect(config.platformDir).toBe("~/industream-platform");
    expect(config.defaultEnvironment).toBe("prod");
  });

  it("saves and loads config", async () => {
    const config: IndustreamConfig = {
      platformDir: "/opt/industream",
      defaultEnvironment: "dev",
      domain: "test.industream.lan",
    };
    await saveConfig(config, tempDir);
    const loaded = await loadConfig(tempDir);
    expect(loaded.domain).toBe("test.industream.lan");
    expect(loaded.defaultEnvironment).toBe("dev");
  });

  it("creates config directory if missing", async () => {
    const nested = join(tempDir, "nested", ".industream");
    await saveConfig({ platformDir: "~/industream-platform", defaultEnvironment: "prod" }, nested);
    const loaded = await loadConfig(nested);
    expect(loaded.platformDir).toBe("~/industream-platform");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/lib/config.test.ts`
Expected: FAIL — cannot find module `./config.js`

- [ ] **Step 3: Implement config module**

```typescript
// src/lib/config.ts
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

export interface IndustreamConfig {
  platformDir: string;
  defaultEnvironment: string;
  domain?: string;
  registryUrl?: string;
}

const DEFAULT_CONFIG: IndustreamConfig = {
  platformDir: "~/industream-platform",
  defaultEnvironment: "prod",
};

const CONFIG_FILE = "config.json";

export function getConfigDir(): string {
  return join(homedir(), ".industream");
}

export async function loadConfig(configDir?: string): Promise<IndustreamConfig> {
  const directory = configDir ?? getConfigDir();
  const filePath = join(directory, CONFIG_FILE);
  try {
    const content = await readFile(filePath, "utf-8");
    return { ...DEFAULT_CONFIG, ...JSON.parse(content) };
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

export async function saveConfig(
  config: IndustreamConfig,
  configDir?: string,
): Promise<void> {
  const directory = configDir ?? getConfigDir();
  await mkdir(directory, { recursive: true });
  const filePath = join(directory, CONFIG_FILE);
  await writeFile(filePath, JSON.stringify(config, null, 2));
}
```

- [ ] **Step 4: Run tests**

Run: `npx vitest run src/lib/config.test.ts`
Expected: 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/lib/config.ts src/lib/config.test.ts
git commit -m "feat: add config module with load/save and defaults"
```

---

### Task 3: Module registry (`src/lib/modules.ts`)

**Files:**
- Create: `modules.json`
- Create: `src/lib/modules.ts`
- Create: `src/lib/modules.test.ts`

- [ ] **Step 1: Create modules.json from the Excel registry**

Create `modules.json` at project root with all modules from `Industream_Module_License_Registry_Pricing 2026.xlsx`. Include only platform-deployable modules (not hardware, not domain process packages for MVP).

Structure per module:
```json
{
  "modules": [
    {
      "id": "industream-core",
      "name": "Industream core",
      "category": "Platform",
      "license": "bsl",
      "status": "ready",
      "serviceName": "flowmaker-scheduler",
      "stackFile": "docker-stack.flowmaker.yml"
    },
    {
      "id": "opc-ua-connector",
      "name": "OPC-UA connector",
      "category": "DataBridge — live connectors",
      "license": "proprietary",
      "status": "ready",
      "serviceName": "worker-opc-ua-client",
      "stackFile": "docker-stack.workers.yml",
      "imagePattern": "flowmaker.boxes/flow-box-opc-ua-client"
    }
  ]
}
```

- [ ] **Step 2: Write failing tests**

```typescript
// src/lib/modules.test.ts
import { describe, it, expect } from "vitest";
import {
  loadModuleRegistry,
  getModulesByLicense,
  isModuleLicensed,
  type Module,
} from "./modules.js";

describe("modules", () => {
  it("loads module registry", () => {
    const registry = loadModuleRegistry();
    expect(registry.modules.length).toBeGreaterThan(0);
  });

  it("filters modules by license type", () => {
    const registry = loadModuleRegistry();
    const bslModules = getModulesByLicense(registry, "bsl");
    const proprietaryModules = getModulesByLicense(registry, "proprietary");
    expect(bslModules.length).toBeGreaterThan(0);
    expect(proprietaryModules.length).toBeGreaterThan(0);
    expect(bslModules.every((m) => m.license === "bsl")).toBe(true);
  });

  it("checks if a module is licensed for community plan", () => {
    const registry = loadModuleRegistry();
    expect(isModuleLicensed(registry, "industream-core", "community")).toBe(true);
    expect(isModuleLicensed(registry, "opc-ua-connector", "community")).toBe(false);
  });

  it("checks if a module is licensed for enterprise plan", () => {
    const registry = loadModuleRegistry();
    expect(isModuleLicensed(registry, "opc-ua-connector", "enterprise")).toBe(true);
  });
});
```

- [ ] **Step 3: Implement modules module**

```typescript
// src/lib/modules.ts
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

export interface Module {
  id: string;
  name: string;
  category: string;
  license: "bsl" | "proprietary" | "apache";
  status: "ready" | "coming-soon" | "under-test" | "on-request";
  serviceName?: string;
  stackFile?: string;
  imagePattern?: string;
}

export interface ModuleRegistry {
  modules: Module[];
}

export function loadModuleRegistry(): ModuleRegistry {
  return require("../../modules.json") as ModuleRegistry;
}

export function getModulesByLicense(
  registry: ModuleRegistry,
  license: Module["license"],
): Module[] {
  return registry.modules.filter((m) => m.license === license);
}

export type Plan = "community" | "trial" | "pro" | "enterprise";

export function isModuleLicensed(
  registry: ModuleRegistry,
  moduleId: string,
  plan: Plan,
  licensedModuleIds?: string[],
): boolean {
  const module = registry.modules.find((m) => m.id === moduleId);
  if (!module) return false;

  if (module.license === "bsl" || module.license === "apache") return true;
  if (plan === "enterprise" || plan === "trial") return true;
  if (plan === "pro" && licensedModuleIds) {
    return licensedModuleIds.includes(moduleId);
  }
  return false;
}
```

- [ ] **Step 4: Run tests**

Run: `npx vitest run src/lib/modules.test.ts`
Expected: 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add modules.json src/lib/modules.ts src/lib/modules.test.ts
git commit -m "feat: add module registry with license filtering"
```

---

### Task 4: License validator (`src/lib/license.ts`)

**Files:**
- Create: `src/lib/license.ts`
- Create: `src/lib/license.test.ts`
- Create: `scripts/generate-license-keys.ts`

- [ ] **Step 1: Create key generation script**

This script generates the ES256 key pair. Run once to create the Industream signing keys.

```typescript
// scripts/generate-license-keys.ts
import { generateKeyPair, exportJWK } from "jose";
import { writeFile } from "node:fs/promises";

async function main() {
  const { publicKey, privateKey } = await generateKeyPair("ES256");
  const publicJwk = await exportJWK(publicKey);
  const privateJwk = await exportJWK(privateKey);

  await writeFile("keys/public.jwk.json", JSON.stringify(publicJwk, null, 2));
  await writeFile("keys/private.jwk.json", JSON.stringify(privateJwk, null, 2));

  console.log("Keys generated in keys/");
  console.log("PUBLIC key goes into the CLI binary (src/lib/license.ts)");
  console.log("PRIVATE key stays with Industream for signing licenses");
}

main();
```

- [ ] **Step 2: Generate keys**

```bash
mkdir -p keys
npx tsx scripts/generate-license-keys.ts
```

Add `keys/private.jwk.json` to `.gitignore`. The public key will be embedded in the source.

- [ ] **Step 3: Write failing tests**

```typescript
// src/lib/license.test.ts
import { describe, it, expect } from "vitest";
import { SignJWT, importJWK } from "jose";
import { readFile } from "node:fs/promises";
import {
  validateLicense,
  type LicensePayload,
  type LicenseResult,
} from "./license.js";

async function createTestLicense(
  overrides: Partial<LicensePayload> = {},
  expiredDays = 0,
): Promise<string> {
  const privateJwk = JSON.parse(
    await readFile("keys/private.jwk.json", "utf-8"),
  );
  const privateKey = await importJWK(privateJwk, "ES256");

  const now = Math.floor(Date.now() / 1000);
  const payload: LicensePayload = {
    iss: "industream.com",
    sub: "test-client",
    customer: "Test Corp",
    plan: "enterprise",
    modules: ["opc-ua-connector"],
    seats: 10,
    trial: false,
    ...overrides,
  };

  const expiration = expiredDays > 0
    ? now - expiredDays * 86400
    : now + 365 * 86400;

  return new SignJWT(payload as unknown as Record<string, unknown>)
    .setProtectedHeader({ alg: "ES256" })
    .setIssuedAt()
    .setExpirationTime(expiration)
    .sign(privateKey);
}

describe("license", () => {
  it("validates a valid license", async () => {
    const token = await createTestLicense();
    const result = await validateLicense(token);
    expect(result.isValid).toBe(true);
    expect(result.payload?.customer).toBe("Test Corp");
    expect(result.payload?.plan).toBe("enterprise");
  });

  it("rejects an expired license beyond grace period", async () => {
    const token = await createTestLicense({}, 31);
    const result = await validateLicense(token);
    expect(result.isValid).toBe(false);
    expect(result.error).toContain("expired");
  });

  it("accepts an expired license within grace period", async () => {
    const token = await createTestLicense({}, 15);
    const result = await validateLicense(token);
    expect(result.isValid).toBe(true);
    expect(result.isGracePeriod).toBe(true);
  });

  it("rejects a token with invalid signature", async () => {
    const result = await validateLicense("invalid.jwt.token");
    expect(result.isValid).toBe(false);
  });

  it("returns community plan when no license", async () => {
    const result = await validateLicense(undefined);
    expect(result.isValid).toBe(true);
    expect(result.payload?.plan).toBe("community");
  });
});
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `npx vitest run src/lib/license.test.ts`
Expected: FAIL — cannot find module `./license.js`

- [ ] **Step 5: Implement license validator**

```typescript
// src/lib/license.ts
import { jwtVerify, importJWK, type JWTPayload } from "jose";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { getConfigDir } from "./config.js";

// Embedded public key — generated by scripts/generate-license-keys.ts
// Replace this with the actual public JWK after key generation
const PUBLIC_JWK = {} as JsonWebKey; // TODO: paste from keys/public.jwk.json after generation

const GRACE_PERIOD_DAYS = 30;

export interface LicensePayload {
  iss: string;
  sub: string;
  customer: string;
  plan: "community" | "trial" | "pro" | "enterprise";
  modules: string[];
  seats: number;
  trial: boolean;
}

export interface LicenseResult {
  isValid: boolean;
  isGracePeriod: boolean;
  daysRemaining: number;
  payload: LicensePayload | null;
  error?: string;
}

const COMMUNITY_RESULT: LicenseResult = {
  isValid: true,
  isGracePeriod: false,
  daysRemaining: Infinity,
  payload: {
    iss: "industream.com",
    sub: "community",
    customer: "Community",
    plan: "community",
    modules: [],
    seats: Infinity,
    trial: false,
  },
};

export async function validateLicense(
  token?: string,
): Promise<LicenseResult> {
  if (!token) return COMMUNITY_RESULT;

  try {
    const publicKey = await importJWK(PUBLIC_JWK, "ES256");
    const { payload } = await jwtVerify(token, publicKey, {
      issuer: "industream.com",
    });

    const licensePayload = payload as unknown as LicensePayload & JWTPayload;
    const expiration = (payload.exp ?? 0) * 1000;
    const now = Date.now();
    const daysRemaining = Math.floor((expiration - now) / 86400000);
    const gracePeriodEnd = expiration + GRACE_PERIOD_DAYS * 86400000;

    if (now > gracePeriodEnd) {
      return {
        isValid: false,
        isGracePeriod: false,
        daysRemaining,
        payload: licensePayload,
        error: `License expired ${Math.abs(daysRemaining)} days ago (grace period exceeded)`,
      };
    }

    return {
      isValid: true,
      isGracePeriod: now > expiration,
      daysRemaining,
      payload: licensePayload,
    };
  } catch (error) {
    return {
      isValid: false,
      isGracePeriod: false,
      daysRemaining: 0,
      payload: null,
      error: error instanceof Error ? error.message : "Invalid license",
    };
  }
}

export async function loadLicenseFromDisk(): Promise<string | undefined> {
  try {
    const filePath = join(getConfigDir(), "industream.license");
    return (await readFile(filePath, "utf-8")).trim();
  } catch {
    return undefined;
  }
}
```

After generating keys (Step 2), paste the content of `keys/public.jwk.json` into the `PUBLIC_JWK` constant.

- [ ] **Step 6: Run tests**

Run: `npx vitest run src/lib/license.test.ts`
Expected: 5 tests PASS

- [ ] **Step 7: Commit**

```bash
git add src/lib/license.ts src/lib/license.test.ts scripts/generate-license-keys.ts keys/public.jwk.json .gitignore
git commit -m "feat: add JWT license validator with ES256 offline verification"
```

---

### Task 5: Docker helper (`src/lib/docker.ts`)

**Files:**
- Create: `src/lib/docker.ts`
- Create: `src/lib/docker.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// src/lib/docker.test.ts
import { describe, it, expect } from "vitest";
import {
  parseServiceList,
  parseImageVersion,
  type SwarmService,
} from "./docker.js";

describe("docker helpers", () => {
  it("parses docker service ls output", () => {
    const output = `industream-prod_postgres 1/1 postgres:18-alpine
industream-prod_keycloak 1/1 keycloak/keycloak:26.1.0
industream-prod_flowmaker-scheduler 0/1 842775dh.c1.gra9.container-registry.ovh.net/flowmaker.core/flowmaker-launcher:2.0.2`;

    const services = parseServiceList(output, "industream-prod");
    expect(services).toHaveLength(3);
    expect(services[0].name).toBe("postgres");
    expect(services[0].replicas).toBe("1/1");
    expect(services[0].image).toBe("postgres:18-alpine");
    expect(services[1].name).toBe("keycloak");
    expect(services[2].name).toBe("flowmaker-scheduler");
  });

  it("extracts version from image tag", () => {
    expect(parseImageVersion("postgres:18-alpine")).toBe("18-alpine");
    expect(parseImageVersion("keycloak/keycloak:26.1.0")).toBe("26.1.0");
    expect(parseImageVersion("registry.example.com/foo/bar:1.2.3")).toBe("1.2.3");
    expect(parseImageVersion("registry.example.com/foo/bar")).toBe("latest");
  });
});
```

- [ ] **Step 2: Implement docker helper**

```typescript
// src/lib/docker.ts
import { execa } from "execa";

export interface SwarmService {
  name: string;
  fullName: string;
  replicas: string;
  image: string;
  version: string;
  isRunning: boolean;
}

export function parseServiceList(
  output: string,
  stackName: string,
): SwarmService[] {
  const prefix = `${stackName}_`;
  return output
    .trim()
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => {
      const [fullName, replicas, image] = line.split(/\s+/);
      const name = fullName.startsWith(prefix)
        ? fullName.slice(prefix.length)
        : fullName;
      const [running, total] = replicas.split("/").map(Number);
      return {
        name,
        fullName,
        replicas,
        image,
        version: parseImageVersion(image),
        isRunning: running > 0 && running === total,
      };
    });
}

export function parseImageVersion(image: string): string {
  const parts = image.split(":");
  return parts.length > 1 ? parts[parts.length - 1] : "latest";
}

export async function getSwarmServices(
  stackName: string,
): Promise<SwarmService[]> {
  const { stdout } = await execa("docker", [
    "stack",
    "services",
    stackName,
    "--format",
    "{{.Name}} {{.Replicas}} {{.Image}}",
  ]);
  return parseServiceList(stdout, stackName);
}

export async function isSwarmActive(): Promise<boolean> {
  try {
    const { stdout } = await execa("docker", [
      "info",
      "--format",
      "{{.Swarm.LocalNodeState}}",
    ]);
    return stdout.trim() === "active";
  } catch {
    return false;
  }
}

export async function isDockerAvailable(): Promise<boolean> {
  try {
    await execa("docker", ["version", "--format", "{{.Server.Version}}"]);
    return true;
  } catch {
    return false;
  }
}

export async function getServiceLogs(
  serviceName: string,
  tail = 100,
): Promise<string> {
  const { stdout } = await execa("docker", [
    "service",
    "logs",
    "--tail",
    String(tail),
    "--no-trunc",
    serviceName,
  ]);
  return stdout;
}
```

- [ ] **Step 3: Run tests**

Run: `npx vitest run src/lib/docker.test.ts`
Expected: 2 tests PASS

- [ ] **Step 4: Commit**

```bash
git add src/lib/docker.ts src/lib/docker.test.ts
git commit -m "feat: add Docker/Swarm helper with service parsing"
```

---

### Task 6: Swarm repo manager (`src/lib/swarm-repo.ts`)

**Files:**
- Create: `src/lib/swarm-repo.ts`
- Create: `src/lib/swarm-repo.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// src/lib/swarm-repo.test.ts
import { describe, it, expect } from "vitest";
import { resolvePlatformDir, parseEnvFile } from "./swarm-repo.js";

describe("swarm-repo", () => {
  it("resolves ~ in platform dir", () => {
    const resolved = resolvePlatformDir("~/industream-platform");
    expect(resolved).not.toContain("~");
    expect(resolved).toContain("industream-platform");
  });

  it("parses .env file content", () => {
    const content = `
DOCKER_REGISTRY=842775dh.c1.gra9.container-registry.ovh.net
UIFUSION_VERSION=1.0.8
# Comment
FLOWMAKER_CORE_VERSION=2.0.2

KEYCLOAK_VERSION=26.1.0
`;
    const env = parseEnvFile(content);
    expect(env.DOCKER_REGISTRY).toBe("842775dh.c1.gra9.container-registry.ovh.net");
    expect(env.UIFUSION_VERSION).toBe("1.0.8");
    expect(env.FLOWMAKER_CORE_VERSION).toBe("2.0.2");
    expect(env.KEYCLOAK_VERSION).toBe("26.1.0");
  });
});
```

- [ ] **Step 2: Implement swarm-repo module**

```typescript
// src/lib/swarm-repo.ts
import { execa } from "execa";
import { readFile, access } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

const REPO_URL = "https://github.com/industream/industream-swarm.git";

export function resolvePlatformDir(path: string): string {
  return path.replace(/^~/, homedir());
}

export function parseEnvFile(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const equalsIndex = trimmed.indexOf("=");
    if (equalsIndex === -1) continue;
    const key = trimmed.slice(0, equalsIndex);
    const value = trimmed.slice(equalsIndex + 1);
    result[key] = value;
  }
  return result;
}

export async function isPlatformInstalled(platformDir: string): Promise<boolean> {
  try {
    await access(join(resolvePlatformDir(platformDir), ".git"));
    return true;
  } catch {
    return false;
  }
}

export async function cloneSwarmRepo(platformDir: string): Promise<void> {
  const resolved = resolvePlatformDir(platformDir);
  await execa("git", ["clone", "--quiet", REPO_URL, resolved]);
}

export async function pullSwarmRepo(platformDir: string): Promise<string> {
  const resolved = resolvePlatformDir(platformDir);
  const { stdout } = await execa("git", ["-C", resolved, "pull", "--ff-only"]);
  return stdout;
}

export async function loadEnvFile(platformDir: string): Promise<Record<string, string>> {
  const resolved = resolvePlatformDir(platformDir);
  const content = await readFile(join(resolved, ".env"), "utf-8");
  return parseEnvFile(content);
}

export async function getDeployedVersions(
  platformDir: string,
): Promise<Record<string, string>> {
  const env = await loadEnvFile(platformDir);
  const versions: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (key.endsWith("_VERSION")) {
      versions[key] = value;
    }
  }
  return versions;
}
```

- [ ] **Step 3: Run tests**

Run: `npx vitest run src/lib/swarm-repo.test.ts`
Expected: 2 tests PASS

- [ ] **Step 4: Commit**

```bash
git add src/lib/swarm-repo.ts src/lib/swarm-repo.test.ts
git commit -m "feat: add swarm repo manager with env file parsing"
```

---

## Phase 2: Commands

### Task 7: Status command (`src/commands/status.tsx`)

**Files:**
- Create: `src/commands/status.tsx`
- Create: `src/components/ServiceTable.tsx`
- Create: `src/components/Banner.tsx`
- Modify: `src/index.ts`

- [ ] **Step 1: Create Banner component**

```tsx
// src/components/Banner.tsx
import React from "react";
import { Text, Box } from "ink";

export function Banner(): React.ReactElement {
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text bold color="blue">
        INDUSTREAM PLATFORM
      </Text>
    </Box>
  );
}
```

- [ ] **Step 2: Create ServiceTable component**

```tsx
// src/components/ServiceTable.tsx
import React from "react";
import { Text, Box } from "ink";
import type { SwarmService } from "../lib/docker.js";

interface ServiceTableProps {
  services: SwarmService[];
  lockedModuleIds?: string[];
}

export function ServiceTable({
  services,
  lockedModuleIds = [],
}: ServiceTableProps): React.ReactElement {
  return (
    <Box flexDirection="column">
      <Box>
        <Box width={28}>
          <Text bold>SERVICE</Text>
        </Box>
        <Box width={12}>
          <Text bold>STATUS</Text>
        </Box>
        <Box width={15}>
          <Text bold>VERSION</Text>
        </Box>
      </Box>
      {services.map((service) => {
        const isLocked = lockedModuleIds.includes(service.name);
        const statusIcon = isLocked ? "🔒" : service.isRunning ? "●" : "○";
        const statusColor = isLocked
          ? "gray"
          : service.isRunning
            ? "green"
            : "red";
        const statusText = isLocked
          ? "premium"
          : service.isRunning
            ? "running"
            : "stopped";

        return (
          <Box key={service.name}>
            <Box width={28}>
              <Text>
                <Text color={statusColor}>{statusIcon}</Text> {service.name}
              </Text>
            </Box>
            <Box width={12}>
              <Text color={statusColor}>{statusText}</Text>
            </Box>
            <Box width={15}>
              <Text dimColor={isLocked}>{isLocked ? "—" : service.version}</Text>
            </Box>
          </Box>
        );
      })}
    </Box>
  );
}
```

- [ ] **Step 3: Create status command**

```tsx
// src/commands/status.tsx
import React, { useState, useEffect } from "react";
import { render, Text, Box, useInput, useApp } from "ink";
import { Banner } from "../components/Banner.js";
import { ServiceTable } from "../components/ServiceTable.js";
import { getSwarmServices, isSwarmActive } from "../lib/docker.js";
import { loadConfig } from "../lib/config.js";
import { loadLicenseFromDisk, validateLicense } from "../lib/license.js";

function StatusDashboard(): React.ReactElement {
  const { exit } = useApp();
  const [services, setServices] = useState<Awaited<ReturnType<typeof getSwarmServices>>>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchStatus() {
      try {
        const config = await loadConfig();
        const stackName = `industream-${config.defaultEnvironment}`;
        const active = await isSwarmActive();
        if (!active) {
          setError("Docker Swarm is not active. Run: docker swarm init");
          setLoading(false);
          return;
        }
        const result = await getSwarmServices(stackName);
        setServices(result);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Failed to get status");
      } finally {
        setLoading(false);
      }
    }
    fetchStatus();
  }, []);

  useInput((input) => {
    if (input === "q") exit();
  });

  if (loading) {
    return <Text color="blue">Loading services...</Text>;
  }

  if (error) {
    return <Text color="red">{error}</Text>;
  }

  const running = services.filter((s) => s.isRunning).length;

  return (
    <Box flexDirection="column">
      <Banner />
      <ServiceTable services={services} />
      <Box marginTop={1}>
        <Text dimColor>
          {running}/{services.length} services running — press q to quit
        </Text>
      </Box>
    </Box>
  );
}

export function runStatus(): void {
  render(<StatusDashboard />);
}
```

- [ ] **Step 4: Wire status command into index.ts**

```typescript
// src/index.ts — add to existing
import { runStatus } from "./commands/status.js";

program
  .command("status")
  .description("Show platform status dashboard")
  .action(() => {
    runStatus();
  });
```

- [ ] **Step 5: Test manually**

Run: `npm run dev -- status`
Expected: Shows service table or "Docker Swarm is not active" message

- [ ] **Step 6: Commit**

```bash
git add src/commands/status.tsx src/components/ServiceTable.tsx src/components/Banner.tsx src/index.ts
git commit -m "feat: add status dashboard command with live service table"
```

---

### Task 8: Deploy command (`src/commands/deploy.ts`)

**Files:**
- Create: `src/commands/deploy.ts`
- Modify: `src/index.ts`

- [ ] **Step 1: Implement deploy command**

```typescript
// src/commands/deploy.ts
import { execa } from "execa";
import { loadConfig } from "../lib/config.js";
import { resolvePlatformDir, isPlatformInstalled } from "../lib/swarm-repo.js";
import { join } from "node:path";

export type Environment = "prod" | "dev" | "staging";

export async function runDeploy(
  environment?: string,
  options?: { withDemo?: boolean },
): Promise<void> {
  const config = await loadConfig();
  const env = environment ?? config.defaultEnvironment;
  const platformDir = resolvePlatformDir(config.platformDir);

  if (!(await isPlatformInstalled(config.platformDir))) {
    console.error(
      "Platform not installed. Run: industream install",
    );
    process.exit(1);
  }

  const args = ["--env", env];
  if (options?.withDemo) {
    args.push("--with-demo");
  }

  const scriptPath = join(platformDir, "scripts", "deploy-swarm.sh");

  await execa(scriptPath, args, {
    cwd: platformDir,
    stdio: "inherit",
  });
}
```

- [ ] **Step 2: Wire deploy command into index.ts**

```typescript
// src/index.ts — add to existing
import { runDeploy } from "./commands/deploy.js";

program
  .command("deploy")
  .description("Deploy an environment")
  .option("--env <environment>", "Environment to deploy (prod, dev, staging)")
  .option("--with-demo", "Include demo simulators")
  .action((options) => {
    runDeploy(options.env, { withDemo: options.withDemo });
  });
```

- [ ] **Step 3: Commit**

```bash
git add src/commands/deploy.ts src/index.ts
git commit -m "feat: add deploy command delegating to deploy-swarm.sh"
```

---

### Task 9: Stop command (`src/commands/stop.ts`)

**Files:**
- Create: `src/commands/stop.ts`
- Modify: `src/index.ts`

- [ ] **Step 1: Implement stop command**

```typescript
// src/commands/stop.ts
import { execa } from "execa";
import { loadConfig } from "../lib/config.js";

export async function runStop(environment?: string): Promise<void> {
  const config = await loadConfig();
  const env = environment ?? config.defaultEnvironment;
  const stackName = `industream-${env}`;

  console.log(`Stopping ${stackName}...`);

  await execa("docker", ["stack", "rm", stackName], {
    stdio: "inherit",
  });

  console.log(`${stackName} stopped.`);
}
```

- [ ] **Step 2: Wire stop command into index.ts**

```typescript
import { runStop } from "./commands/stop.js";

program
  .command("stop")
  .description("Stop an environment")
  .option("--env <environment>", "Environment to stop (prod, dev, staging)")
  .action((options) => {
    runStop(options.env);
  });
```

- [ ] **Step 3: Commit**

```bash
git add src/commands/stop.ts src/index.ts
git commit -m "feat: add stop command"
```

---

### Task 10: Logs command (`src/commands/logs.ts`)

**Files:**
- Create: `src/commands/logs.ts`
- Modify: `src/index.ts`

- [ ] **Step 1: Implement logs command**

```typescript
// src/commands/logs.ts
import { execa } from "execa";
import { loadConfig } from "../lib/config.js";

export async function runLogs(
  service?: string,
  options?: { follow?: boolean; tail?: number },
): Promise<void> {
  const config = await loadConfig();
  const stackName = `industream-${config.defaultEnvironment}`;
  const serviceName = service
    ? `${stackName}_${service}`
    : stackName;

  if (!service) {
    // List services and let user pick
    const { stdout } = await execa("docker", [
      "stack",
      "services",
      stackName,
      "--format",
      "{{.Name}}",
    ]);
    console.log("Available services:");
    for (const name of stdout.split("\n").filter(Boolean)) {
      console.log(`  ${name.replace(`${stackName}_`, "")}`);
    }
    console.log("\nUsage: industream logs <service-name>");
    return;
  }

  const args = ["service", "logs"];
  if (options?.follow) args.push("-f");
  args.push("--tail", String(options?.tail ?? 100));
  args.push(serviceName);

  await execa("docker", args, { stdio: "inherit" });
}
```

- [ ] **Step 2: Wire logs command into index.ts**

```typescript
import { runLogs } from "./commands/logs.js";

program
  .command("logs [service]")
  .description("View service logs")
  .option("-f, --follow", "Follow log output")
  .option("--tail <lines>", "Number of lines to show", "100")
  .action((service, options) => {
    runLogs(service, { follow: options.follow, tail: Number(options.tail) });
  });
```

- [ ] **Step 3: Commit**

```bash
git add src/commands/logs.ts src/index.ts
git commit -m "feat: add logs command with follow and tail support"
```

---

### Task 11: Secrets command (`src/commands/secrets.ts`)

**Files:**
- Create: `src/commands/secrets.ts`
- Modify: `src/index.ts`

- [ ] **Step 1: Implement secrets command**

```typescript
// src/commands/secrets.ts
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { execa } from "execa";
import { loadConfig } from "../lib/config.js";
import { resolvePlatformDir } from "../lib/swarm-repo.js";

export async function runSecrets(options?: {
  show?: boolean;
  regenerate?: boolean;
}): Promise<void> {
  const config = await loadConfig();
  const platformDir = resolvePlatformDir(config.platformDir);
  const secretsDir = join(platformDir, "secrets");

  if (options?.regenerate) {
    const scriptPath = join(platformDir, "scripts", "setup", "create-secrets.sh");
    await execa(scriptPath, ["--env", config.defaultEnvironment, "--regenerate"], {
      cwd: platformDir,
      stdio: "inherit",
    });
    return;
  }

  try {
    const files = await readdir(secretsDir);
    const secretFiles = files.filter((f) => !f.startsWith("."));

    for (const file of secretFiles.sort()) {
      if (options?.show) {
        const value = await readFile(join(secretsDir, file), "utf-8");
        console.log(`${file}: ${value.trim()}`);
      } else {
        console.log(`  ${file}`);
      }
    }
  } catch {
    console.error("No secrets directory found. Run: industream deploy");
  }
}
```

- [ ] **Step 2: Wire secrets command into index.ts**

```typescript
import { runSecrets } from "./commands/secrets.js";

program
  .command("secrets")
  .description("Manage platform secrets")
  .option("--show", "Display secret values")
  .option("--regenerate", "Regenerate all secrets")
  .action((options) => {
    runSecrets(options);
  });
```

- [ ] **Step 3: Commit**

```bash
git add src/commands/secrets.ts src/index.ts
git commit -m "feat: add secrets command with show and regenerate"
```

---

## Phase 3: Install Wizard + Build

### Task 12: Install wizard (`src/commands/install.tsx`)

**Files:**
- Create: `src/commands/install.tsx`
- Create: `src/components/Spinner.tsx`
- Modify: `src/index.ts`

- [ ] **Step 1: Create Spinner component**

```tsx
// src/components/Spinner.tsx
import React, { useState, useEffect } from "react";
import { Text } from "ink";

const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

interface SpinnerProps {
  label: string;
}

export function Spinner({ label }: SpinnerProps): React.ReactElement {
  const [frame, setFrame] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setFrame((prev) => (prev + 1) % FRAMES.length);
    }, 80);
    return () => clearInterval(timer);
  }, []);

  return (
    <Text>
      <Text color="blue">{FRAMES[frame]}</Text> {label}
    </Text>
  );
}
```

- [ ] **Step 2: Create install wizard**

This is the largest component. It orchestrates the full install flow as a multi-step Ink wizard. Due to its size, implement as a sequence of async functions called from a React component that tracks the current step.

```tsx
// src/commands/install.tsx
import React, { useState, useEffect } from "react";
import { render, Text, Box, useApp } from "ink";
import { Spinner } from "../components/Spinner.js";
import { Banner } from "../components/Banner.js";
import { saveConfig } from "../lib/config.js";
import { isDockerAvailable, isSwarmActive } from "../lib/docker.js";
import {
  cloneSwarmRepo,
  isPlatformInstalled,
  resolvePlatformDir,
} from "../lib/swarm-repo.js";
import { execa } from "execa";
import { join } from "node:path";

type Step =
  | "prerequisites"
  | "clone"
  | "setup"
  | "deploy"
  | "done"
  | "error";

function InstallWizard(): React.ReactElement {
  const { exit } = useApp();
  const [step, setStep] = useState<Step>("prerequisites");
  const [statusMessage, setStatusMessage] = useState("Checking prerequisites...");
  const [error, setError] = useState<string | null>(null);
  const platformDir = "~/industream-platform";

  useEffect(() => {
    async function runInstall() {
      try {
        // Step 1: Prerequisites
        setStep("prerequisites");
        setStatusMessage("Checking Docker...");
        if (!(await isDockerAvailable())) {
          throw new Error("Docker is not installed. Install Docker first: https://docs.docker.com/engine/install/");
        }
        setStatusMessage("Checking Docker Swarm...");
        if (!(await isSwarmActive())) {
          setStatusMessage("Initializing Docker Swarm...");
          await execa("docker", ["swarm", "init"]);
        }

        // Step 2: Clone repo
        setStep("clone");
        setStatusMessage("Downloading platform files...");
        if (await isPlatformInstalled(platformDir)) {
          setStatusMessage("Platform files already present, updating...");
          const resolved = resolvePlatformDir(platformDir);
          await execa("git", ["-C", resolved, "pull", "--ff-only"]);
        } else {
          await cloneSwarmRepo(platformDir);
        }

        // Step 3: Setup (.env, secrets)
        setStep("setup");
        const resolved = resolvePlatformDir(platformDir);
        setStatusMessage("Running platform setup...");
        await execa(join(resolved, "industream.sh"), [], {
          cwd: resolved,
          stdio: "inherit",
        });

        // Step 4: Save config
        await saveConfig({
          platformDir,
          defaultEnvironment: "prod",
        });

        setStep("done");
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
        setStep("error");
      }
    }
    runInstall();
  }, []);

  if (step === "error") {
    return (
      <Box flexDirection="column">
        <Banner />
        <Text color="red">Installation failed: {error}</Text>
      </Box>
    );
  }

  if (step === "done") {
    return (
      <Box flexDirection="column">
        <Banner />
        <Text color="green" bold>
          Installation complete!
        </Text>
        <Text dimColor>Run `industream status` to check your platform.</Text>
      </Box>
    );
  }

  return (
    <Box flexDirection="column">
      <Banner />
      <Spinner label={statusMessage} />
    </Box>
  );
}

export function runInstall(): void {
  render(<InstallWizard />);
}
```

- [ ] **Step 3: Wire install command into index.ts**

```typescript
import { runInstall } from "./commands/install.js";

program
  .command("install")
  .description("Install the Industream platform")
  .action(() => {
    runInstall();
  });
```

- [ ] **Step 4: Test manually on VM**

```bash
npm run dev -- install
```

- [ ] **Step 5: Commit**

```bash
git add src/commands/install.tsx src/components/Spinner.tsx src/index.ts
git commit -m "feat: add install wizard with prerequisites check and guided setup"
```

---

### Task 13: Node SEA build script

**Files:**
- Create: `scripts/build-sea.sh`
- Create: `sea-config.json`
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create SEA config**

```json
{
  "main": "dist/bundle.cjs",
  "output": "dist/sea-prep.blob",
  "disableExperimentalSEAWarning": true,
  "useSnapshot": false,
  "useCodeCache": true
}
```

- [ ] **Step 2: Install esbuild for bundling**

```bash
npm install -D esbuild
```

- [ ] **Step 3: Create build script**

```bash
#!/bin/bash
# scripts/build-sea.sh — Build Node SEA binary
set -e

echo "=== Building Industream CLI ==="

# 1. Bundle TypeScript → single CJS file
echo "Bundling..."
npx esbuild src/index.ts \
  --bundle \
  --platform=node \
  --target=node22 \
  --format=cjs \
  --outfile=dist/bundle.cjs \
  --external:yoga-wasm-web

# 2. Generate SEA blob
echo "Generating SEA blob..."
node --experimental-sea-config sea-config.json

# 3. Copy node binary
echo "Creating binary..."
cp $(which node) dist/industream

# 4. Inject blob
echo "Injecting SEA blob..."
npx postject dist/industream NODE_SEA_BLOB dist/sea-prep.blob \
  --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2

# 5. Make executable
chmod +x dist/industream

echo ""
ls -lh dist/industream
echo "=== Build complete ==="
```

- [ ] **Step 4: Add build script to package.json**

```json
{
  "scripts": {
    "build:sea": "bash scripts/build-sea.sh"
  }
}
```

- [ ] **Step 5: Create GitHub Actions release workflow**

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags:
      - "v*"

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            arch: x64
            artifact: industream-linux-x64
          - os: ubuntu-24.04-arm
            arch: arm64
            artifact: industream-linux-arm64
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "22"
      - run: npm ci
      - run: npm run build:sea
      - uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.artifact }}
          path: dist/industream

  release:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
      - uses: softprops/action-gh-release@v2
        with:
          files: |
            industream-linux-x64/industream
            industream-linux-arm64/industream
```

- [ ] **Step 6: Test build locally**

```bash
chmod +x scripts/build-sea.sh
npm run build:sea
./dist/industream --help
```

Expected: Shows "Industream Platform CLI" help

- [ ] **Step 7: Commit**

```bash
git add scripts/build-sea.sh sea-config.json .github/workflows/release.yml package.json
git commit -m "feat: add Node SEA build and GitHub Actions release pipeline"
```

---

### Task 14: Bootstrap install script

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Create install.sh**

```bash
#!/bin/bash
# Industream CLI — One-line installer
# Usage: curl -fsSL https://raw.githubusercontent.com/industream/industream-cli/main/install.sh | bash
set -e

REPO="industream/industream-cli"
INSTALL_DIR="${INDUSTREAM_INSTALL_DIR:-$HOME/.local/bin}"
SHARE_DIR="${INDUSTREAM_SHARE_DIR:-$HOME/.local/share/industream}"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARTIFACT="industream-linux-x64" ;;
  aarch64) ARTIFACT="industream-linux-arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Get latest release URL
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep "browser_download_url.*$ARTIFACT" | head -1 | cut -d'"' -f4)

if [ -z "$LATEST" ]; then
  echo "Could not find release for $ARTIFACT"
  exit 1
fi

# Download
echo "Downloading Industream CLI..."
mkdir -p "$SHARE_DIR/versions"
VERSION=$(echo "$LATEST" | grep -oP 'v[\d.]+' | head -1)
BINARY_PATH="$SHARE_DIR/versions/$VERSION"
curl -fsSL -o "$BINARY_PATH" "$LATEST"
chmod +x "$BINARY_PATH"

# Symlink
mkdir -p "$INSTALL_DIR"
ln -sf "$BINARY_PATH" "$INSTALL_DIR/industream"

echo ""
echo "Industream CLI installed to $INSTALL_DIR/industream"
echo "Run: industream install"
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat: add bootstrap install script for curl pipe"
```

---

## Summary

| Phase | Tasks | Description |
|-------|-------|-------------|
| **Phase 1** | Tasks 1-6 | Scaffold, config, modules, license, docker, swarm-repo |
| **Phase 2** | Tasks 7-11 | Commands: status, deploy, stop, logs, secrets |
| **Phase 3** | Tasks 12-14 | Install wizard, Node SEA build, bootstrap script |

**Total: 14 tasks, ~70 steps**

Post-MVP tasks (not in this plan):
- `industream update` command (registry version comparison)
- `industream license` command
- `industream uninstall` command
- Interactive menu (`industream` with no args)
- License enforcement at deploy time (filtering stack files)
- Auto-update notification on CLI launch
