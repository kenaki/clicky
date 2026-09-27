/**
 * Correlates request ids with the promises waiting on their replies, with a
 * timeout per request so a silent app never hangs the agent.
 */
export interface PendingReplyRegistryOptions {
  timeoutMs: number;
  createTimeoutError: (requestId: string) => Error;
}

interface PendingEntry<Reply> {
  resolve: (reply: Reply) => void;
  reject: (reason: Error) => void;
  timer: NodeJS.Timeout;
}

export class PendingReplyRegistry<Reply> {
  private readonly entriesByRequestId = new Map<string, PendingEntry<Reply>>();
  private readonly options: PendingReplyRegistryOptions;

  constructor(options: PendingReplyRegistryOptions) {
    this.options = options;
  }

  /** Registers a request and returns the promise its reply will resolve. */
  register(requestId: string): Promise<Reply> {
    if (this.entriesByRequestId.has(requestId)) {
      return Promise.reject(new Error(`duplicate pending request id ${requestId}`));
    }
    return new Promise<Reply>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.entriesByRequestId.delete(requestId);
        reject(this.options.createTimeoutError(requestId));
      }, this.options.timeoutMs);
      this.entriesByRequestId.set(requestId, { resolve, reject, timer });
    });
  }

  /** Returns false if nothing was waiting on that id (late or unknown reply). */
  resolve(requestId: string, reply: Reply): boolean {
    const entry = this.entriesByRequestId.get(requestId);
    if (!entry) return false;
    clearTimeout(entry.timer);
    this.entriesByRequestId.delete(requestId);
    entry.resolve(reply);
    return true;
  }

  rejectAll(reason: Error): void {
    for (const [requestId, entry] of this.entriesByRequestId) {
      clearTimeout(entry.timer);
      this.entriesByRequestId.delete(requestId);
      entry.reject(reason);
    }
  }

  get pendingCount(): number {
    return this.entriesByRequestId.size;
  }
}
