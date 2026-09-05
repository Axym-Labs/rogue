import { execFile } from "node:child_process";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);
const logger = path.resolve("scripts/append-daily-log.sh");

describe("daily activity log", () => {
  it("echoes activity and appends it to today's private log", async () => {
    const logDir = await mkdtemp(path.join(tmpdir(), "rogue-logs-"));
    const env = { ...process.env, LOCAL_ROGUE_LOG_DIR: logDir };
    const { stdout: dayOutput } = await execFileAsync("date", ["+%F"]);
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
    expect(await readFile(path.join(logDir, `${day}.log`), "utf8")).toBe(
      "reasoning\ntool call\ntool result\n",
    );
    expect((await stat(logDir)).mode & 0o777).toBe(0o700);
    expect((await stat(path.join(logDir, `${day}.log`))).mode & 0o777).toBe(0o600);
  });

  it("removes terminal control characters before display or persistence", async () => {
    const logDir = await mkdtemp(path.join(tmpdir(), "rogue-logs-"));
    const env = { ...process.env, LOCAL_ROGUE_LOG_DIR: logDir };
    const { stdout: dayOutput } = await execFileAsync("date", ["+%F"]);
    const day = dayOutput.trim();

    const result = await execFileAsync(
      "bash",
      ["-c", 'printf "safe\\033]52;c;stolen\\a\\nnext\\rline\\n" | "$1"', "bash", logger],
      { env },
    );

    expect(result.stdout).toBe("safe]52;c;stolen\nnextline\n");
    expect(await readFile(path.join(logDir, `${day}.log`), "utf8")).toBe(
      "safe]52;c;stolen\nnextline\n",
    );
  });
});
