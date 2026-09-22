// The 15 built-in card templates — mirrors Models/Templates.swift, reproduced
// one-to-one from the original Resources/database.xml. `@string/…` references
// resolve through database.strings at access time.
import type { Autofill, Card, CardLabel, FieldType, Field, PasswordDatabase } from "./models";
import { newCard, newField } from "./models";
import { db } from "./i18n";

export interface TemplateFieldSpec {
  nameKey: string;
  type: FieldType;
  autofill: Autofill;
}
export interface TemplateSpec {
  id: number;
  titleKey: string;
  symbol: string | null;
  autofill: boolean;
  fields: TemplateFieldSpec[];
}

export const TEMPLATES: TemplateSpec[] = [
  { id: 101, titleKey: "credit_card_template", symbol: "credit_card", autofill: true, fields: [
    { nameKey: "number_field", type: "number", autofill: "cc-number" },
    { nameKey: "owner_field", type: "text", autofill: "cc-name" },
    { nameKey: "expires_field", type: "expiry", autofill: "cc-exp" },
    { nameKey: "cvv_field", type: "pin", autofill: "cc-csc" },
    { nameKey: "pin_field", type: "pin", autofill: "off" },
    { nameKey: "blocking_field", type: "phone", autofill: "off" },
  ] },
  { id: 102, titleKey: "web_account_template", symbol: "web_site", autofill: true, fields: [
    { nameKey: "login_field", type: "login", autofill: "username" },
    { nameKey: "password_field", type: "password", autofill: "current-password" },
    { nameKey: "url_field", type: "website", autofill: "url" },
    { nameKey: "one_time_password_field", type: "one_time_password", autofill: "one-time-code" },
  ] },
  { id: 103, titleKey: "email_account_template", symbol: "email", autofill: true, fields: [
    { nameKey: "email_field", type: "login", autofill: "username" },
    { nameKey: "password_field", type: "password", autofill: "current-password" },
    { nameKey: "url_field", type: "website", autofill: "url" },
    { nameKey: "one_time_password_field", type: "one_time_password", autofill: "one-time-code" },
  ] },
  { id: 104, titleKey: "login_password_template", symbol: "key", autofill: false, fields: [
    { nameKey: "login_field", type: "login", autofill: "username" },
    { nameKey: "password_field", type: "password", autofill: "current-password" },
  ] },
  { id: 100, titleKey: "code_template", symbol: "lock", autofill: false, fields: [
    { nameKey: "code_field", type: "password", autofill: "current-password" },
  ] },
  { id: 105, titleKey: "id_passport_template", symbol: "id", autofill: false, fields: [
    { nameKey: "number_field", type: "number", autofill: "off" },
    { nameKey: "name_field", type: "text", autofill: "off" },
    { nameKey: "birthday_field", type: "date", autofill: "off" },
    { nameKey: "issued_field", type: "date", autofill: "off" },
    { nameKey: "expires_field", type: "expiry", autofill: "off" },
  ] },
  { id: 106, titleKey: "insurance_template", symbol: "insurance", autofill: false, fields: [
    { nameKey: "number_field", type: "number", autofill: "off" },
    { nameKey: "expires_field", type: "expiry", autofill: "off" },
    { nameKey: "phone_field", type: "phone", autofill: "off" },
  ] },
  { id: 107, titleKey: "membership_template", symbol: "membership", autofill: true, fields: [
    { nameKey: "number_field", type: "number", autofill: "off" },
    { nameKey: "login_field", type: "login", autofill: "username" },
    { nameKey: "password_field", type: "password", autofill: "current-password" },
    { nameKey: "url_field", type: "website", autofill: "url" },
    { nameKey: "phone_field", type: "phone", autofill: "off" },
  ] },
  { id: 108, titleKey: "bank_account_template", symbol: "bank", autofill: true, fields: [
    { nameKey: "bank_field", type: "text", autofill: "off" },
    { nameKey: "holder_field", type: "text", autofill: "off" },
    { nameKey: "account_field", type: "number", autofill: "off" },
    { nameKey: "type_field", type: "text", autofill: "off" },
    { nameKey: "swift_field", type: "text", autofill: "off" },
    { nameKey: "iban_field", type: "text", autofill: "off" },
    { nameKey: "phone_field", type: "phone", autofill: "off" },
    { nameKey: "login_field", type: "login", autofill: "username" },
    { nameKey: "password_field", type: "password", autofill: "current-password" },
    { nameKey: "url_field", type: "website", autofill: "url" },
  ] },
  { id: 109, titleKey: "driving_license_template", symbol: "id", autofill: false, fields: [
    { nameKey: "number_field", type: "text", autofill: "off" },
    { nameKey: "name_field", type: "text", autofill: "off" },
    { nameKey: "birthday_field", type: "date", autofill: "off" },
    { nameKey: "class_field", type: "text", autofill: "off" },
    { nameKey: "expires_field", type: "expiry", autofill: "off" },
  ] },
  { id: 110, titleKey: "social_security_template", symbol: "social_security", autofill: false, fields: [
    { nameKey: "number_field", type: "text", autofill: "off" },
    { nameKey: "name_field", type: "text", autofill: "off" },
  ] },
  { id: 111, titleKey: "wifi_router_template", symbol: "router", autofill: false, fields: [
    { nameKey: "network_field", type: "text", autofill: "off" },
    { nameKey: "ip_address_field", type: "number", autofill: "off" },
    { nameKey: "admin_password_field", type: "password", autofill: "off" },
    { nameKey: "wifi_password_field", type: "password", autofill: "current-password" },
  ] },
  { id: 112, titleKey: "internet_provider_template", symbol: "network", autofill: true, fields: [
    { nameKey: "protocol_field", type: "text", autofill: "off" },
    { nameKey: "login_field", type: "login", autofill: "username" },
    { nameKey: "password_field", type: "password", autofill: "current-password" },
    { nameKey: "dns_field", type: "number", autofill: "off" },
    { nameKey: "dns_2_field", type: "number", autofill: "off" },
    { nameKey: "url_field", type: "website", autofill: "url" },
  ] },
  { id: 113, titleKey: "software_license_template", symbol: "cd", autofill: true, fields: [
    { nameKey: "email_field", type: "login", autofill: "username" },
    { nameKey: "password_field", type: "password", autofill: "current-password" },
    { nameKey: "key_field", type: "text", autofill: "off" },
    { nameKey: "url_field", type: "website", autofill: "url" },
  ] },
  { id: 120, titleKey: "totp_template", symbol: "key", autofill: true, fields: [
    { nameKey: "one_time_password_field", type: "one_time_password", autofill: "one-time-code" },
    { nameKey: "url_field", type: "website", autofill: "url" },
  ] },
  { id: 114, titleKey: "custom_template", symbol: null, autofill: false, fields: [] },
];

export function templateSpec(id: number): TemplateSpec | undefined {
  return TEMPLATES.find((s) => s.id === id);
}

/** Default labels of a fresh database (web_accounts is a special type). */
export const DEFAULT_LABEL_KEYS: { nameKey: string; id: number; type: string | null }[] = [
  { nameKey: "busines_label", id: 1, type: null },
  { nameKey: "private_label", id: 2, type: null },
  { nameKey: "web_accounts_label", id: 4, type: "web_accounts" },
];

/** Instantiates a real card (template=false) from a template spec. */
export function makeCardFromSpec(spec: TemplateSpec, id: number, now = Date.now()): Card {
  const card = newCard(id, now);
  card.title = db(spec.titleKey);
  card.symbol = spec.symbol;
  card.color = "gray";
  card.autofillEnabled = spec.autofill;
  card.fields = spec.fields.map(
    (f): Field => ({ ...newField(db(f.nameKey)), type: f.type, autofill: f.autofill }),
  );
  return card;
}

/** A template card instance (template=true) stored inside the database. */
export function makeTemplateCard(spec: TemplateSpec, now = Date.now()): Card {
  const c = makeCardFromSpec(spec, spec.id, now);
  c.template = true;
  return c;
}

export const TEMPLATE_IDS = new Set(TEMPLATES.map((s) => s.id));

/** New database with the original's default labels and 15 built-in templates. */
export function createDefaultDatabase(now = Date.now()): PasswordDatabase {
  const dbase = { labels: [] as CardLabel[], cards: [] as Card[], ghosts: [] };
  for (const { nameKey, id, type } of DEFAULT_LABEL_KEYS) {
    dbase.labels.push({ id, name: db(nameKey), type, color: null, pinToTop: false, timeStamp: now });
  }
  dbase.cards = TEMPLATES.map((s) => makeTemplateCard(s, now));
  return dbase;
}
