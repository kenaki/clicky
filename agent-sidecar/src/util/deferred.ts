/**
 * A promise whose resolve/reject are exposed, for bridging callback-style
 * events (a WebSocket reply, an SDK result message) into async code.
 */
export interface Deferred<T> {
  readonly promise: Promise<T>;
  resolve(value: T): void;
  reject(reason: Error): void;
  readonly isSettled: boolean;
}

export function createDeferred<T>(): Deferred<T> {
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (reason: Error) => void;
  let isSettled = false;

  const promise = new Promise<T>((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });

  return {
    promise,
    resolve(value) {
      if (isSettled) return;
      isSettled = true;
      resolvePromise(value);
    },
    reject(reason) {
      if (isSettled) return;
      isSettled = true;
      rejectPromise(reason);
    },
    get isSettled() {
      return isSettled;
    }
  };
}
