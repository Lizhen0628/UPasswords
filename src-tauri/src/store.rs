//! Databases on disk — mirrors Services/DatabaseStore.swift (DatabaseManager +
//! DatabaseConfig). Root: `~/Library/Application Support/UPasswords/` (same
//! location as the Swift version, so databases are shared between builds).
use crate::cipher;
use crate::model::PasswordDatabase;
use crate::xml;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_millis() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DatabaseFile {
    pub name: String,
    pub file_name: String,
    pub created: f64,
}

pub struct DatabaseStore {
    pub root: PathBuf,
}

impl DatabaseStore {
    /// Errors localized on the frontend via the returned code strings.
    pub fn err(code: &str) -> String {
        code.to_string()
    }

    pub fn new() -> Self {
        let base = dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("UPasswords");
        let store = DatabaseStore { root: base };
        let _ = fs::create_dir_all(store.databases_dir());
        let _ = fs::create_dir_all(store.backups_dir());
        store
    }

    pub fn databases_dir(&self) -> PathBuf {
        self.root.join("Databases")
    }

    pub fn backups_dir(&self) -> PathBuf {
        self.root.join("Backups")
    }

    pub fn url_for(&self, name: &str) -> PathBuf {
        self.databases_dir().join(format!("{name}.upw"))
    }

    pub fn backup_dir_for(&self, name: &str) -> PathBuf {
        self.backups_dir().join(name)
    }

    pub fn list(&self) -> Vec<DatabaseFile> {
        let Ok(entries) = fs::read_dir(self.databases_dir()) else {
            return Vec::new();
        };
        let mut out: Vec<DatabaseFile> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().map(|x| x == "upw").unwrap_or(false))
            .map(|e| {
                let path = e.path();
                let name = path
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let created = e
                    .metadata()
                    .and_then(|m| m.created())
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_millis() as f64)
                    .unwrap_or(0.0);
                DatabaseFile {
                    file_name: path
                        .file_name()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    name,
                    created,
                }
            })
            .collect();
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    pub fn exists(&self, name: &str) -> bool {
        self.url_for(name).exists()
    }

    pub fn file_size(&self, name: &str) -> Result<u64, String> {
        fs::metadata(self.url_for(name)).map(|m| m.len()).map_err(|_| Self::err("DATABASE_NOT_FOUND"))
    }

    pub fn load(&self, name: &str, password: &str) -> Result<PasswordDatabase, String> {
        let data = fs::read(self.url_for(name)).map_err(|_| Self::err("DATABASE_NOT_FOUND"))?;
        let plain = cipher::decrypt(&data, password, "WRONG_PASSWORD")?;
        let text = String::from_utf8(plain).map_err(|_| Self::err("WRONG_FORMAT"))?;
        xml::parse(&text)
    }

    pub fn save(&self, db: &PasswordDatabase, name: &str, password: &str) -> Result<(), String> {
        let xml_text = xml::serialize(db);
        let enc = cipher::encrypt(xml_text.as_bytes(), password)?;
        let tmp = self.url_for(name).with_extension("upw.tmp");
        fs::write(&tmp, &enc).map_err(|e| format!("IO: {e}"))?;
        fs::rename(&tmp, self.url_for(name)).map_err(|e| format!("IO: {e}"))?;
        Ok(())
    }

    pub fn rename(&self, old: &str, new: &str) -> Result<(), String> {
        if !self.exists(old) {
            return Err(Self::err("DATABASE_NOT_FOUND"));
        }
        if self.exists(new) {
            return Err(Self::err("DATABASE_EXISTS"));
        }
        validate_name(new)?;
        fs::rename(self.url_for(old), self.url_for(new)).map_err(|e| format!("IO: {e}"))?;
        // move backups alongside
        let from = self.backup_dir_for(old);
        if from.exists() {
            let _ = fs::rename(&from, self.backup_dir_for(new));
        }
        Ok(())
    }

    pub fn delete(&self, name: &str) -> Result<(), String> {
        if !self.exists(name) {
            return Ok(());
        }
        fs::remove_file(self.url_for(name)).map_err(|e| format!("IO: {e}"))?;
        let _ = fs::remove_dir_all(self.backup_dir_for(name));
        Ok(())
    }

    // ----- Auto backup (BackupDatabaseTask / AutoBackupModel) -----

    pub fn backup(&self, name: &str) -> Result<(), String> {
        let dir = self.backup_dir_for(name);
        fs::create_dir_all(&dir).map_err(|e| format!("IO: {e}"))?;
        let data = fs::read(self.url_for(name)).map_err(|_| Self::err("DATABASE_NOT_FOUND"))?;
        let stamp = backup_stamp(now_millis());
        fs::write(dir.join(format!("{stamp}.upw")), &data).map_err(|e| format!("IO: {e}"))?;
        self.prune_backups(name, 10);
        Ok(())
    }

    pub fn backups(&self, name: &str) -> Vec<(String, f64)> {
        let dir = self.backup_dir_for(name);
        let Ok(entries) = fs::read_dir(&dir) else {
            return Vec::new();
        };
        let mut out: Vec<(String, f64)> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().map(|x| x == "upw").unwrap_or(false))
            .map(|e| {
                let path = e.path();
                let modified = e
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_millis() as f64)
                    .unwrap_or(0.0);
                (
                    path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default(),
                    modified,
                )
            })
            .collect();
        out.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        out
    }

    fn prune_backups(&self, name: &str, keep: usize) {
        let all = self.backups(name);
        if all.len() > keep {
            for (file, _) in all.into_iter().skip(keep) {
                let _ = fs::remove_file(self.backup_dir_for(name).join(file));
            }
        }
    }

    pub fn restore(&self, name: &str, backup_file: &str) -> Result<(), String> {
        let path: PathBuf = self.backup_dir_for(name).join(backup_file);
        let data = fs::read(&path).map_err(|_| Self::err("DATABASE_NOT_FOUND"))?;
        if !cipher::check_magic(&data) {
            return Err(Self::err("WRONG_FORMAT"));
        }
        fs::write(self.url_for(name), &data).map_err(|e| format!("IO: {e}"))?;
        Ok(())
    }
}

pub fn validate_name(name: &str) -> Result<(), String> {
    let valid = !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric());
    if valid {
        Ok(())
    } else {
        Err(DatabaseStore::err("DATABASE_NAME"))
    }
}

/// yyyyMMdd-HHmmss in UTC — matches the Swift backupStampFormatter shape.
fn backup_stamp(millis: f64) -> String {
    let secs = (millis / 1000.0) as i64;
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}{m:02}{d:02}-{h:02}{mi:02}{s:02}")
}

/// Howard Hinnant's civil_from_days.
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}
