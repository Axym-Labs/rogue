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
      accessibleToAgent: false,
    });
    expect(plan.mounts.every((mount: { source: string }) => mount.source !== logDir)).toBe(true);
  });

  it("describes a read-only workspace, isolated writable folder, and credential masks", async () => {
    const workspace = await mkdtemp(path.join(tmpdir(), "rogue-workspace-"));
    const workdir = path.join(workspace, "rogue-workdir");
    await mkdir(path.join(workspace, "nested"));
    await mkdir(workdir);
    await writeFile(path.join(workspace, ".env"), "SECRET=never-read\n");
    await writeFile(path.join(workspace, ".env.example"), "SECRET=example\n");
    await writeFile(path.join(workspace, "nested", "service.key"), "never-read\n");

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
    expect(plan.network).toBe("internal");
    expect(plan.security).toMatchObject({
      readOnlyRoot: true,
      capabilities: [],
      noNewPrivileges: true,
      dockerSocket: false,
      hostNamespaces: false,
      internet: false,
    });
    expect(plan.mounts).toEqual([
      { source: workspace, target: "/workspace", mode: "ro" },
      { source: workdir, target: "/workspace/rogue-workdir", mode: "rw" },
    ]);
    expect(plan.maskedCredentials).toEqual([".env", "nested/service.key"]);
    expect(plan.maskedCredentials).not.toContain(".env.example");
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
});
