//! Data model — mirrors Models/CoreModels.swift (XCard / XField / XLabel /
//! XGhost / XImage / XFile / XHistory). JSON shape (camelCase) matches the
//! frontend TypeScript types in src/lib/models.ts one-to-one.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub value: String,
    pub time: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Field {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub field_type: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub autofill: String,
    #[serde(default)]
    pub history: Vec<HistoryEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub id: String,
    pub name: String,
    /// base64 payload — decoded bytes live only inside the XML layer
    pub data: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardLabel {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(rename = "type", default)]
    pub label_type: Option<String>,
    #[serde(default)]
    pub pin_to_top: bool,
    #[serde(default)]
    pub time_stamp: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ghost {
    pub id: i64,
    pub time: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Card {
    pub id: i64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub symbol: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub custom_icon_name: Option<String>,
    #[serde(default)]
    pub template: bool,
    #[serde(default)]
    pub autofill_enabled: bool,
    #[serde(default)]
    pub favorite: bool,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub trashed: bool,
    #[serde(default)]
    pub expiration: Option<f64>,
    #[serde(default)]
    pub reminder: Option<f64>,
    #[serde(default)]
    pub created: f64,
    #[serde(default)]
    pub modified: f64,
    #[serde(default)]
    pub use_website_icon: bool,
    #[serde(default)]
    pub watch: bool,
    #[serde(default)]
    pub fields: Vec<Field>,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub label_ids: Vec<i64>,
    #[serde(default)]
    pub images: Vec<Attachment>,
    #[serde(default)]
    pub files: Vec<Attachment>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PasswordDatabase {
    #[serde(default)]
    pub labels: Vec<CardLabel>,
    #[serde(default)]
    pub cards: Vec<Card>,
    #[serde(default)]
    pub ghosts: Vec<Ghost>,
}

#[allow(dead_code)]
impl PasswordDatabase {
    /// DatabaseAdapter fresh item id (max + 1, skipping used ids).
    pub fn next_item_id(&self) -> i64 {
        let mut id = 1;
        while self.is_used_item_id(id) {
            id += 1;
        }
        id
    }

    pub fn is_used_item_id(&self, id: i64) -> bool {
        self.cards.iter().any(|c| c.id == id)
            || self.labels.iter().any(|l| l.id == id)
            || self.ghosts.iter().any(|g| g.id == id)
    }

    /// XDatabase.mergeWithDatabase: — item-level merge for sync convergence:
    /// newest `modified`/`timeStamp` wins; tombstones suppress resurrection.
    pub fn merge_with(&mut self, other: &PasswordDatabase) {
        let ghost_ids: std::collections::HashSet<i64> = other
            .ghosts
            .iter()
            .chain(self.ghosts.iter())
            .map(|g| g.id)
            .collect();

        let mut by_label: std::collections::HashMap<i64, CardLabel> =
            self.labels.drain(..).map(|l| (l.id, l)).collect();
        for l in &other.labels {
            if ghost_ids.contains(&l.id) {
                continue;
            }
            if let Some(mine) = by_label.get(&l.id) {
                if mine.time_stamp >= l.time_stamp {
                    continue;
                }
            }
            by_label.insert(l.id, l.clone());
        }
        self.labels = {
            let mut v: Vec<CardLabel> = by_label.into_values().collect();
            v.sort_by_key(|l| l.id);
            v
        };

        let mut by_card: std::collections::HashMap<i64, Card> =
            self.cards.drain(..).map(|c| (c.id, c)).collect();
        for c in &other.cards {
            if ghost_ids.contains(&c.id) {
                continue;
            }
            if let Some(mine) = by_card.get(&c.id) {
                if mine.modified >= c.modified {
                    continue;
                }
            }
            by_card.insert(c.id, c.clone());
        }
        self.cards = {
            let mut v: Vec<Card> = by_card.into_values().collect();
            v.sort_by_key(|c| c.id);
            v
        };

        let mut by_ghost: std::collections::HashMap<i64, Ghost> =
            self.ghosts.drain(..).map(|g| (g.id, g)).collect();
        for g in &other.ghosts {
            by_ghost.insert(g.id, g.clone());
        }
        self.ghosts = {
            let mut v: Vec<Ghost> = by_ghost.into_values().collect();
            v.sort_by_key(|g| g.id);
            v
        };
    }
}
