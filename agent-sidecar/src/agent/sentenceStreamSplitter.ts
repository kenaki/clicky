/**
 * Turns a stream of text chunks into complete sentences as soon as they can
 * be recognised, so speech can start on the first sentence while Claude is
 * still writing the second.
 *
 * A sentence ends at a run of . ! or ? (optionally followed by a closing
 * quote or bracket) that is followed by whitespace, or at a newline. Text
 * whose ending punctuation has not yet been followed by whitespace stays
 * pending, because the next chunk might continue it ("3." then "5 seconds").
 * Speech is forgiving, so there is deliberately no abbreviation or initials
 * logic: "press command f. then type" must split after "f.", and a stray
 * split after an initial costs only a tiny pause.
 */
export class SentenceStreamSplitter {
  private pendingText = "";

  /** Appends a chunk and returns every sentence it completed, in order. */
  feed(chunk: string): string[] {
    this.pendingText += chunk;
    const completedSentences: string[] = [];
    const boundaryPattern = /([.!?]+["')\]]*)(\s+)|(\n+)/g;
    let consumedUpTo = 0;
    let match: RegExpExecArray | null;

    while ((match = boundaryPattern.exec(this.pendingText)) !== null) {
      const isPunctuationBoundary = match[1] !== undefined;
      const sentenceEnd = isPunctuationBoundary ? match.index + (match[1] as string).length : match.index;
      const candidate = this.pendingText.slice(consumedUpTo, sentenceEnd).trim();
      if (candidate !== "") {
        completedSentences.push(candidate);
      }
      consumedUpTo = match.index + match[0].length;
    }

    this.pendingText = this.pendingText.slice(consumedUpTo);
    return completedSentences;
  }

  /** Returns whatever is still pending as a final sentence, or null, and resets. */
  flush(): string | null {
    const remaining = this.pendingText.trim();
    this.pendingText = "";
    return remaining === "" ? null : remaining;
  }

  get pending(): string {
    return this.pendingText;
  }
}
