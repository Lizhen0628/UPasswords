//! The 15 built-in card templates — mirrors Models/Templates.swift. Names are
//! emitted as `@string/<key>` references; the frontend resolves them through
//! database.strings before the first save (same values as the original's
//! Resources/database.xml).
use crate::model::{Attachment, Card, Field, HistoryEntry};

pub struct Spec {
    pub id: i64,
    pub title_key: &'static str,
    pub symbol: Option<&'static str>,
    pub autofill: bool,
    pub fields: &'static [(&'static str, &'static str, &'static str)], // (nameKey, type, autofill)
}

pub const SPECS: &[Spec] = &[
    Spec { id: 101, title_key: "credit_card_template", symbol: Some("credit_card"), autofill: true, fields: &[
        ("number_field", "number", "cc-number"),
        ("owner_field", "text", "cc-name"),
        ("expires_field", "expiry", "cc-exp"),
        ("cvv_field", "pin", "cc-csc"),
        ("pin_field", "pin", "off"),
        ("blocking_field", "phone", "off"),
    ] },
    Spec { id: 102, title_key: "web_account_template", symbol: Some("web_site"), autofill: true, fields: &[
        ("login_field", "login", "username"),
        ("password_field", "password", "current-password"),
        ("url_field", "website", "url"),
        ("one_time_password_field", "one_time_password", "one-time-code"),
    ] },
    Spec { id: 103, title_key: "email_account_template", symbol: Some("email"), autofill: true, fields: &[
        ("email_field", "login", "username"),
        ("password_field", "password", "current-password"),
        ("url_field", "website", "url"),
        ("one_time_password_field", "one_time_password", "one-time-code"),
    ] },
    Spec { id: 104, title_key: "login_password_template", symbol: Some("key"), autofill: false, fields: &[
        ("login_field", "login", "username"),
        ("password_field", "password", "current-password"),
    ] },
    Spec { id: 100, title_key: "code_template", symbol: Some("lock"), autofill: false, fields: &[
        ("code_field", "password", "current-password"),
    ] },
    Spec { id: 105, title_key: "id_passport_template", symbol: Some("id"), autofill: false, fields: &[
        ("number_field", "number", "off"),
        ("name_field", "text", "off"),
        ("birthday_field", "date", "off"),
        ("issued_field", "date", "off"),
        ("expires_field", "expiry", "off"),
    ] },
    Spec { id: 106, title_key: "insurance_template", symbol: Some("insurance"), autofill: false, fields: &[
        ("number_field", "number", "off"),
        ("expires_field", "expiry", "off"),
        ("phone_field", "phone", "off"),
    ] },
    Spec { id: 107, title_key: "membership_template", symbol: Some("membership"), autofill: true, fields: &[
        ("number_field", "number", "off"),
        ("login_field", "login", "username"),
        ("password_field", "password", "current-password"),
        ("url_field", "website", "url"),
        ("phone_field", "phone", "off"),
    ] },
    Spec { id: 108, title_key: "bank_account_template", symbol: Some("bank"), autofill: true, fields: &[
        ("bank_field", "text", "off"),
        ("holder_field", "text", "off"),
        ("account_field", "number", "off"),
        ("type_field", "text", "off"),
        ("swift_field", "text", "off"),
        ("iban_field", "text", "off"),
        ("phone_field", "phone", "off"),
        ("login_field", "login", "username"),
        ("password_field", "password", "current-password"),
        ("url_field", "website", "url"),
    ] },
    Spec { id: 109, title_key: "driving_license_template", symbol: Some("id"), autofill: false, fields: &[
        ("number_field", "text", "off"),
        ("name_field", "text", "off"),
        ("birthday_field", "date", "off"),
        ("class_field", "text", "off"),
        ("expires_field", "expiry", "off"),
    ] },
    Spec { id: 110, title_key: "social_security_template", symbol: Some("social_security"), autofill: false, fields: &[
        ("number_field", "text", "off"),
        ("name_field", "text", "off"),
    ] },
    Spec { id: 111, title_key: "wifi_router_template", symbol: Some("router"), autofill: false, fields: &[
        ("network_field", "text", "off"),
        ("ip_address_field", "number", "off"),
        ("admin_password_field", "password", "off"),
        ("wifi_password_field", "password", "current-password"),
    ] },
    Spec { id: 112, title_key: "internet_provider_template", symbol: Some("network"), autofill: true, fields: &[
        ("protocol_field", "text", "off"),
        ("login_field", "login", "username"),
        ("password_field", "password", "current-password"),
        ("dns_field", "number", "off"),
        ("dns_2_field", "number", "off"),
        ("url_field", "website", "url"),
    ] },
    Spec { id: 113, title_key: "software_license_template", symbol: Some("cd"), autofill: true, fields: &[
        ("email_field", "login", "username"),
        ("password_field", "password", "current-password"),
        ("key_field", "text", "off"),
        ("url_field", "website", "url"),
    ] },
    Spec { id: 120, title_key: "totp_template", symbol: Some("key"), autofill: true, fields: &[
        ("one_time_password_field", "one_time_password", "one-time-code"),
        ("url_field", "website", "url"),
    ] },
    Spec { id: 114, title_key: "custom_template", symbol: None, autofill: false, fields: &[] },
];

fn make_card_from_spec(spec: &Spec, id: i64, now: f64) -> Card {
    Card {
        id,
        title: format!("@string/{}", spec.title_key),
        symbol: spec.symbol.map(|s| s.to_string()),
        color: Some("gray".into()),
        template: false,
        autofill_enabled: spec.autofill,
        favorite: false,
        archived: false,
        trashed: false,
        expiration: None,
        reminder: None,
        created: now,
        modified: now,
        use_website_icon: false,
        watch: false,
        fields: spec
            .fields
            .iter()
            .map(|(name_key, field_type, autofill)| Field {
                id: uuid::Uuid::new_v4().to_string(),
                name: format!("@string/{name_key}"),
                field_type: field_type.to_string(),
                value: String::new(),
                autofill: autofill.to_string(),
                history: Vec::<HistoryEntry>::new(),
            })
            .collect(),
        notes: String::new(),
        label_ids: Vec::new(),
        images: Vec::<Attachment>::new(),
        files: Vec::<Attachment>::new(),
        custom_icon_name: None,
    }
}

/// Template card instances (template=true) stored inside a fresh database.
pub fn template_cards(now: f64) -> Vec<Card> {
    SPECS
        .iter()
        .map(|spec| {
            let mut c = make_card_from_spec(spec, spec.id, now);
            c.template = true;
            c
        })
        .collect()
}
