//! SafeInCloud XML exchange format — mirrors Services/DatabaseXML.swift.
//! Used both for the encrypted payload inside `.upw` containers and for
//! import/export. Element/attribute names match the original `database.xml`
//! one-to-one.
use crate::model::{Attachment, Card, CardLabel, Field, Ghost, HistoryEntry, PasswordDatabase};
use base64::Engine;
use quick_xml::events::Event;
use quick_xml::Reader;

pub fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(ch),
        }
    }
    out
}

fn attr_unescape(s: &str) -> String {
    // quick-xml gives raw attribute bytes; unescape the standard entities.
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '&' {
            out.push(ch);
            continue;
        }
        let mut entity = String::new();
        let mut terminated = false;
        for e in chars.by_ref() {
            if e == ';' {
                terminated = true;
                break;
            }
            entity.push(e);
            if entity.len() > 8 {
                break;
            }
        }
        match (terminated, entity.as_str()) {
            (true, "amp") => out.push('&'),
            (true, "lt") => out.push('<'),
            (true, "gt") => out.push('>'),
            (true, "quot") => out.push('"'),
            (true, "apos") => out.push('\''),
            _ => {
                out.push('&');
                out.push_str(&entity);
                if terminated {
                    out.push(';');
                }
            }
        }
    }
    out
}

const KNOWN_FIELD_TYPES: &[&str] = &[
    "login", "password", "pin", "number", "date", "phone", "website", "email",
    "one_time_password", "text", "expiry", "secret",
];
const KNOWN_AUTOFILLS: &[&str] = &[
    "off", "username", "current-password", "url", "one-time-code",
    "cc-number", "cc-name", "cc-exp", "cc-csc",
];

pub fn serialize(db: &PasswordDatabase) -> String {
    let mut s = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<database>\n");
    for l in &db.labels {
        s.push_str(&format!(
            "    <label name=\"{}\" id=\"{}\"",
            xml_escape(&l.name),
            l.id
        ));
        if let Some(t) = &l.label_type {
            if !t.is_empty() {
                s.push_str(&format!(" type=\"{}\"", xml_escape(t)));
            }
        }
        if let Some(c) = &l.color {
            s.push_str(&format!(" color=\"{}\"", xml_escape(c)));
        }
        if l.pin_to_top {
            s.push_str(" pin_to_top=\"true\"");
        }
        s.push_str(" />\n");
    }
    for c in &db.cards {
        s.push_str(&format!(
            "    <card title=\"{}\" id=\"{}\"",
            xml_escape(&c.title),
            c.id
        ));
        if let Some(sym) = &c.symbol {
            if !sym.is_empty() {
                s.push_str(&format!(" symbol=\"{}\"", xml_escape(sym)));
            }
        }
        if let Some(col) = &c.color {
            s.push_str(&format!(" color=\"{}\"", xml_escape(col)));
        }
        if c.template {
            s.push_str(" template=\"true\"");
        }
        s.push_str(&format!(
            " autofill=\"{}\"",
            if c.autofill_enabled { "on" } else { "off" }
        ));
        if c.favorite {
            s.push_str(" favorite=\"true\"");
        }
        if c.archived {
            s.push_str(" archived=\"true\"");
        }
        if c.trashed {
            s.push_str(" trashed=\"true\"");
        }
        if let Some(e) = c.expiration {
            s.push_str(&format!(" expiration=\"{}\"", e as i64));
        }
        if let Some(r) = c.reminder {
            s.push_str(&format!(" reminder=\"{}\"", r as i64));
        }
        s.push_str(&format!(
            " created=\"{}\" modified=\"{}\">\n",
            c.created as i64,
            c.modified as i64
        ));
        for f in &c.fields {
            s.push_str(&format!(
                "        <field name=\"{}\" type=\"{}\" autofill=\"{}\"",
                xml_escape(&f.name),
                f.field_type,
                f.autofill
            ));
            if !f.history.is_empty() {
                let json = history_to_json(&f.history);
                s.push_str(&format!(" history=\"{}\"", xml_escape(&json)));
            }
            s.push_str(&format!(">{}</field>\n", xml_escape(&f.value)));
        }
        if !c.notes.is_empty() {
            s.push_str(&format!("        <note>{}</note>\n", xml_escape(&c.notes)));
        }
        for lid in &c.label_ids {
            if let Some(l) = db.labels.iter().find(|l| l.id == *lid) {
                s.push_str(&format!(
                    "        <label name=\"{}\" id=\"{}\" />\n",
                    xml_escape(&l.name),
                    l.id
                ));
            }
        }
        for img in &c.images {
            s.push_str(&format!(
                "        <image name=\"{}\">{}</image>\n",
                xml_escape(&img.name),
                img.data
            ));
        }
        for file in &c.files {
            s.push_str(&format!(
                "        <file name=\"{}\">{}</file>\n",
                xml_escape(&file.name),
                file.data
            ));
        }
        s.push_str("    </card>\n");
    }
    for g in &db.ghosts {
        s.push_str(&format!(
            "    <ghost id=\"{}\" time=\"{}\" />\n",
            g.id,
            g.time as i64
        ));
    }
    s.push_str("</database>\n");
    s
}

pub fn history_to_json(entries: &[HistoryEntry]) -> String {
    let arr: Vec<serde_json::Value> = entries
        .iter()
        .map(|e| serde_json::json!({"v": e.value, "t": e.time as i64}))
        .collect();
    serde_json::to_string(&arr).unwrap_or_else(|_| "[]".into())
}

pub fn history_from_json(raw: &str) -> Vec<HistoryEntry> {
    let Ok(serde_json::Value::Array(arr)) = serde_json::from_str(raw) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|obj| {
            let v = obj.get("v")?.as_str()?.to_string();
            let t = obj.get("t").and_then(|t| t.as_f64()).unwrap_or(0.0);
            Some(HistoryEntry { value: v, time: t })
        })
        .collect()
}

struct ParserState {
    db: PasswordDatabase,
    current_card: Option<Card>,
    current_field: Option<Field>,
    text: String,
    pending_attachment_name: Option<String>,
    pending_attachment_is_image: bool,
}

/// Parses the original SafeInCloud XML exchange format (XDatabase.parseData:).
pub fn parse(xml: &str) -> Result<PasswordDatabase, String> {
    let mut state = ParserState {
        db: PasswordDatabase::default(),
        current_card: None,
        current_field: None,
        text: String::new(),
        pending_attachment_name: None,
        pending_attachment_is_image: false,
    };
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    let b64 = base64::engine::general_purpose::STANDARD;

    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                let name = e.name().0.to_vec();
                let name = String::from_utf8_lossy(&name).into_owned();
                let attrs: Vec<(String, String)> = e
                    .attributes()
                    .filter_map(|a| a.ok())
                    .map(|a| {
                        (
                            String::from_utf8_lossy(a.key.as_ref()).into_owned(),
                            attr_unescape(&String::from_utf8_lossy(&a.value)),
                        )
                    })
                    .collect();
                let attr = |k: &str| attrs.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
                state.text.clear();
                match name.as_str() {
                    "label" => {
                        if state.current_card.is_some() {
                            // card-level label reference
                            if let Some(id) = attr("id").and_then(|v| v.parse::<i64>().ok()) {
                                state.current_card.as_mut().unwrap().label_ids.push(id);
                            }
                        } else if let (Some(id), Some(n)) = (
                            attr("id").and_then(|v| v.parse::<i64>().ok()),
                            attr("name"),
                        ) {
                            state.db.labels.push(CardLabel {
                                id,
                                name: n,
                                label_type: attr("type").filter(|t| !t.is_empty()),
                                color: attr("color"),
                                pin_to_top: attr("pin_to_top").as_deref() == Some("true"),
                                time_stamp: attr("time").and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0),
                            });
                        }
                    }
                    "card" => {
                        let c = Card {
                            id: attr("id").and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
                            title: attr("title").unwrap_or_default(),
                            symbol: attr("symbol"),
                            color: attr("color"),
                            custom_icon_name: attr("custom_icon"),
                            template: attr("template").as_deref() == Some("true"),
                            // autofill="off" explicitly disables; default on
                            autofill_enabled: attr("autofill").as_deref() != Some("off"),
                            favorite: attr("favorite").as_deref() == Some("true"),
                            archived: attr("archived").as_deref() == Some("true"),
                            trashed: attr("trashed").as_deref() == Some("true"),
                            expiration: attr("expiration").and_then(|v| v.parse::<f64>().ok()),
                            reminder: attr("reminder").and_then(|v| v.parse::<f64>().ok()),
                            created: attr("created").and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0),
                            modified: attr("modified").and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0),
                            use_website_icon: attr("use_website_icon").as_deref() == Some("true"),
                            watch: attr("watch").as_deref() == Some("true"),
                            ..Default::default()
                        };
                        state.current_card = Some(c);
                    }
                    "field" => {
                        let field_type = attr("type")
                            .filter(|t| KNOWN_FIELD_TYPES.contains(&t.as_str()))
                            .unwrap_or_else(|| "text".into()); // XSanitizer degradation
                        let autofill = attr("autofill")
                            .filter(|a| KNOWN_AUTOFILLS.contains(&a.as_str()))
                            .unwrap_or_else(|| "off".into());
                        state.current_field = Some(Field {
                            id: uuid::Uuid::new_v4().to_string(),
                            name: attr("name").unwrap_or_default(),
                            field_type,
                            value: String::new(),
                            autofill,
                            history: attr("history")
                                .map(|h| history_from_json(&h))
                                .unwrap_or_default(),
                        });
                    }
                    "image" | "file" => {
                        state.pending_attachment_name = Some(attr("name").unwrap_or_default());
                        state.pending_attachment_is_image = name == "image";
                    }
                    "ghost" => {
                        if let Some(id) = attr("id").and_then(|v| v.parse::<i64>().ok()) {
                            state.db.ghosts.push(Ghost {
                                id,
                                time: attr("time").and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0),
                            });
                        }
                    }
                    _ => {}
                }
                buf.clear();
            }
            Ok(Event::Text(t)) => {
                if let Ok(txt) = t.unescape() {
                    state.text.push_str(&txt);
                }
                buf.clear();
            }
            Ok(Event::CData(t)) => {
                state.text.push_str(&String::from_utf8_lossy(t.as_ref()));
                buf.clear();
            }
            Ok(Event::End(e)) => {
                let name = e.name().0.to_vec();
                let name = String::from_utf8_lossy(&name).into_owned();
                match name.as_str() {
                    "field" => {
                        if let Some(mut f) = state.current_field.take() {
                            f.value = state.text.clone();
                            if let Some(c) = state.current_card.as_mut() {
                                c.fields.push(f);
                            }
                        }
                    }
                    "note" => {
                        if let Some(c) = state.current_card.as_mut() {
                            c.notes = state.text.clone();
                        }
                    }
                    "image" | "file" => {
                        let trimmed = state.text.trim();
                        if !trimmed.is_empty() {
                            if let Ok(bytes) = b64.decode(trimmed) {
                                let att = Attachment {
                                    id: uuid::Uuid::new_v4().to_string(),
                                    name: state.pending_attachment_name.take().unwrap_or_default(),
                                    data: b64.encode(bytes), // normalized
                                };
                                if let Some(c) = state.current_card.as_mut() {
                                    if state.pending_attachment_is_image {
                                        c.images.push(att);
                                    } else {
                                        c.files.push(att);
                                    }
                                }
                            }
                        }
                        state.pending_attachment_name = None;
                    }
                    "card" => {
                        if let Some(c) = state.current_card.take() {
                            state.db.cards.push(c);
                        }
                    }
                    _ => {}
                }
                state.text.clear();
                buf.clear();
            }
            Ok(Event::Eof) => break,
            Ok(_) => {
                buf.clear();
            }
            Err(e) => return Err(format!("XML parse error: {e}")),
        }
    }
    Ok(state.db)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xml_roundtrip() {
        let xml_input = r#"<?xml version="1.0" encoding="UTF-8"?>
<database>
    <label name="Work" id="1" type="web_accounts" color="blue" pin_to_top="true" />
    <card title="Example" id="5" symbol="web_site" color="gray" autofill="on" favorite="true" created="1000" modified="2000">
        <field name="login" type="login" autofill="username">alice</field>
        <field name="password" type="password" autofill="current-password" history="[{&quot;v&quot;:&quot;old&quot;,&quot;t&quot;:900}]">s3cret</field>
        <note>hello &amp; goodbye</note>
        <label name="Work" id="1" />
    </card>
    <ghost id="9" time="123" />
</database>
"#;
        let db = parse(xml_input).unwrap();
        assert_eq!(db.labels.len(), 1);
        assert_eq!(db.cards.len(), 1);
        assert_eq!(db.ghosts.len(), 1);
        let card = &db.cards[0];
        assert_eq!(card.title, "Example");
        assert!(card.favorite);
        assert!(card.autofill_enabled);
        assert_eq!(card.fields.len(), 2);
        assert_eq!(card.fields[0].value, "alice");
        assert_eq!(card.fields[1].history.len(), 1);
        assert_eq!(card.fields[1].history[0].value, "old");
        assert_eq!(card.notes, "hello & goodbye");
        assert_eq!(card.label_ids, vec![1]);

        // re-serialize and re-parse → stable
        let out = serialize(&db);
        let db2 = parse(&out).unwrap();
        assert_eq!(db2.cards.len(), 1);
        assert_eq!(db2.cards[0].fields[1].history[0].value, "old");
        assert_eq!(db2.labels[0].color.as_deref(), Some("blue"));
        assert!(db2.labels[0].pin_to_top);
    }

    #[test]
    fn unknown_field_types_degrade_to_text() {
        let db = parse(r#"<database><card title="t" id="1"><field name="x" type="quantum">v</field></card></database>"#).unwrap();
        assert_eq!(db.cards[0].fields[0].field_type, "text");
    }
}
