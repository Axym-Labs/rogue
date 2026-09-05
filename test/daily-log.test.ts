import { execFile } from "node:child_process";
import { mkdtemp, readFile, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);
const logger = path.resolve("scripts/append-daily-log.sh");

describe("daily activity log", () => {
  it("echoes activity and appends it to today's private log", async () => {
    const logDir = await mkdtemp(path.join(tmpdir(), "rogue-logs-"));
    const env = { ...process.env, LOCAL_ROGUE_LOG_DIR: logDir, LOCAL_ROGUE_LOG_SESSION: "test-session" };
    const { stdout: dayOutput } = await execFileAsync("date", ["-u", "+%F"]);
    const day = dayOutput.trim();

    const first = await execFileAsync(
      "bash",
      ["-c", 'printf "reasoning\\ntool call\\n" | "$1"', "bash", logger],
      { env },
    );
    const second = await execFileAsync(
      "bash",
      ["-c", 'printf "tool result\\n" | "$1"', "bash", logger],
      { env },
    );

    expect(first.stdout).toBe("reasoning\ntool call\n");
    expect(second.stdout).toBe("tool result\n");
    const lines = (await readFile(path.join(logDir, `${day}.log`), "utf8")).trimEnd().split("\n");
    expect(lines).toHaveLength(3);
    expect(lines.map((line) => line.replace(/^\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\] \[session=test-session\] /, "")))
      .toEqual(["reasoning", "tool call", "tool result"]);
    expect(lines.every((line) => /^\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\] /.test(line))).toBe(true);
    expect((await stat(logDir)).mode & 0o777).toBe(0o700);
    expect((await stat(path.join(logDir, `${day}.log`))).mode & 0o777).toBe(0o600);
  });

  it("removes terminal control characters before display or persistence", async () => {
    const logDir = await mkdtemp(path.join(tmpdir(), "rogue-logs-"));
    const env = { ...process.env, LOCAL_ROGUE_LOG_DIR: logDir, LOCAL_ROGUE_LOG_SESSION: "escape-test" };
    const { stdout: dayOutput } = await execFileAsync("date", ["-u", "+%F"]);
    const day = dayOutput.trim();

    const result = await execFileAsync(
      "bash",
      ["-c", 'printf "safe\\033]52;c;stolen\\a\\nnext\\rline\\n" | "$1"', "bash", logger],
      { env },
    );

    expect(result.stdout).toBe("safe]52;c;stolen\nnextline\n");
    const persisted = await readFile(path.join(logDir, `${day}.log`), "utf8");
    expect(persisted).not.toContain("\u001b");
    expect(persisted).toContain("safe]52;c;stolen");
    expect(persisted).toContain("nextline");
  });

  it("deletes only expired daily logs outside the retention window", async () => {
    const logDir = await mkdtemp(path.join(tmpdir(), "rogue-logs-"));
    const expired = path.join(logDir, "2025-01-01.log");
    const retained = path.join(logDir, "retained-not-a-daily-log.txt");
    await writeFile(expired, "old\n");
    await writeFile(retained, "keep\n");
    const old = new Date(Date.now() - 100 * 86_400_000);
    await utimes(expired, old, old);

    await execFileAsync("bash", ["-c", 'printf "current\n" | "$1"', "bash", logger], {
      env: {
        ...process.env,
        LOCAL_ROGUE_LOG_DIR: logDir,
        LOCAL_ROGUE_LOG_SESSION: "retention-test",
        LOCAL_ROGUE_LOG_RETENTION_DAYS: "90",
      },
    });

    await expect(readFile(expired)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(readFile(retained, "utf8")).resolves.toBe("keep\n");
  });
});
