// Parity test: the single-pass sidebarCounts must produce exactly the same
// numbers as the original per-selection cardsFor(sel, "").length scans.
import { describe, test, expect, beforeAll } from "vitest";
import { setActivePinia, createPinia } from "pinia";
import { useAppStore } from "../src/stores/app";
import { SPECIAL_LABELS } from "../src/lib/sidebar";
import type { Card, Field, PasswordDatabase } from "../src/lib/models";

const localStorageMock = (() => {
  let store: Record<string, string> = {};
  return {
    getItem: (k: string) => store[k] ?? null,
    setItem: (k: string, v: string) => { store[k] = v; },
    removeItem: (k: string) => { delete store[k]; },
    clear: () => { store = {}; },
  };
})();
beforeAll(() => {
  Object.defineProperty(globalThis, "localStorage", { value: localStorageMock });
});

let fid = 1;
const fld = (type: string, value = ""): Field =>
  ({ id: fid++, name: type, type, value, history: [], autofill: false }) as unknown as Field;

let cid = 1;
function card(partial: Partial<Card>): Card {
  return {
    id: cid++, title: `Card ${cid}`, symbol: "custom", color: "blue",
    favorite: false, archived: false, trashed: false, template: false,
    labelIds: [], expiration: null, autofillEnabled: false,
    notes: "", images: [], files: [], created: 0, modified: 0, useWebsiteIcon: false,
    fields: [], ...partial,
  } as unknown as Card;
}

function fixtureDb(): PasswordDatabase {
  const day = 86400000;
  const now = Date.now();
  return {
    labels: [
      { id: 101, name: "工作", color: "blue", pinToTop: false },
      { id: 102, name: "个人", color: "red", pinToTop: false },
    ],
    ghosts: [],
    cards: [
      card({ fields: [fld("login", "a@b.c"), fld("password", "123456")], labelIds: [101] }), // weak
      card({ fields: [fld("login", "x@y.z"), fld("password", "123456")], labelIds: [101, 102] }), // weak + same
      card({ fields: [fld("password", "V3ry-Str0ng!Pass#99")], favorite: true }),
      card({ fields: [fld("password", "V3ry-Str0ng!Pass#99")], archived: true }), // archived same-pw
      card({ fields: [fld("one_time_password", "JBSWY3DPEHPK3PXP")] }),
      card({ notes: "纯笔记" }),
      card({ symbol: "credit_card", fields: [fld("number", "4111111111111111")] }),
      card({ files: [{ id: 1, name: "f.pdf", data: "AAAA" }] }),
      card({ images: [{ id: 1, data: "AAAA" }] }),
      card({ expiration: now + 10 * day }), // expiring
      card({ expiration: now - day }), // expired
      card({ expiration: now + 60 * day }), // neither
      card({ archived: true, fields: [fld("password", "123456")] }), // archived weak/same
      card({ trashed: true, fields: [fld("password", "123456")] }), // trash
      card({ template: true }), // template
      card({ fields: [fld("password", "password")] }), // compromised demo set + weak
    ],
  } as unknown as PasswordDatabase;
}

describe("sidebarCounts parity", () => {
  test("countFor 与 cardsFor(...).length 完全一致", () => {
    setActivePinia(createPinia());
    const app = useAppStore();
    // @ts-expect-error 注入测试数据库
    app.database = fixtureDb();

    for (const sp of SPECIAL_LABELS) {
      const expected = app.cardsFor({ kind: "special", sp }, "").length;
      expect(app.countFor({ kind: "special", sp }), `special:${sp}`).toBe(expected);
    }
    for (const l of [101, 102, 999]) {
      const expected = app.cardsFor({ kind: "label", id: l }, "").length;
      expect(app.countFor({ kind: "label", id: l }), `label:${l}`).toBe(expected);
    }
  });
});
