import { describe, expect, it } from "vitest";
import { csvRows, csvEscape } from "../src/lib/importer";
import { csvFormat, importFormatById } from "../src/lib/importer";
import { emptyDatabase, nextItemId } from "../src/lib/models";

describe("CSV engine", () => {
  it("parses quoted fields and embedded separators", () => {
    const rows = csvRows('name,note\n"Alpha, Inc","line\nbreak"\nplain,"say ""hi"""\n');
    expect(rows).toEqual([
      ["name", "note"],
      ["Alpha, Inc", "line\nbreak"],
      ["plain", 'say "hi"'],
    ]);
  });

  it("supports tab separators", () => {
    expect(csvRows("a\tb\n1\t2")).toEqual([["a", "b"], ["1", "2"]]);
  });

  it("escapes on export", () => {
    expect(csvEscape('a"b')).toBe('"a""b"');
  });
});

describe("CSV importers", () => {
  it("imports Chrome-family exports", () => {
    const db = emptyDatabase();
    const fmt = importFormatById("chrome-chrome")!;
    const n = fmt.parse(
      "name,url,username,password\nExample,https://example.com,alice,secret1\n,https://b.org,bob,pw2\n",
      db,
      Date.now(),
    );
    expect(n).toBe(2);
    expect(db.cards).toHaveLength(2);
    expect(db.cards[0].title).toBe("Example");
    expect(db.cards[0].fields.find((f) => f.type === "password")?.value).toBe("secret1");
  });

  it("creates labels from Bitwarden folders", () => {
    const db = emptyDatabase();
    const fmt = importFormatById("bitwarden-csv")!;
    const n = fmt.parse(
      "folder,name,login_username,login_password,login_uri,notes\nWork,Portal,john,pw,https://intranet,note\nPersonal,Bank,jane,pw2,,\n",
      db,
      Date.now(),
    );
    expect(n).toBe(2);
    expect(db.labels.map((l) => l.name).sort()).toEqual(["Personal", "Work"]);
    expect(db.cards[0].labelIds).toHaveLength(1);
  });

  it("skips fully empty rows", () => {
    const db = emptyDatabase();
    const n = importFormatById("csv")!.parse(
      "name,username,password\n,,\nx,y,z\n",
      db,
      Date.now(),
    );
    expect(n).toBe(1);
  });
});

describe("nextItemId", () => {
  it("skips used ids across cards/labels/ghosts", () => {
    const db = emptyDatabase();
    db.cards.push({ ...({} as never), id: 1, title: "a" });
    db.labels.push({ id: 2, name: "l", pinToTop: false, timeStamp: 0 });
    db.ghosts.push({ id: 3, time: 0 });
    expect(nextItemId(db)).toBe(4);
  });
});
