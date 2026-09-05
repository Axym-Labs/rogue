import { describe, expect, it } from "vitest";
import {
  BoundedThinkingTrace,
  formatToolResultTrace,
  formatToolStartTrace,
} from "../src/terminal-trace.js";

describe("terminal activity trace", () => {
  it("shows concrete tool arguments compactly", () => {
    expect(formatToolStartTrace("bash", { command: "python -m pytest -q", timeout: 120 })).toBe(
      '↳ bash {"command":"python -m pytest -q","timeout":120}',
    );
  });

  it("redacts credential-shaped fields and values", () => {
    const line = formatToolStartTrace("write", {
      path: ".env",
      content: "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz123456\nAuthorization: Bearer secret-token",
      apiKey: "do-not-print",
    });
    expect(line).toContain('"path":".env"');
    expect(line).not.toContain("ghp_");
    expect(line).not.toContain("secret-token");
    expect(line).not.toContain("do-not-print");
    expect(line).toContain("<redacted>");
  });

  it("returns a bounded, sanitized result preview", () => {
    const line = formatToolResultTrace("bash", {
      content: [
        { type: "text", text: "PASSWORD=hunter2" },
        { type: "text", text: "x".repeat(2_000) },
      ],
    });
    expect(line.startsWith("✓ bash ")).toBe(true);
    expect(line).not.toContain("hunter2");
    expect(line.length).toBeLessThanOrEqual(530);
    expect(line.endsWith("…")).toBe(true);
  });

  it("shows only a bounded amount of streamed reasoning per turn", () => {
    const trace = new BoundedThinkingTrace(30);
    expect(trace.push("consider the repository ")).toBe("consider the repository ");
    expect(trace.push("and all credentials")).toBe("and a…");
    expect(trace.push("ignored forever")).toBe("");
    trace.reset();
    expect(trace.push("new turn")).toBe("new turn");
  });
});
