// Password strength estimator — mirrors Services/PasswordStrength.swift
// (zxcvbn-style pattern analysis: common passwords / repeats / keyboard
// sequences / dates / dictionary words / brute-force entropy, 0–4 scale).
import { t } from "./i18n";
import { generatorInstance } from "./generator";

export interface PasswordStrength {
  score: number; // 0…4
  entropy: number; // bits
}

const COMMON = new Set([
  "123456", "password", "123456789", "12345678", "12345", "qwerty", "111111", "1234567",
  "dragon", "123123", "abc123", "iloveyou", "sunshine", "princess", "admin", "welcome",
  "monkey", "login", "football", "letmein", "passw0rd", "master", "hello", "freedom",
  "whatever", "qazwsx", "trustno1", "batman", "zaq12wsx", "asdfgh", "000000", "654321",
  "superman", "1qaz2wsx", "michael", "shadow", "password1", "p@ssw0rd", "qwerty123",
  "1q2w3e4r", "11111111", "aaa111", "zkzkzk", "asdf1234", "pass123", "test123", "root",
]);

const KEYBOARD_ROWS = [
  "qwertyuiop",
  "asdfghjkl",
  "zxcvbnm",
  "1234567890",
  "abcdefghijklmnopqrstuvwxyz",
];

/** Returns [guesses, charsConsumed] for the strongest pattern at the head. */
function matchPattern(s: string): [number, number] {
  const chars = [...s];
  const head = chars[0];
  if (head === undefined) return [1, 1];

  // repeat (aaa, 111)
  let run = 1;
  while (run < chars.length && chars[run] === head) run += 1;
  if (run >= 3) return [run * 10, run];

  // keyboard sequences (qwerty rows) and alphabet/digit sequences
  const lower = (c: string) => c.toLowerCase();
  const runLength = (row: string): number => {
    const lowHead = lower(head);
    const start = row.indexOf(lowHead);
    if (start < 0) return 1;
    let n = 1;
    let i = start + 1;
    while (n < chars.length && i < row.length && row[i] === lower(chars[n])) {
      n += 1;
      i += 1;
    }
    if (n < 3 && start > 0) {
      let m = 1;
      let j = start - 1;
      while (m < chars.length && j >= 0 && row[j] === lower(chars[m])) {
        m += 1;
        j -= 1;
      }
      n = Math.max(n, m);
    }
    return n;
  };
  let bestSeq = 1;
  for (const row of KEYBOARD_ROWS) bestSeq = Math.max(bestSeq, runLength(row));
  if (bestSeq >= 3) return [bestSeq * 12, bestSeq];

  // year / date-like
  if (/^(19|20)\d{2}/.test(s) && chars.length >= 4) return [365 * 12, 4];

  // dictionary word from the generator's word list (prefix match)
  const lowerStr = s.toLowerCase();
  let bestWord = "";
  for (const w of generatorInstance.dictionary) {
    if (w.length >= 4 && lowerStr.startsWith(w) && w.length > bestWord.length) bestWord = w;
  }
  if (bestWord) {
    const capBonus = chars[0] === chars[0].toUpperCase() && chars[0] !== chars[0].toLowerCase() ? 2 : 1;
    return [generatorInstance.dictionary.length * capBonus, bestWord.length];
  }

  // brute force by charset size (one char per step)
  const hasLower = /[a-z]/.test(s);
  const hasUpper = /[A-Z]/.test(s);
  const hasDigit = /\d/.test(s);
  const hasSymbol = /[^a-zA-Z0-9]/.test(s);
  let c = 0;
  if (hasLower) c += 26;
  if (hasUpper) c += 26;
  if (hasDigit) c += 10;
  if (hasSymbol) c += 33;
  return [Math.max(c, 10), 1];
}

export function evaluateStrength(password: string): PasswordStrength {
  if (!password) return { score: 0, entropy: 0 };
  if (COMMON.has(password.toLowerCase())) {
    return { score: 0, entropy: Math.log2(COMMON.size) };
  }
  let totalGuesses = 1;
  let rest = password;
  while (rest.length > 0) {
    const [guess, consumed] = matchPattern(rest);
    totalGuesses *= guess;
    rest = rest.slice(Math.max(1, consumed));
  }
  const entropy = Math.log2(Math.max(totalGuesses, 1));
  const score = entropy < 20 ? 0 : entropy < 40 ? 1 : entropy < 60 ? 2 : entropy < 80 ? 3 : 4;
  return { score, entropy };
}

/** Per-character brute fallback for pure random strings. */
export function bruteEntropy(password: string): number {
  if (!password) return 0;
  const hasLower = /[a-z]/.test(password);
  const hasUpper = /[A-Z]/.test(password);
  const hasDigit = /\d/.test(password);
  const hasSymbol = /[^a-zA-Z0-9]/.test(password);
  let c = 0;
  if (hasLower) c += 26;
  if (hasUpper) c += 26;
  if (hasDigit) c += 10;
  if (hasSymbol) c += 33;
  return [...password].length * Math.log2(Math.max(c, 2));
}

/** The attacker takes the cheapest strategy: min(pattern entropy, brute entropy). */
export function scorePassword(password: string): PasswordStrength {
  const p = evaluateStrength(password);
  const b = bruteEntropy(password);
  const entropy = Math.min(p.entropy, b);
  const s = entropy < 20 ? 0 : entropy < 40 ? 1 : entropy < 60 ? 2 : entropy < 80 ? 3 : 4;
  return { score: s, entropy };
}

/** Offline attack, 1e10 guesses/s — StrengthIndicator convention. */
export function crackSeconds(strength: PasswordStrength): number {
  return 2 ** strength.entropy / 1e10;
}

/** StrengthIndicator.crackTimeWithSeconds: — localized crack-time text. */
export function crackTimeText(seconds: number): string {
  const minute = 60, hour = 3600, day = 86400;
  const month = day * 30, year = day * 365, century = year * 100;
  if (seconds < 1) return t("instant_text");
  if (seconds < minute) return `${Math.trunc(seconds)}${t("seconds_abbr_text")}`;
  if (seconds < hour) return `${Math.trunc(seconds / minute)}${t("minutes_abbr_text")}`;
  if (seconds < day) return `${Math.trunc(seconds / hour)}${t("hours_text")}`;
  if (seconds < month) return `${Math.trunc(seconds / day)}${t("days_text")}`;
  if (seconds < year) return `${Math.trunc(seconds / month)}${t("months_text")}`;
  if (seconds < century) return `${Math.trunc(seconds / year)}${t("years_text")}`;
  const c = seconds / century;
  if (c > 100) return t("centuries_text");
  return `${Math.trunc(c)} ${t("centuries_text")}`;
}

export function strengthCrackTimeText(strength: PasswordStrength): string {
  return crackTimeText(crackSeconds(strength));
}
