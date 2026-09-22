// One-off generator: converts Cocoa .strings tables into TypeScript modules
// consumed by src/lib/i18n. Re-run only when the .strings sources change.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;

function parseStrings(path) {
  const out = {};
  const text = readFileSync(path, "utf8");
  const re = /"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    out[m[1]] = m[2].replace(/\\"/g, '"').replace(/\\n/g, "\n");
  }
  return out;
}

function emit(table, locale, destName) {
  const data = parseStrings(
    `${root}Sources/UPasswords/Resources/${locale}.lproj/${table}.strings`,
  );
  const body = `// Generated from ${locale}.lproj/${table}.strings — do not edit by hand.
export const ${destName}: Record<string, string> = ${JSON.stringify(data, null, 2)};
`;
  writeFileSync(`${root}src/lib/i18n/${table}.${locale}.ts`, body);
}

mkdirSync(`${root}src/lib/i18n`, { recursive: true });
emit("Localizable", "zh-Hans", "localizableZh");
emit("Localizable", "en", "localizableEn");
emit("Database", "zh-Hans", "databaseZh");
emit("Database", "en", "databaseEn");
console.log("i18n tables generated");
