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
 *
 * With `minimumWordsPerSentence` above 1, a completed sentence shorter than
 * that is held back and joined to the next one ("sure." + "the menu is up
 * top." → "sure. the menu is up top."), because a speech model given a lone
 * "sure." can return a fraction of a second of near silence (seen with Miso
 * on 2026-09-28). `flush` still returns anything held, so no words are lost.
 */
export class SentenceStreamSplitter {
  private pendingText = "";
  /** A completed sentence too short to speak alone, waiting for the next one. */
  private heldShortSentence = "";

  constructor(private readonly minimumWordsPerSentence: number = 1) {}

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
        const sentence = this.joinWithHeldShortSentence(candidate);
        if (countWords(sentence) < this.minimumWordsPerSentence) {
          this.heldShortSentence = sentence;
        } else {
          completedSentences.push(sentence);
        }
      }
      consumedUpTo = match.index + match[0].length;
    }

    this.pendingText = this.pendingText.slice(consumedUpTo);
    return completedSentences;
  }

  /** Returns whatever is still pending (including a held short sentence) as a final sentence, or null, and resets. */
  flush(): string | null {
    const remaining = this.joinWithHeldShortSentence(this.pendingText.trim());
    this.pendingText = "";
    return remaining === "" ? null : remaining;
  }

  /**
   * A text block ended mid-turn (a tool call usually follows): return what is
   * pending so it is spoken now, unless it is too short to speak alone, in
   * which case hold it for the next sentence. Use `flush` at the end of a turn.
   */
  flushAtPause(): string | null {
    const remaining = this.flush();
    if (remaining !== null && countWords(remaining) < this.minimumWordsPerSentence) {
      this.heldShortSentence = remaining;
      return null;
    }
    return remaining;
  }

  private joinWithHeldShortSentence(sentence: string): string {
    if (this.heldShortSentence === "") return sentence;
    const joined = sentence === "" ? this.heldShortSentence : `${this.heldShortSentence} ${sentence}`;
    this.heldShortSentence = "";
    return joined;
  }

  get pending(): string {
    return this.pendingText;
  }
}

function countWords(text: string): number {
  return text.split(/\s+/).filter((word) => word !== "").length;
}
