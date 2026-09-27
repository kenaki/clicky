/**
 * Error types shared across layers. Every error carries a `code` that is
 * stable on the wire so the Swift app can switch on it. Codes are documented
 * in docs/ipc-protocol.md.
 */

export type SidecarErrorCode =
  | "hello_required"
  | "unauthorized"
  | "protocol_version_unsupported"
  | "malformed_message"
  | "client_already_connected"
  | "session_not_started"
  | "session_already_started"
  | "session_failed"
  | "turn_interrupted"
  | "screenshot_timeout"
  | "permission_timeout"
  | "internal_error";

export interface SidecarErrorOptions {
  cause?: unknown;
  utteranceId?: string;
}

export class SidecarError extends Error {
  readonly code: SidecarErrorCode;
  readonly utteranceId: string | undefined;

  constructor(code: SidecarErrorCode, message: string, options: SidecarErrorOptions = {}) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = new.target.name;
    this.code = code;
    this.utteranceId = options.utteranceId;
  }
}

/** A message from the client that could not be understood or was out of order. */
export class ProtocolError extends SidecarError {}

/** The agent session itself failed, was interrupted, or is in the wrong state. */
export class SessionError extends SidecarError {}

/** A request to the host (screenshot, permission) did not get an answer in time. */
export class HostReplyTimeoutError extends SidecarError {}

export function describeUnknownError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
