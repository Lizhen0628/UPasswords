// Sidebar / sorting / color models — mirrors Models/SidebarModels.swift
// (the MLabel special sidebar labels, SortingSet, SelectColorViewController palette).
import type { Card } from "./models";
import { cardSize } from "./models";
import { db, t } from "./i18n";

export const SPECIAL_LABELS = [
  "all_cards_label",
  "favorites_label",
  "recent_label",
  "passwords_label",
  "totp_label",
  "notes_label",
  "files_label",
  "images_label",
  "passkeys_label",
  "credit_cards_label",
  "weak_passwords_label",
  "same_passwords_label",
  "compromised_passwords_label",
  "expiring_label",
  "expired_label",
  "archived_label",
  "trash_label",
  "templates_label",
] as const;
export type SpecialLabel = (typeof SPECIAL_LABELS)[number];

export function specialLabelName(sp: SpecialLabel): string {
  return db(sp);
}

/** lucide icon per special label (original sidebar had colored SF Symbols). */
export function specialLabelIcon(sp: SpecialLabel): string {
  switch (sp) {
    case "all_cards_label": return "layout-grid";
    case "favorites_label": return "star";
    case "recent_label": return "clock";
    case "passwords_label": return "key-round";
    case "totp_label": return "timer";
    case "notes_label": return "sticky-note";
    case "files_label": return "file";
    case "images_label": return "image";
    case "passkeys_label": return "key-round";
    case "credit_cards_label": return "credit-card";
    case "weak_passwords_label": return "triangle-alert";
    case "same_passwords_label": return "copy";
    case "compromised_passwords_label": return "shield-alert";
    case "expiring_label": return "hourglass";
    case "expired_label": return "calendar-x";
    case "archived_label": return "archive";
    case "trash_label": return "trash";
    case "templates_label": return "layers";
  }
}

export type SidebarSection = "safe" | "labels" | "security" | "special" | "optionalItems";

/** Sidebar grouping per the original app: Safe / 标签 / 安全性 / 特殊. */
export function specialLabelSection(sp: SpecialLabel): SidebarSection {
  switch (sp) {
    case "all_cards_label":
    case "favorites_label":
    case "credit_cards_label":
    case "notes_label":
    case "totp_label":
    case "passkeys_label":
    case "recent_label":
      return "safe";
    case "passwords_label":
    case "files_label":
    case "images_label":
      return "optionalItems";
    case "compromised_passwords_label":
    case "weak_passwords_label":
    case "same_passwords_label":
      return "security";
    case "expiring_label":
    case "expired_label":
    case "archived_label":
    case "templates_label":
    case "trash_label":
      return "special";
  }
}

/** Icon tint matching the original sidebar (colored special marks). */
export function specialLabelTint(sp: SpecialLabel): string | null {
  switch (sp) {
    case "favorites_label": return "yellow";
    case "compromised_passwords_label":
    case "weak_passwords_label": return "red";
    case "same_passwords_label": return "orange";
    case "templates_label": return "blue";
    default: return null;
  }
}

/** Empty-state text (Localizable `*_empty_state` keys of the original). */
export function specialLabelEmptyState(sp: SpecialLabel): string {
  switch (sp) {
    case "all_cards_label": return t("user_empty_state");
    case "favorites_label": return t("favorites_empty_state");
    case "recent_label": return t("recent_empty_state");
    case "passkeys_label": return t("passkeys_empty_state");
    case "notes_label": return t("notes_empty_state");
    case "compromised_passwords_label": return t("compromised_passwords_empty_state");
    case "weak_passwords_label": return t("weak_passwords_empty_state");
    case "expired_label": return t("expired_empty_state");
    case "expiring_label": return t("expiring_empty_state");
    case "archived_label": return t("archived_empty_state");
    case "trash_label": return t("trash_empty_state");
    case "templates_label": return t("templates_empty_state");
    default: return t("user_empty_state");
  }
}

export function sectionGroupKey(section: SidebarSection): string | null {
  switch (section) {
    case "safe": return "safe_group";
    case "labels": return "labels_group";
    case "security": return "security_group";
    case "special": return "special_group";
    case "optionalItems": return null;
  }
}

/** Sidebar selection: either a special label key or a user label id. */
export type SidebarSelection =
  | { kind: "special"; sp: SpecialLabel }
  | { kind: "label"; id: number };

export function selectionEquals(a: SidebarSelection, b: SidebarSelection): boolean {
  if (a.kind === "special" && b.kind === "special") return a.sp === b.sp;
  if (a.kind === "label" && b.kind === "label") return a.id === b.id;
  return false;
}

/** Colored group header icons of the original sidebar (LabelListGroupCell). */
export function sectionHeaderIcon(section: SidebarSection): string {
  switch (section) {
    case "safe": return "shield";
    case "labels": return "tag";
    case "security": return "shield-alert";
    case "special": return "settings";
    case "optionalItems": return "settings";
  }
}

// ----- SortingSet (Services/SortingSet.h) -----

export const SORTINGS = [
  "title_asc", "title_desc", "created_asc", "created_desc",
  "modified_asc", "modified_desc", "size_asc", "size_desc",
] as const;
export type Sorting = (typeof SORTINGS)[number];

export function sortingName(s: Sorting): string {
  return t(`${s}_text`);
}

export function sortCards(cards: Card[], sorting: Sorting, favoritesFirst: boolean): Card[] {
  const out = [...cards];
  const cmpTitle = new Intl.Collator(undefined, { sensitivity: "base" });
  switch (sorting) {
    case "title_asc": out.sort((a, b) => cmpTitle.compare(a.title, b.title)); break;
    case "title_desc": out.sort((a, b) => cmpTitle.compare(b.title, a.title)); break;
    case "created_asc": out.sort((a, b) => a.created - b.created); break;
    case "created_desc": out.sort((a, b) => b.created - a.created); break;
    case "modified_asc": out.sort((a, b) => a.modified - b.modified); break;
    case "modified_desc": out.sort((a, b) => b.modified - a.modified); break;
    case "size_asc": out.sort((a, b) => cardSize(a) - cardSize(b)); break;
    case "size_desc": out.sort((a, b) => cardSize(b) - cardSize(a)); break;
  }
  if (favoritesFirst) {
    out.sort((a, b) => Number(b.favorite) - Number(a.favorite));
  }
  return out;
}

// ----- Card color palette (XML `color` attribute vocabulary) -----

export const CARD_COLORS = [
  "gray", "blue", "red", "green", "yellow", "purple",
  "orange", "cyan", "pink", "brown", "white", "black",
] as const;
export type CardColor = (typeof CARD_COLORS)[number];

export function colorCss(name?: string | null): string {
  switch (name) {
    case "blue": return "#2f7cf6";
    case "red": return "#e5484d";
    case "green": return "#32a467";
    case "yellow": return "#f5b544";
    case "purple": return "#8e5ad8";
    case "orange": return "#f76b15";
    case "cyan": return "#00a2c7";
    case "pink": return "#f26cb8";
    case "brown": return "#ad7f58";
    case "white": return "#ffffff";
    case "black": return "#3a3a3c";
    default: return "#8e8e93"; // gray (Safe's neutral default)
  }
}
