// Localization helper — mirrors App/L10n.swift. Tables are generated from the
// original .strings resources (scripts/gen-i18n.mjs); values carried over
// verbatim. Language follows the settings override, else the system locale.
import { localizableZh } from "./Localizable.zh-Hans";
import { localizableEn } from "./Localizable.en";
import { databaseZh } from "./Database.zh-Hans";
import { databaseEn } from "./Database.en";

export type Lang = "zh-Hans" | "en";

const tables = {
  "zh-Hans": { t: localizableZh, db: databaseZh },
  en: { t: localizableEn, db: databaseEn },
};

/** Current language override; "" = follow the system. Updated by the settings store. */
let activeLang: Lang | "" = "";

export function systemLang(): Lang {
  const langs = typeof navigator !== "undefined" ? navigator.languages ?? [navigator.language] : ["en"];
  return langs.some((l) => l?.toLowerCase().startsWith("zh")) ? "zh-Hans" : "en";
}

export function setLanguage(lang: string) {
  activeLang = lang === "zh-Hans" || lang === "en" ? (lang as Lang) : "";
}

export function language(): Lang {
  return activeLang || systemLang();
}

/** Localizable.strings lookup. */
export function t(key: string, fallback?: string): string {
  const v = tables[language()].t[key];
  if (v !== undefined) return v;
  return fallback ?? key;
}

/** database.strings lookup (template/field/special-label names). */
export function db(key: string): string {
  const v = tables[language()].db[key];
  return v !== undefined ? v : key;
}

/** Resolves `@string/key` references used by the original templates XML. */
export function resolve(raw: string): string {
  return raw.startsWith("@string/") ? db(raw.slice("@string/".length)) : raw;
}

/** The original strings hardcode the "Safe" brand; substitute ours. */
export function tBranded(key: string): string {
  return t(key).replaceAll("Safe", "UPasswords");
}
