/**
 * Turns a spoken slash command into the typed form the Agent SDK runs.
 *
 * Speech to text writes "slash teach linear regression" (or, rarely,
 * "/teach linear regression"); the SDK expands a command only when the user
 * message is the plain string "/teach linear regression" (probed 2026-09-28:
 * the same text inside content blocks, with or without screenshots, reaches
 * Claude as ordinary words). Only names in the session's command list are
 * rewritten, so an ordinary sentence that starts with "slash" is left alone.
 * Multi-word names are spoken with spaces: "slash chunk plan" → "/chunk-plan".
 */

const MAXIMUM_SPOKEN_NAME_WORDS = 3;

export function rewriteSpokenSlashCommand(transcript: string, availableCommandNames: readonly string[]): string | null {
  const commandMatch = /^\s*(?:slash\s+|\/\s*)(.+)$/i.exec(transcript);
  if (!commandMatch?.[1]) {
    return null;
  }

  const spokenWords = commandMatch[1].trim().split(/\s+/);
  const commandNamesByLowercase = new Map(availableCommandNames.map((commandName) => [commandName.toLowerCase(), commandName]));

  for (let nameWordCount = Math.min(MAXIMUM_SPOKEN_NAME_WORDS, spokenWords.length); nameWordCount >= 1; nameWordCount -= 1) {
    const candidateName = spokenWords
      .slice(0, nameWordCount)
      .map((spokenWord) => spokenWord.toLowerCase().replace(/[^a-z0-9:-]/g, ""))
      .join("-");
    const commandName = commandNamesByLowercase.get(candidateName);
    if (commandName) {
      const commandArguments = spokenWords.slice(nameWordCount).join(" ").replace(/^[,.:;]\s*/, "");
      return commandArguments ? `/${commandName} ${commandArguments}` : `/${commandName}`;
    }
  }
  return null;
}
