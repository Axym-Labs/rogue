import { execFile } from "node:child_process";
import { mkdtemp, mkdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);
const repositoryRoot = path.resolve(".");
const script = path.join(repositoryRoot, "scripts/local-qwen-sandbox.sh");

describe("local Qwen Docker boundary", () => {
  it("describes a least-privilege project mount and credential masks", async () => {
    const project = await mkdtemp(path.join(tmpdir(), "rogue-project-"));
    await mkdir(path.join(project, "nested"));
    await writeFile(path.join(project, ".env"), "SECRET=never-read\n");
    await writeFile(path.join(project, ".env.example"), "SECRET=example\n");
    await writeFile(path.join(project, "nested", "service.key"), "never-read\n");

    const { stdout } = await execFileAsync("bash", [script, "--dry-run", "--project", project]);
    const plan = JSON.parse(stdout);

    expect(plan.project).toBe(project);
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
    expect(plan.mounts).toContainEqual({ source: project, target: "/workspace", mode: "rw" });
    expect(plan.maskedCredentials).toEqual([".env", "nested/service.key"]);
    expect(plan.maskedCredentials).not.toContain(".env.example");
  });

  it("refuses filesystem root as a project", async () => {
    await expect(execFileAsync("bash", [script, "--dry-run", "--project", "/"])).rejects.toMatchObject({
      stderr: expect.stringContaining("filesystem root"),
    });
  });

  it("resolves its repository when invoked through an alias symlink", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "rogue-alias-"));
    const alias = path.join(directory, "local-rogue");
    await symlink(script, alias);
    const { stdout } = await execFileAsync("bash", [alias, "--dry-run", "--project", directory]);
    expect(JSON.parse(stdout)).toMatchObject({ project: directory, repository: repositoryRoot });
  });
});
