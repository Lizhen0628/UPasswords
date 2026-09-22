//! OS keychain — mirrors Services/PasswordStore.swift. Uses the same service
//! (`UPasswords-<database>`) and account names ("database" / "biometric") as
//! the Swift version, so existing keychain entries remain readable.
//! Note: the keyring crate cannot attach a `userPresence` access control, so
//! the "biometric" entry is a plain keychain item here (documented difference).
use keyring::Entry;

fn service(database_name: &str) -> String {
    format!("UPasswords-{database_name}")
}

pub fn save_password(name: &str, password: &str) -> Result<(), String> {
    let entry = Entry::new(&service(name), "database").map_err(|e| e.to_string())?;
    entry.set_password(password).map_err(|e| e.to_string())
}

pub fn save_biometric(name: &str, password: &str) -> Result<(), String> {
    let entry = Entry::new(&service(name), "biometric").map_err(|e| e.to_string())?;
    entry.set_password(password).map_err(|e| e.to_string())
}

pub fn load_password(name: &str) -> Option<String> {
    let entry = Entry::new(&service(name), "database").ok()?;
    entry.get_password().ok()
}

pub fn load_biometric(name: &str) -> Option<String> {
    let entry = Entry::new(&service(name), "biometric").ok()?;
    entry.get_password().ok()
}

pub fn has_biometric(name: &str) -> bool {
    load_biometric(name).is_some()
}

pub fn remove_biometric(name: &str) -> Result<(), String> {
    let entry = Entry::new(&service(name), "biometric").map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

pub fn erase(name: &str) {
    for account in ["database", "biometric"] {
        if let Ok(entry) = Entry::new(&service(name), account) {
            let _ = entry.delete_credential();
        }
    }
}
