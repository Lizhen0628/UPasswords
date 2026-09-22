// UPasswords — Safe.app (SafeInCloud) replica, Tauri 2 + Vue 3 rewrite.
mod cipher;
mod commands;
mod compromised;
mod keychain;
mod model;
mod store;
mod templates;
mod webdav;
mod xml;

use commands::StoreState;
use std::sync::Mutex;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(StoreState(Mutex::new(store::DatabaseStore::new())))
        .invoke_handler(tauri::generate_handler![
            commands::list_databases,
            commands::database_exists,
            commands::load_database,
            commands::save_database,
            commands::rename_database,
            commands::delete_database,
            commands::database_file_size,
            commands::backup_database,
            commands::list_backups,
            commands::restore_backup,
            commands::create_default_database,
            commands::parse_xml,
            commands::serialize_xml,
            commands::keychain_save_password,
            commands::keychain_save_biometric,
            commands::keychain_load_password,
            commands::keychain_load_biometric,
            commands::keychain_has_biometric,
            commands::keychain_remove_biometric,
            commands::keychain_erase,
            commands::fast_unlock_available,
            commands::webdav_test,
            commands::webdav_sync,
            commands::check_compromised,
            commands::copy_text,
            commands::pick_files,
            commands::save_text_file,
            commands::save_binary_file,
        ])
        .run(tauri::generate_context!())
        .expect("error while running UPasswords");
}
