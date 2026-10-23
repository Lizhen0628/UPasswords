import Foundation
import UPasswordsCore

extension Vault {
    /// Saves personal information separately from password cards.
    /// - Parameter draft: Edited contact details; an empty draft removes the current profile.
    func savePersonalInfo(_ draft: PersonalInfoDraft) {
        let previous = database.userProfiles.first
        let enabled = previous?.registrationAutofillEnabled ?? registrationAutofillEnabled
        if let profile = draft.makeProfile(autofillEnabled: enabled, updating: previous) {
            if previous != nil {
                database.userProfiles[0] = profile
            } else {
                database.userProfiles.append(profile)
            }
        } else if let previous {
            database.userProfiles.removeAll { $0.id == previous.id }
        }
        persist()
        Log.info("ui", "ios personal information saved records=\(database.userProfiles.count)")
    }

    /// Migrates old contact cards and consumes onboarding details after vault unlock.
    func savePendingPersonalInfoIfNeeded() {
        guard !locked else { return }
        if database.migrateLegacyPersonalInfo() > 0 { persist() }
        guard let draft = pendingPersonalInfo else { return }
        pendingPersonalInfo = nil
        guard database.userProfiles.isEmpty else {
            Log.info("ui", "ios setup: personal information already exists in restored vault")
            return
        }
        savePersonalInfo(draft)
    }
}
