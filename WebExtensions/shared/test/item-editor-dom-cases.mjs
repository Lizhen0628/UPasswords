// Browser-compatible DOM cases; Node registers them only when a real XML DOM is available.
import { parseVaultXml, readItemDetail, sourceFromFragment, updateItemXml, VaultCryptoError } from "../dist/index.js";

const uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const fragment = `<card id="${uuid}" title="Old" created="10" modified="20" favorite="true" future="keep">
<field name="User" type="future-type" autofill="future-token" history="[{&quot;v&quot;:&quot;old&quot;}]" extra="keep">old</field>
<field name="Site" type="website">https://example.com/path</field>
<note format="future">line 1&#10;line &amp; 2</note>
<label id="ref"/><image name="pic">AAAA</image><file name="file">BBBB</file><icon source="custom">CCCC</icon>
<future extra="keep"><field name="nested">do not edit</field><note>opaque note</note><child/></future>
<!--keep comment--><?future keep?>
</card>`;
const edit = { title: "New <&\"'", fieldValues: ["new <&", "https://example.org/a"], notes: "first\n\nlast & <tag>" };

function assert(condition, message = "DOM assertion failed") {
    if (!condition) throw new Error(message);
}

function equal(actual, expected) {
    assert(actual === expected, "DOM values differ");
}

function rejects(action, code) {
    try {
        action();
    } catch (error) {
        assert(error instanceof VaultCryptoError, "Expected a safe editor error");
        if (code) equal(error.message, code);
        return;
    }
    throw new Error("Expected rejection");
}

const parse = (xml) => new DOMParser().parseFromString(xml, "application/xml");
const serialize = (element) => new XMLSerializer().serializeToString(element);
const direct = (card, name) => Array.from(card.children).filter((element) => element.tagName === name);

export const itemEditorDomCases = [
    {
        name: "edits values, native modified milliseconds and singular note without losing unknown data",
        run() {
            const before = parse(fragment).documentElement;
            const after = parse(updateItemXml(fragment, edit, 1_800_000_000_123)).documentElement;
            equal(after.getAttribute("id"), uuid);
            equal(after.getAttribute("title"), edit.title);
            equal(after.getAttribute("modified"), "1800000000123");
            for (const attr of ["created", "favorite", "future"]) equal(after.getAttribute(attr), before.getAttribute(attr));
            const fields = direct(after, "field");
            equal(fields.length, 2);
            fields.forEach((field, index) => {
                equal(field.textContent, edit.fieldValues[index]);
                for (const attr of direct(before, "field")[index].attributes) equal(field.getAttribute(attr.name), attr.value);
            });
            equal(direct(after, "note")[0].textContent, edit.notes);
            equal(direct(after, "note")[0].getAttribute("format"), "future");
            for (const name of ["label", "image", "file", "icon", "future"]) {
                equal(serialize(direct(after, name)[0]), serialize(direct(before, name)[0]));
            }
            assert(serialize(after).includes("<!--keep comment-->"));
            assert(serialize(after).includes("<?future keep?>"));
        },
    },
    {
        name: "extracts decoded multiline notes from original source and verifies identity",
        run() {
            const source = sourceFromFragment(fragment, 7);
            equal(source.xml, fragment);
            equal(source.revision, 7);
            equal(readItemDetail({ id: uuid.toUpperCase(), source }).notes, "line 1\nline & 2");
            equal(readItemDetail({ notes: "fallback\nnotes" }).notes, "fallback\nnotes");
            equal(readItemDetail({}).notes, "");
            rejects(() => readItemDetail({ id: "wrong", source }), "item_id_mismatch");
        },
    },
    {
        name: "adds and clears note text while preserving existing note attributes and comments",
        run() {
            const source = `<card id="${uuid}"><field><![CDATA[old]]><!--field comment--></field></card>`;
            const changed = updateItemXml(source, { title: "", fieldValues: ["new\r\nline"], notes: "a\r\nb\rc" }, 0);
            const card = parse(changed).documentElement;
            equal(direct(card, "field")[0].textContent, "new\r\nline");
            assert(changed.includes("<!--field comment-->"));
            equal(direct(card, "note")[0].textContent, "a\r\nb\rc");
            equal(card.getAttribute("modified"), "0");
            const cleared = parse(updateItemXml(fragment, { ...edit, notes: "" }, 123)).documentElement;
            equal(direct(cleared, "note")[0].textContent, "");
            equal(direct(cleared, "note")[0].getAttribute("format"), "future");
            const empty = parse(updateItemXml(`<card id="${uuid}"/>`, { title: "", fieldValues: [], notes: "" }, 123));
            equal(empty.getElementsByTagName("note").length, 0);
        },
    },
    {
        name: "preserves unchanged CDATA and notes whitespace",
        run() {
            const source = `<card id="${uuid}"><field><![CDATA[value]]></field><note>  a\n\n b  </note></card>`;
            const result = updateItemXml(source, { title: "", fieldValues: ["value"], notes: "  a\n\n b  " }, 1);
            assert(result.includes("<![CDATA[value]]>"));
            equal(readItemDetail({ id: uuid, source: { xml: result, revision: 1 } }).notes, "  a\n\n b  ");
        },
    },
    {
        name: "title-only edits preserve exact CR/CRLF in passwords, notes and opaque text and attributes",
        run() {
            const source = `<card id="${uuid}" title="Old" future="a&#13;b&#10;c&#9;d">
<field type="password" future="x&#13;&#10;y">secret&#13;part&#13;&#10;end</field>
<note>first&#13;second&#13;&#10;last</note>
<future extra="q&#13;r&#10;s&#9;t">opaque&#13;text&#13;&#10;tail<child>deep&#13;value</child></future>
<![CDATA[unchanged <xml> & &#13;]]><!--keep &#13; literal--><?future keep &#13; literal?>
</card>`;
            const before = parse(source).documentElement;
            const values = direct(before, "field").map((field) => field.textContent);
            const notes = direct(before, "note")[0].textContent;
            const result = updateItemXml(source, { title: "New\r\nTitle\t", fieldValues: values, notes }, 123);
            const after = parse(result).documentElement;
            equal(after.getAttribute("title"), "New\r\nTitle\t");
            equal(direct(after, "field")[0].textContent, "secret\rpart\r\nend");
            equal(direct(after, "note")[0].textContent, "first\rsecond\r\nlast");
            for (const name of ["field", "future"]) {
                const original = direct(before, name)[0];
                const changed = direct(after, name)[0];
                equal(changed.textContent, original.textContent);
                for (const attribute of original.attributes) equal(changed.getAttribute(attribute.name), attribute.value);
            }
            equal(after.getAttribute("future"), before.getAttribute("future"));
            const originalOpaque = Array.from(before.childNodes).filter((node) => [4, 7, 8].includes(node.nodeType));
            const changedOpaque = Array.from(after.childNodes).filter((node) => [4, 7, 8].includes(node.nodeType));
            equal(changedOpaque.length, originalOpaque.length);
            originalOpaque.forEach((node, index) => {
                equal(changedOpaque[index].nodeType, node.nodeType);
                equal(changedOpaque[index].nodeValue, node.nodeValue);
            });
            assert(result.includes("<![CDATA[unchanged <xml> & &#13;]]>"));
            assert(result.includes("<!--keep &#13; literal-->"));
            assert(result.includes("<?future keep &#13; literal?>"));
        },
    },
    {
        name: "changed password and notes retain exact CR, CRLF, LF, tabs and entity-like text",
        run() {
            const source = `<card id="${uuid}"><field type="password"><![CDATA[old]]><!--keep--><?hint keep?></field></card>`;
            const value = "new\rsecret\r\nline\nlast\t&#13;<tag>";
            const notes = "note\rnext\r\nend\n\t&#13;";
            const result = updateItemXml(source, { title: "T", fieldValues: [value], notes }, 1);
            const after = parse(result).documentElement;
            equal(direct(after, "field")[0].textContent, value);
            equal(direct(after, "note")[0].textContent, notes);
            assert(result.includes("<!--keep-->"));
            assert(result.includes("<?hint keep?>"));
            equal(readItemDetail({ id: uuid, source: { xml: result, revision: 1 } }).notes, notes);
            const unchanged = updateItemXml(result, { title: "Again", fieldValues: [value], notes }, 2);
            equal(direct(parse(unchanged).documentElement, "field")[0].textContent, value);
            equal(direct(parse(unchanged).documentElement, "note")[0].textContent, notes);
        },
    },
    {
        name: "projects only direct unnamespaced fields and edits without losing opaque nested fields",
        run() {
            const source = `<card id="${uuid}"><field type="login">user</field><field type="password">secret</field>
<future><field type="password">opaque secret</field><field type="website">https://unrelated.example</field></future>
<foreign xmlns="urn:future"><field type="password">namespaced opaque</field></foreign>
</card>`;
            const projected = parseVaultXml(`<passworddatabase>${source}</passworddatabase>`);
            equal(projected.length, 1);
            equal(projected[0].fields.length, 2);
            equal(projected[0].fields[0].value, "user");
            equal(projected[0].fields[1].value, "secret");
            equal(projected[0].host, "");
            const before = parse(source).documentElement;
            const result = updateItemXml(source, {
                title: "Updated", fieldValues: projected[0].fields.map((field) => field.value), notes: "",
            }, 123);
            const after = parse(result).documentElement;
            for (const name of ["future", "foreign"]) {
                equal(serialize(direct(after, name)[0]), serialize(direct(before, name)[0]));
            }
            equal(parseVaultXml(`<passworddatabase>${result}</passworddatabase>`)[0].fields.length, 2);
            const namespaced = `<card id="${uuid}"><field type="login">user</field><field xmlns="urn:future">opaque</field></card>`;
            equal(parseVaultXml(`<passworddatabase>${namespaced}</passworddatabase>`)[0].fields.length, 1);
        },
    },
    {
        name: "refuses malformed XML, missing/invalid IDs, nested cards and destructive value structures",
        run() {
            for (const source of [
                "<card", "<card/>", '<card id="wrong"/>', `<card id="${uuid}"></wrong>`,
                `<database><card id="${uuid}"/></database>`,
                `<card xmlns="urn:future" id="${uuid}"/>`,
                `<card id="${uuid}"><card id="${uuid}"/></card>`,
                `<card id="${uuid}"><future><card/></future></card>`,
                `<card id="${uuid}"><field>text<future/></field></card>`,
                `<card id="${uuid}"><note>text<br/></note></card>`,
                `<card id="${uuid}"><note/><note/></card>`,
                `<card id="${uuid}"/><card id="${uuid}"/>`,
            ]) rejects(() => updateItemXml(source, { title: "", fieldValues: [], notes: "" }, 1));
            rejects(() => updateItemXml(fragment, { ...edit, fieldValues: [] }, 1), "field_count_mismatch");
        },
    },
    {
        name: "forbids DTD/entities before parsing and rejects invalid XML text, times and revisions",
        run() {
            for (const declaration of [
                '<!DOCTYPE card SYSTEM "https://invalid.example/dtd">',
                '<!DOCTYPE card [<!ENTITY x "expanded">]>',
                '<!ENTITY x SYSTEM "file:///private/secret">',
            ]) rejects(() => sourceFromFragment(`${declaration}<card id="${uuid}"/>`, 1), "bad_xml");
            for (const value of ["\u0000", "\u0001", "\uD800", "\uFFFF"]) {
                rejects(() => updateItemXml(fragment, { ...edit, notes: value }, 1), "bad_xml_text");
            }
            for (const time of [-1, NaN, Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
                rejects(() => updateItemXml(fragment, edit, time), "bad_item_time");
            }
            for (const revision of [0, -1, NaN, Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
                rejects(() => sourceFromFragment(fragment, revision), "bad_item_revision");
            }
        },
    },
];
