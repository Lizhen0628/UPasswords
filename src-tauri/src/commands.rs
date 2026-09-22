//! Tauri command surface — one command per DatabaseStore / PasswordStore /
//! WebDavDriver / CompromisedService entry point of the Swift version.
//! Error strings are localization CODES resolved on the frontend.
use crate::compromised;
use crate::keychain;
use crate::model::PasswordDatabase;
use crate::store::{DatabaseFile, DatabaseStore};
use crate::webdav::{self, WebDavSettings};
use crate::xml;
use base64::Engine;
use serde::Serialize;
use std::sync::Mutex;
use tauri::AppHandle;
use tauri::State;
use tauri_plugin_dialog::DialogExt;

pub struct StoreState(pub Mutex<DatabaseStore>);

fn store<'a>(state: &'a State<'a, StoreState>) -> std::sync::MutexGuard<'a, DatabaseStore> {
    state.0.lock().unwrap()
}

// ----- DatabaseStore -----

#[tauri::command]
pub fn list_databases(state: State<StoreState>) -> Vec<DatabaseFile> {
    store(&state).list()
}

#[tauri::command]
pub fn database_exists(state: State<StoreState>, name: String) -> bool {
    store(&state).exists(&name)
}

#[tauri::command]
pub fn load_database(state: State<StoreState>, name: String, password: String) -> Result<PasswordDatabase, String> {
    store(&state).load(&name, &password)
}

#[tauri::command]
pub fn save_database(state: State<StoreState>, db_json: PasswordDatabase, name: String, password: String) -> Result<(), String> {
    store(&state).save(&db_json, &name, &password)
}

#[tauri::command]
pub fn rename_database(state: State<StoreState>, old_name: String, new_name: String) -> Result<(), String> {
    let saved_password = {
        let s = store(&state);
        s.rename(&old_name, &new_name)?;
        keychain::load_password(&old_name)
    };
    if let Some(pw) = saved_password {
        let _ = keychain::save_password(&new_name, &pw);
        if keychain::has_biometric(&old_name) {
            let _ = keychain::save_biometric(&new_name, &pw);
        }
    }
    keychain::erase(&old_name);
    Ok(())
}

#[tauri::command]
pub fn delete_database(state: State<StoreState>, name: String) -> Result<(), String> {
    store(&state).delete(&name)?;
    keychain::erase(&name);
    Ok(())
}

#[tauri::command]
pub fn database_file_size(state: State<StoreState>, name: String) -> Result<u64, String> {
    store(&state).file_size(&name)
}

// ----- Backups -----

#[tauri::command]
pub fn backup_database(state: State<StoreState>, name: String) -> Result<(), String> {
    store(&state).backup(&name)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupEntry {
    pub file_name: String,
    pub created: f64,
}

#[tauri::command]
pub fn list_backups(state: State<StoreState>, name: String) -> Vec<BackupEntry> {
    store(&state)
        .backups(&name)
        .into_iter()
        .map(|(file_name, created)| BackupEntry { file_name, created })
        .collect()
}

#[tauri::command]
pub fn restore_backup(state: State<StoreState>, name: String, file_name: String) -> Result<(), String> {
    store(&state).restore(&name, &file_name)
}

/// Builds a fresh default database (15 templates + default labels). Names use
/// `@string/` references which the frontend resolves before first save — the
/// same values the original's Resources/database.xml ships.
#[tauri::command]
pub fn create_default_database() -> PasswordDatabase {
    let now = crate::store::now_millis();
    let mut db = PasswordDatabase::default();
    for (key, id, label_type) in [
        ("@string/busines_label", 1i64, None),
        ("@string/private_label", 2, None),
        ("@string/web_accounts_label", 4, Some("web_accounts")),
    ] {
        db.labels.push(crate::model::CardLabel {
            id,
            name: key.to_string(),
            label_type: label_type.map(|s| s.to_string()),
            color: None,
            pin_to_top: false,
            time_stamp: now,
        });
    }
    db.cards = crate::templates::template_cards(now);
    db
}

// ----- XML exchange format -----

#[tauri::command]
pub fn parse_xml(text: String) -> Result<PasswordDatabase, String> {
    xml::parse(&text)
}

#[tauri::command]
pub fn serialize_xml(db_json: PasswordDatabase) -> String {
    xml::serialize(&db_json)
}

// ----- Keychain (PasswordStore) -----

#[tauri::command]
pub fn keychain_save_password(name: String, password: String) -> Result<(), String> {
    keychain::save_password(&name, &password)
}

#[tauri::command]
pub fn keychain_save_biometric(name: String, password: String) -> Result<(), String> {
    keychain::save_biometric(&name, &password)
}

#[tauri::command]
pub fn keychain_load_password(name: String) -> Option<String> {
    keychain::load_password(&name)
}

#[tauri::command]
pub fn keychain_load_biometric(name: String) -> Option<String> {
    keychain::load_biometric(&name)
}

#[tauri::command]
pub fn keychain_has_biometric(name: String) -> bool {
    keychain::has_biometric(&name)
}

#[tauri::command]
pub fn keychain_remove_biometric(name: String) -> Result<(), String> {
    keychain::remove_biometric(&name)
}

#[tauri::command]
pub fn keychain_erase(name: String) {
    keychain::erase(&name)
}

#[tauri::command]
pub fn fast_unlock_available(name: String) -> bool {
    keychain::has_biometric(&name)
}

// ----- WebDAV -----

#[tauri::command]
pub async fn webdav_test(settings: WebDavSettings, database_name: String) -> Result<(), String> {
    webdav::test_connection(&settings, &database_name).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncOutcomeJson {
    pub merged: PasswordDatabase,
    pub changed: bool,
}

#[tauri::command]
pub async fn webdav_sync(
    settings: WebDavSettings,
    database_name: String,
    password: String,
    local_json: PasswordDatabase,
) -> Result<SyncOutcomeJson, String> {
    let out = webdav::sync(&settings, &database_name, &password, &local_json).await?;
    Ok(SyncOutcomeJson { merged: out.merged, changed: out.changed })
}

// ----- Compromised passwords -----

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompromisedJson {
    pub compromised: Vec<String>,
    pub offline: bool,
}

#[tauri::command]
pub async fn check_compromised(passwords: Vec<String>, demo: bool) -> CompromisedJson {
    let r = compromised::check(passwords, demo).await;
    CompromisedJson { compromised: r.compromised, offline: r.offline }
}

// ----- Clipboard (ClipboardModel: copy + auto-clear) -----

#[tauri::command]
pub fn copy_text(app: AppHandle, text: String, clear_seconds: i64) -> Result<(), String> {
    {
        let mut cb = arboard::Clipboard::new().map_err(|e| e.to_string())?;
        cb.set_text(text.clone()).map_err(|e| e.to_string())?;
    }
    if clear_seconds > 0 {
        let expected = text;
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(clear_seconds as u64));
            // NSPasteboard must be touched on the main thread on macOS; clear
            // only when the clipboard still holds what we wrote.
            let _ = app.run_on_main_thread(move || {
                if let Ok(mut cb) = arboard::Clipboard::new() {
                    if cb.get_text().map(|cur| cur == expected).unwrap_or(false) {
                        let _ = cb.clear();
                    }
                }
            });
        });
    }
    Ok(())
}

// ----- File panels (NSOpenPanel / NSSavePanel equivalents) -----

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PickedFile {
    pub name: String,
    pub data: String,
    pub length: u64,
}

#[tauri::command]
pub async fn pick_files(app: AppHandle, filter_kind: String) -> Result<Vec<PickedFile>, String> {
    let mut dialog = app.dialog().file();
    match filter_kind.as_str() {
        "image" => dialog = dialog.add_filter("Images", &["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]),
        "text" => dialog = dialog.add_filter("Text", &["csv", "txt", "tsv"]),
        "xml" => dialog = dialog.add_filter("Data", &["xml", "json", "csv", "txt", "tsv"]),
        _ => dialog = dialog.add_filter("Files", &["*"]),
    }
    let Some(paths) = dialog.blocking_pick_files() else {
        return Ok(Vec::new());
    };
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut out = Vec::new();
    for p in paths {
        let path = p.into_path().map_err(|e| e.to_string())?;
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        out.push(PickedFile {
            name: path
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default(),
            length: bytes.len() as u64,
            data: b64.encode(bytes),
        });
    }
    Ok(out)
}

#[tauri::command]
pub async fn save_text_file(app: AppHandle, default_name: String, text: String) -> Result<Option<String>, String> {
    let Some(file) = app
        .dialog()
        .file()
        .set_file_name(default_name)
        .blocking_save_file()
    else {
        return Ok(None);
    };
    let path = file.into_path().map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| format!("IO: {e}"))?;
    Ok(Some(
        path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default(),
    ))
}

#[tauri::command]
pub async fn save_binary_file(app: AppHandle, default_name: String, base64_data: String) -> Result<Option<String>, String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(base64_data)
        .map_err(|e| e.to_string())?;
    let Some(file) = app
        .dialog()
        .file()
        .set_file_name(default_name)
        .blocking_save_file()
    else {
        return Ok(None);
    };
    let path = file.into_path().map_err(|e| e.to_string())?;
    std::fs::write(&path, bytes).map_err(|e| format!("IO: {e}"))?;
    Ok(Some(
        path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default(),
    ))
}
