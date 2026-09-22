//! Compromised password check — mirrors Services/SecurityServices.swift
//! (CompromisedPasswordsSheetController / haveibeenpwned k-anonymity range
//! API: only the first 5 hex chars of each SHA-1 leave the machine). Falls
//! back to the embedded offline demo set when the network is unavailable.
use sha1::{Digest, Sha1};

pub const OFFLINE_DEMO_SET: &[&str] = &[
    "123456", "password", "123456789", "12345678", "12345", "1234567", "qwerty",
    "111111", "1234567890", "123123", "abc123", "1234", "password1", "iloveyou",
    "000000", "qwerty123", "1q2w3e4r", "admin", "qwertyuiop", "654321", "555555",
    "lovely", "7777777", "888888", "princess", "dragon", "sunshine", "master",
    "monkey", "letmein", "football", "shadow", "superman", "michael", "trustno1",
];

pub struct Result2 {
    pub compromised: Vec<String>,
    pub offline: bool,
}

fn sha1_hex(p: &str) -> String {
    let mut h = Sha1::new();
    h.update(p.as_bytes());
    h.finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub async fn check(passwords: Vec<String>, demo: bool) -> Result2 {
    if passwords.is_empty() {
        return Result2 { compromised: Vec::new(), offline: false };
    }
    if demo {
        let set: std::collections::HashSet<&str> = OFFLINE_DEMO_SET.iter().copied().collect();
        return Result2 {
            compromised: passwords.into_iter().filter(|p| set.contains(p.as_str())).collect(),
            offline: true,
        };
    }

    let hashes: Vec<(String, String)> = passwords.iter().map(|p| (p.clone(), sha1_hex(p))).collect();
    let mut by_prefix: std::collections::HashMap<String, Vec<usize>> = std::collections::HashMap::new();
    for (i, (_, hash)) in hashes.iter().enumerate() {
        by_prefix
            .entry(hash[..5].to_string())
            .or_default()
            .push(i);
    }

    let mut found: Vec<String> = Vec::new();
    let mut network_failure = false;

    for prefix in by_prefix.keys() {
        let Ok(client) = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .build()
        else {
            network_failure = true;
            continue;
        };
        let url = format!("https://api.pwnedpasswords.com/range/{prefix}");
        match client.get(&url).send().await {
            Ok(resp) if resp.status().as_u16() == 200 => {
                let body = resp.text().await.unwrap_or_default();
                let suffixes: std::collections::HashSet<String> = body
                    .lines()
                    .filter_map(|line| line.split(':').next().map(|s| s.to_uppercase()))
                    .collect();
                for i in &by_prefix[prefix] {
                    let (pw, hash) = &hashes[*i];
                    let suffix = hash[5..].to_uppercase();
                    if suffixes.contains(&suffix) {
                        found.push(pw.clone());
                    }
                }
            }
            _ => network_failure = true,
        }
    }

    if found.is_empty() && network_failure && !by_prefix.is_empty() {
        let set: std::collections::HashSet<&str> = OFFLINE_DEMO_SET.iter().copied().collect();
        return Result2 {
            compromised: passwords.into_iter().filter(|p| set.contains(p.as_str())).collect(),
            offline: true,
        };
    }
    Result2 { compromised: found, offline: false }
}
