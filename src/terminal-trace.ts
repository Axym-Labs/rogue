import { redacted } from "./redaction.js";

const PREVIEW_LIMIT = 500;
const SENSITIVE_TEXT = [
  /\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{12,}\b/g,
  /\bhf_[A-Za-z0-9]{12,}\b/g,
  /\bAKIA[A-Z0-9]{12,}\b/g,
  /\bBearer\s+[^\s"']+/gi,
  /\b(?:[A-Z0-9_]*(?:PASSWORD|PASSWD|TOKEN|SECRET|API_KEY|PRIVATE_KEY)[A-Z0-9_]*)\s*[:=]\s*[^\s,}]+/gi,
  /-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----/g,
];

function sanitizeText(value: string): string {
  return SENSITIVE_TEXT.reduce((text, pattern) => text.replace(pattern, "<redacted>"), value);
}

function preview(value: unknown, limit = PREVIEW_LIMIT): string {
  const serialized = sanitizeText(JSON.stringify(redacted(value)) ?? String(value)).replace(/\s+/g, " ");
  return serialized.length <= limit ? serialized : `${serialized.slice(0, limit - 1)}…`;
}

export function formatToolStartTrace(toolName: string, args: unknown): string {
  return `↳ ${toolName} ${preview(args)}`;
}

export function formatToolResultTrace(toolName: string, result: unknown): string {
  return `✓ ${toolName} ${preview(result)}`;
}

/** Caps streamed private reasoning without buffering or rewriting terminal output. */
export class BoundedThinkingTrace {
  private emitted = 0;
  private closed = false;

  constructor(private readonly limit = 1_200) {}

  push(delta: string): string {
    if (this.closed || !delta || this.limit <= 0) return "";
    const remaining = this.limit - this.emitted;
    if (delta.length <= remaining) {
      this.emitted += delta.length;
      return delta;
    }
    this.closed = true;
    if (remaining <= 1) return remaining === 1 ? "…" : "";
    this.emitted = this.limit;
    return `${delta.slice(0, remaining - 1)}…`;
  }

  reset(): void {
    this.emitted = 0;
    this.closed = false;
  }
}
