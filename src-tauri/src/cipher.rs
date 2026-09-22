//! Encrypted database container — mirrors Services/DatabaseCipher.swift.
//! The exact cipher parameters of the original SafeInCloud binary are not
//! recoverable; both the Swift replica and this rewrite use the modern
//! equivalent PBKDF2-SHA256 × 310,000 + AES-256-GCM, so `.upw` files created
//! by the Swift version open here unchanged.
//!
//! Container layout (little-endian fixed fields + ciphertext):
//! ```text
//! offset 0  : magic "UPWDB1\0\0"        (8 bytes)
//! offset 8  : format version            (UInt32)
//! offset 12 : PBKDF2 iterations          (UInt32)
//! offset 16 : salt                       (16 bytes)
//! offset 32 : AES-GCM sealed box         (nonce 12 + ct + tag 16)
//! ```
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use rand::RngCore;

pub const MAGIC: &[u8; 8] = b"UPWDB1\0\0";
pub const VERSION: u32 = 1;
pub const SALT_LENGTH: usize = 16;
pub const ITERATIONS: u32 = 310_000;
const KEY_LEN: usize = 32;

fn derive_key(password: &str, salt: &[u8], iterations: u32) -> [u8; KEY_LEN] {
    use sha2::Sha256;
    let mut out = [0u8; KEY_LEN];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, iterations, &mut out);
    out
}

pub fn encrypt(plaintext: &[u8], password: &str) -> Result<Vec<u8>, String> {
    let mut salt = [0u8; SALT_LENGTH];
    rand::rngs::OsRng.fill_bytes(&mut salt);
    let key = derive_key(password, &salt, ITERATIONS);
    let cipher = Aes256Gcm::new((&key).into());
    let mut nonce_bytes = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|_| "AES-GCM seal failed".to_string())?;

    let mut out = Vec::with_capacity(8 + 4 + 4 + SALT_LENGTH + 12 + ciphertext.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&ITERATIONS.to_le_bytes());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

pub fn decrypt(data: &[u8], password: &str, wrong_password_msg: &str) -> Result<Vec<u8>, String> {
    if !check_magic(data) {
        return Err("WRONG_FORMAT".into());
    }
    let iters = u32::from_le_bytes(data[12..16].try_into().map_err(|_| "WRONG_FORMAT")?);
    let salt = &data[16..16 + SALT_LENGTH];
    let box_start = 16 + SALT_LENGTH;
    let nonce_bytes: [u8; 12] = data[box_start..box_start + 12]
        .try_into()
        .map_err(|_| "WRONG_FORMAT")?;
    let ciphertext = &data[box_start + 12..];
    let key = derive_key(password, salt, iters);
    let cipher = Aes256Gcm::new((&key).into());
    cipher
        .decrypt(Nonce::from_slice(&nonce_bytes), ciphertext)
        .map_err(|_| wrong_password_msg.to_string())
}

pub fn check_magic(data: &[u8]) -> bool {
    data.len() >= 16 + SALT_LENGTH && &data[..8] == MAGIC
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn container_roundtrip() {
        let plaintext = b"<?xml version=\"1.0\"?><database></database>";
        let enc = encrypt(plaintext, "swordfish").unwrap();
        assert!(check_magic(&enc));
        let dec = decrypt(&enc, "swordfish", "wrong").unwrap();
        assert_eq!(dec, plaintext);
        assert!(decrypt(&enc, "other", "WRONG_PASSWORD").unwrap_err().contains("WRONG_PASSWORD"));
    }
}
