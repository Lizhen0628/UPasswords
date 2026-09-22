//! WebDAV driver — mirrors Services/CloudSync.swift (WebDavDriver / SyncTask):
//! PROPFIND/MKCOL test, GET download, PUT upload of the encrypted container,
//! with an item-level merge when both sides changed.
use crate::cipher;
use crate::model::PasswordDatabase;
use crate::xml;
use reqwest::Method;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavSettings {
    #[serde(default)]
    pub host: String,
    #[serde(default = "default_port")]
    pub port: i64,
    #[serde(default = "default_https")]
    pub use_https: bool,
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub password: String,
    #[serde(default = "default_path")]
    pub path: String,
}

fn default_port() -> i64 {
    443
}
fn default_https() -> bool {
    true
}
fn default_path() -> String {
    "/UPasswords/".into()
}

impl WebDavSettings {
    fn base_url(&self) -> Result<String, String> {
        if self.host.is_empty() {
            return Err("BAD_URL".into());
        }
        let scheme = if self.use_https { "https" } else { "http" };
        let default_port = if self.use_https { 443 } else { 80 };
        let mut p = self.path.clone();
        if !p.starts_with('/') {
            p = format!("/{p}");
        }
        let p = p.trim_matches('/');
        let port = if self.port != default_port && self.port > 0 {
            format!(":{}", self.port)
        } else {
            String::new()
        };
        Ok(format!("{scheme}://{}{port}/{p}", self.host))
    }

    fn auth_header(&self) -> String {
        use base64::Engine;
        let cred = format!("{}:{}", self.user, self.password);
        format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(cred))
    }
}

fn client() -> Result<Client, String> {
    Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("HTTP: {e}"))
}

fn http_error(status: u16) -> String {
    match status {
        401 => "WEBDAV_401".into(),
        405 => "WEBDAV_405".into(),
        code => format!("SYNC_HTTP_{code}"),
    }
}

pub async fn test_connection(settings: &WebDavSettings, database_name: &str) -> Result<(), String> {
    let base = settings.base_url()?;
    let c = client()?;
    // PROPFIND the folder
    let req = c
        .request(Method::from_bytes(b"PROPFIND").unwrap(), &base)
        .header("Authorization", settings.auth_header())
        .header("Depth", "0");
    let resp = req.send().await.map_err(|_| "NETWORK".to_string())?;
    match resp.status().as_u16() {
        401 => return Err(http_error(401)),
        s if !(200..300).contains(&s) && s != 404 => return Err(http_error(s)),
        404 => {
            // create the folder (MKCOL)
            let mk = c
                .request(Method::from_bytes(b"MKCOL").unwrap(), &base)
                .header("Authorization", settings.auth_header());
            let resp2 = mk.send().await.map_err(|_| "NETWORK".to_string())?;
            let s2 = resp2.status().as_u16();
            if !(200..300).contains(&s2) && s2 != 405 && s2 != 301 {
                return Err(http_error(s2));
            }
        }
        _ => {}
    }
    let _ = database_name;
    Ok(())
}

async fn download(settings: &WebDavSettings, database_name: &str) -> Result<Option<Vec<u8>>, String> {
    let url = format!("{}/{}.upw", settings.base_url()?, database_name);
    let c = client()?;
    let resp = c
        .get(&url)
        .header("Authorization", settings.auth_header())
        .send()
        .await
        .map_err(|_| "NETWORK".to_string())?;
    match resp.status().as_u16() {
        404 => Ok(None),
        s if (200..300).contains(&s) => Ok(Some(resp.bytes().await.map_err(|_| "NETWORK".to_string())?.to_vec())),
        s => Err(http_error(s)),
    }
}

async fn upload(settings: &WebDavSettings, database_name: &str, data: &[u8]) -> Result<(), String> {
    let url = format!("{}/{}.upw", settings.base_url()?, database_name);
    let c = client()?;
    let resp = c
        .put(&url)
        .header("Authorization", settings.auth_header())
        .header("Content-Type", "application/octet-stream")
        .body(data.to_vec())
        .send()
        .await
        .map_err(|_| "NETWORK".to_string())?;
    let s = resp.status().as_u16();
    if (200..300).contains(&s) {
        Ok(())
    } else {
        Err(http_error(s))
    }
}

pub struct SyncOutcome {
    pub merged: PasswordDatabase,
    pub changed: bool,
}

/// Full sync: download → decrypt → merge → serialize → upload.
pub async fn sync(
    settings: &WebDavSettings,
    database_name: &str,
    password: &str,
    local: &PasswordDatabase,
) -> Result<SyncOutcome, String> {
    test_connection(settings, database_name).await?;
    let mut merged = local.clone();
    let mut changed = false;
    if let Some(remote_data) = download(settings, database_name).await? {
        let plain = cipher::decrypt(&remote_data, password, "WRONG_PASSWORD")?;
        let text = String::from_utf8(plain).map_err(|_| "WRONG_FORMAT".to_string())?;
        let remote = xml::parse(&text)?;
        merged.merge_with(&remote);
        changed = true;
    }
    let out = cipher::encrypt(xml::serialize(&merged).as_bytes(), password)?;
    upload(settings, database_name, &out).await?;
    Ok(SyncOutcome { merged, changed })
}
