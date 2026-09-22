// Password generator — mirrors Services/PasswordGenerator.swift +
// PasswordSettings (4 modes + history + embedded word dictionary).
import { t } from "./i18n";

export interface PasswordSettings {
  symbolsAlphabet: string;
  separatorAlphabet: string;
  excludeSimilarCharacters: boolean;
  passwordLength: number;
  /** 0 random / 1 memorable / 2 letters+digits / 3 digits-only */
  passwordType: number;
}

export function defaultPasswordSettings(): PasswordSettings {
  return {
    symbolsAlphabet: "!@#$%^&*()-_=+[]{};:,.?/",
    separatorAlphabet: "-_.",
    excludeSimilarCharacters: false,
    passwordLength: 12,
    passwordType: 0,
  };
}

const DICTIONARY = `apple anchor autumn brave breeze bridge bright bronze butter cabin candle canvas canyon carbon
castle cedar cherry chess cinder clay cliff clover cobalt comet compass copper coral cosmic cotton
crystal dagger dahlia dawn delta desert diamond dolphin domino dragon dune eagle ember emerald
falcon feather fern fiddle flint forest fossil fountain galaxy garnet gecko ginger glacier granite
harbor harvest hazard helix hollow horizon ivory jade jasmine jasper jungle juniper kernel kettle
lagoon lantern lava lemon lilac linen lotus lumber lunar lynx magma maple marble meadow mercury
mineral mirror monsoon moss nebula nickel noble nectar needle oasis ocean olive onyx opal orbit
orchid otter oxide paddle panda papaya pearl pebble pepper petal phoenix pigeon pillar pine pistol
planet plasma plaza plum polar poppy prairie prism quail quartz quiver rabbit radar rapid raven
reef ribbon ridge ripple river robin rocket rose ruby rustic saffron sage sail salmon sandal
sapphire satin savanna scarlet sequoia shadow shell shrimp signal silk silver siren slate solar
sonnet sparrow spider spiral spruce stellar stone sunset syrup tandem teal temple thicket thunder
tiger timber topaz torch tornado tortoise totem toucan trail trellis tulip tundra tunnel turtle
umber unicorn valley vanilla velvet verbena vertex vessel violet vista volcanic walnut warbler
waterfall wattle willow winter wisteria wolf wombat yarrow zebra zenith zephyr zinc zircon`
  .split(/\s+/)
  .filter((w) => w.length >= 3);

const LOWER = "abcdefghijklmnopqrstuvwxyz";
const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const DIGITS = "0123456789";
const SIMILAR = "Il1O0o";

export class PasswordGenerator {
  history: string[] = [];

  get dictionary(): string[] {
    return DICTIONARY;
  }

  addPasswordToHistory(p: string) {
    if (!p) return;
    this.history = this.history.filter((h) => h !== p);
    this.history.unshift(p);
    if (this.history.length > 20) this.history = this.history.slice(0, 20);
  }

  clearHistory() {
    this.history = [];
  }

  randomPassword(length: number, alphabets: string[], settings: PasswordSettings): string {
    if (length < 1) return "";
    let pools = alphabets.filter((a) => a.length > 0);
    if (settings.excludeSimilarCharacters) {
      pools = pools
        .map((a) => [...a].filter((ch) => !SIMILAR.includes(ch)).join(""))
        .filter((a) => a.length > 0);
    }
    if (!pools.length) return "";
    const chars: string[] = [];
    for (const pool of pools) {
      if (chars.length >= length) break;
      chars.push(pool[Math.floor(Math.random() * pool.length)]);
    }
    const all = pools.join("");
    while (chars.length < length) {
      chars.push(all[Math.floor(Math.random() * all.length)]);
    }
    // Fisher–Yates shuffle
    for (let i = chars.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [chars[i], chars[j]] = [chars[j], chars[i]];
    }
    return chars.join("");
  }

  memorablePassword(length: number, settings: PasswordSettings): string {
    const sepAlphabet = settings.separatorAlphabet;
    const sep = sepAlphabet.length
      ? sepAlphabet[Math.floor(Math.random() * sepAlphabet.length)]
      : "-";
    const words: string[] = [];
    let total = 0;
    while (total < length) {
      const w = this.dictionaryWord(Math.max(3, length - total));
      if (total > 0) total += 1;
      total += w.length;
      words.push(w);
      if (words.length >= 6) break;
    }
    let pw = words.join(sep);
    if (pw.length > length + 4) {
      pw = this.randomPassword(length, [LOWER, DIGITS], settings);
    }
    return pw;
  }

  password(length: number, type: number, settings: PasswordSettings): string {
    switch (type) {
      case 1: return this.memorablePassword(length, settings);
      case 2: return this.randomPassword(length, [LOWER, UPPER, DIGITS], settings);
      case 3: return this.randomPassword(length, [DIGITS], settings);
      default:
        return this.randomPassword(length, [LOWER, UPPER, DIGITS, settings.symbolsAlphabet], settings);
    }
  }

  dictionaryWord(maxLength: number): string {
    const min = Math.min(3, maxLength);
    const candidates = this.dictionary.filter((w) => w.length <= Math.max(min, maxLength));
    return candidates[Math.floor(Math.random() * candidates.length)] ?? "word";
  }
}

export const generatorInstance = new PasswordGenerator();

export function passwordTypeName(type: number): string {
  return [
    t("random_text"),
    t("memorable_text"),
    t("letters_and_numbers_text"),
    t("numbers_only_text"),
  ][type] ?? "";
}
