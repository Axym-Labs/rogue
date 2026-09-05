import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);
const repositoryRoot = path.resolve(".");
const script = path.join(repositoryRoot, "scripts/local-qwen-sandbox.sh");

describe("local Qwen Docker boundary", () => {
  it("defaults to the complete configured workspace instead of the current project", async () => {
    const workspace = await mkdtemp(path.join(tmpdir(), "rogue-workspace-"));
    const currentProject = path.join(workspace, "project-a");
    const workdir = path.join(workspace, "rogue-workdir");
    const logDir = await mkdtemp(path.join(tmpdir(), "rogue-private-logs-"));
    await mkdir(currentProject);
    await mkdir(workdir);

    const { stdout } = await execFileAsync("bash", [script, "--dry-run"], {
      cwd: currentProject,
      env: {
        ...process.env,
        LOCAL_ROGUE_WORKSPACE_ROOT: workspace,
        LOCAL_ROGUE_WORKDIR: workdir,
        LOCAL_ROGUE_LOG_DIR: logDir,
        LOCAL_ROGUE_CYCLE_DELAY_SECONDS: "42",
      },
    });
    const plan = JSON.parse(stdout);

    expect(plan.workspace).toBe(workspace);
    expect(plan.workdir).toBe(workdir);
    expect(plan.mounts).toEqual([
      { source: workspace, target: "/workspace", mode: "ro" },
      { source: workdir, target: "/workspace/rogue-workdir", mode: "rw" },
    ]);
    expect(plan.activityLogs).toEqual({
      directory: logDir,
      rolling: "daily",
      retentionDays: 90,
      timestamps: "UTC",
      sessionTagged: true,
      accessibleToAgent: false,
    });
    expect(plan.conversationRetentionDays).toBe(90);
    expect(plan.cycleDelaySeconds).toBe(42);
    expect(plan.permissionNote).toEqual({
      source: path.join(repositoryRoot, "config", "00-READ-ME-FIRST.md"),
      target: "/workspace/rogue-workdir/00-READ-ME-FIRST.md",
      mode: "ro",
    });
    expect(plan.mounts.every((mount: { source: string }) => mount.source !== logDir)).toBe(true);
  });

  it("describes a read-only workspace, isolated writable folder, and credential masks", async () => {
    const workspace = await mkdtemp(path.join(tmpdir(), "rogue-workspace-"));
    const workdir = path.join(workspace, "rogue-workdir");
    await mkdir(path.join(workspace, "nested"));
    await mkdir(path.join(workspace, ".git"));
    await mkdir(path.join(workspace, "nested", ".rogue"));
    await mkdir(path.join(workspace, "nested", ".ssh"));
    await mkdir(workdir);
    await writeFile(path.join(workspace, ".env"), "SECRET=never-read\n");
    await writeFile(path.join(workspace, ".env.example"), "SECRET=example\n");
    await writeFile(path.join(workspace, "nested", "service.key"), "never-read\n");
    await writeFile(path.join(workspace, "nested", "client_secret_test.json"), "never-read\n");
    await writeFile(path.join(workspace, "nested", "terraform.tfstate"), "never-read\n");
    await writeFile(
      path.join(workspace, "nested", ".rogue", "internal.txt"),
      'api_key = "aB3dE5fG7hI9jK1mN3pQ5rS7tU9vW2xY"\n',
    );

    const { stdout } = await execFileAsync("bash", [script, "--dry-run"], {
      env: {
        ...process.env,
        LOCAL_ROGUE_WORKSPACE_ROOT: workspace,
        LOCAL_ROGUE_WORKDIR: workdir,
      },
    });
    const plan = JSON.parse(stdout);

    expect(plan.workspace).toBe(workspace);
    expect(plan.workdir).toBe(workdir);
    expect(plan.model).toBe("claude-opus-4-6[1m]");
    expect(plan.contextWindow).toBe(229376);
    expect(plan.reasoning).toBe("xhigh");
    expect(plan.cycleDelaySeconds).toBe(300);
    expect(plan.network).toBe("vpn-only");
    expect(plan.vpnGateway).toMatchObject({
      image: "qmcgaw/gluetun@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027",
      config: "/home/davwis/.config/local-rogue/wg0.conf",
      proxy: "http://vpn-gateway:8888",
      killSwitch: true,
      credentialsExposedToAgent: false,
      directInternet: false,
    });
    expect(plan.security).toMatchObject({
      readOnlyRoot: true,
      capabilities: [],
      noNewPrivileges: true,
      dockerSocket: false,
      hostNamespaces: false,
      internet: "vpn-only",
      recursiveSubmounts: false,
      apparmor: "docker-default",
      seccomp: "builtin",
      ipc: "private",
      cgroupns: "private",
      restartPolicy: "no",
    });
    expect(plan.modelService).toEqual({
      dedicated: true,
      hostIpc: false,
      outboundNetwork: false,
      readOnlyRoot: true,
      capabilities: [],
      noNewPrivileges: true,
    });
    expect(plan.mounts).toEqual([
      { source: workspace, target: "/workspace", mode: "ro" },
      { source: workdir, target: "/workspace/rogue-workdir", mode: "rw" },
    ]);
    expect(plan.maskedDirectories).toEqual([".git", "nested/.rogue", "nested/.ssh"]);
    expect(plan.maskedCredentials).toEqual([
      ".env",
      "nested/client_secret_test.json",
      "nested/service.key",
      "nested/terraform.tfstate",
    ]);
    expect(plan.maskedCredentials).not.toContain(".env.example");
    expect(plan.maskedCredentials).not.toContain("nested/.rogue/internal.txt");
  });

  it("fails closed when the readable workspace contains an IPC node", async () => {
    const workspace = await mkdtemp(path.join(tmpdir(), "rogue-workspace-"));
    const workdir = path.join(workspace, "rogue-workdir");
    await mkdir(workdir);
    await execFileAsync("mkfifo", [path.join(workdir, "credential-agent.sock")]);

    await expect(
      execFileAsync("bash", [script, "--dry-run"], {
        env: {
          ...process.env,
          LOCAL_ROGUE_WORKSPACE_ROOT: workspace,
          LOCAL_ROGUE_WORKDIR: workdir,
        },
      }),
    ).rejects.toMatchObject({ stderr: expect.stringContaining("IPC or device node") });
  });

  it("masks a non-obvious file when the content scanner detects a secret", async () => {
    const workspace = await mkdtemp(path.join(tmpdir(), "rogue-workspace-"));
    const workdir = path.join(workspace, "rogue-workdir");
    await mkdir(workdir);
    await writeFile(
      path.join(workspace, "ordinary-notes.txt"),
      'api_key = "aB3dE5fG7hI9jK1mN3pQ5rS7tU9vW2xY"\n',
    );

    const { stdout } = await execFileAsync("bash", [script, "--dry-run"], {
      env: {
        ...process.env,
        LOCAL_ROGUE_WORKSPACE_ROOT: workspace,
        LOCAL_ROGUE_WORKDIR: workdir,
      },
    });
    const plan = JSON.parse(stdout);

    expect(plan.maskedCredentials).toContain("ordinary-notes.txt");
    expect(plan.secretScan).toMatchObject({ tool: "gitleaks", redacted: true, findings: 1 });
    expect(stdout).not.toContain("aB3dE5fG7hI9jK1mN3pQ5rS7tU9vW2xY");
  });

  it("refuses filesystem root as a workspace", async () => {
    await expect(
      execFileAsync("bash", [script, "--dry-run"], {
        env: {
          ...process.env,
          LOCAL_ROGUE_WORKSPACE_ROOT: "/",
          LOCAL_ROGUE_WORKDIR: "/tmp/rogue-workdir",
        },
      }),
    ).rejects.toMatchObject({ stderr: expect.stringContaining("filesystem root") });
  });

  it("resolves its repository when invoked through an alias symlink", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "rogue-alias-"));
    const workdir = path.join(directory, "rogue-workdir");
    await mkdir(workdir);
    const alias = path.join(directory, "local-rogue");
    await symlink(script, alias);
    const { stdout } = await execFileAsync("bash", [alias, "--dry-run"], {
      env: {
        ...process.env,
        LOCAL_ROGUE_WORKSPACE_ROOT: directory,
        LOCAL_ROGUE_WORKDIR: workdir,
      },
    });
    expect(JSON.parse(stdout)).toMatchObject({ workspace: directory, workdir, repository: repositoryRoot });
  });

  it("keeps supervising if the agent process exits itself", async () => {
    const source = await readFile(script, "utf8");
    expect(source).toContain('while docker inspect "$CONTAINER"');
    expect(source).toContain('docker start "$CONTAINER"');
  });

  it("terminates both sides of the log-follow pipeline during cleanup", async () => {
    const source = await readFile(script, "utf8");
    expect(source).toContain('kill "$DOCKER_LOG_PID"');
    expect(source).toContain('kill "$LOG_READER_PID"');
  });

  it("starts a dedicated model directly on the internal network", async () => {
    const source = await readFile(script, "utf8");
    expect(source).toContain('LOCAL_LLM_DOCKER_NETWORK="$NETWORK"');
    expect(source).toContain('docker network connect --alias vpn-gateway "$NETWORK" "$VPN_CONTAINER"');
    expect(source.indexOf('docker network create --internal "$NETWORK"')).toBeLessThan(
      source.indexOf('LOCAL_LLM_DOCKER_NETWORK="$NETWORK"'),
    );
    expect(source).toContain("refusing to reuse an existing local model container");
    expect(source).toContain('docker exec "$MODEL_CONTAINER" bash -c');
    expect(source).not.toContain("http://127.0.0.1:8000/v1/models");
    expect(source).toContain('src=$MASK_FILE,dst=/workspace/$relative,readonly');
    expect(source).not.toContain("src=/dev/null,dst=/workspace/$relative");
    expect(source).toContain("--security-opt seccomp=builtin");
    expect(source).toContain('VPN_STATE_VOLUME="axym-rogue-vpn-state-$TOKEN-$$"');
    expect(source).toContain('src=$VPN_STATE_VOLUME,dst=/gluetun,volume-nocopy');
    expect(source).toContain('src=$VPN_RESOLV,dst=/etc/resolv.conf');
    expect(source).toContain('--cap-add DAC_READ_SEARCH');
    expect(source).toContain('--env PUID=0');
    expect(source).toContain('--env PUBLICIP_ENABLED=off');
    expect(source).toContain('--env VERSION_INFORMATION=off');
    expect(source).toContain('--env HTTPS_PROXY=http://vpn-gateway:8888');
    expect(source).toContain('--env ROGUE_REPROVISION=1');
    expect(source).toContain('VPN_SERVICE_PROVIDER=custom');
    expect(source).toContain('FIREWALL_INPUT_PORTS=8888');
    expect(source).toContain("VPN gateway lost health");
    expect(source).toContain("refusing executable hooks in VPN config");
  });
});
