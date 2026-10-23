import Foundation
import UPasswordsCore

extension AppContext {
    /// Updates the encrypted registration preference for every profile in this vault.
    /// - Parameter enabled: Whether registration forms can offer saved contact details.
    func setRegistrationAutofillEnabled(_ enabled: Bool) {
        settings.registrationAutofillEnabled = enabled
        for index in database.userProfiles.indices {
            database.userProfiles[index].registrationAutofillEnabled = enabled
            database.userProfiles[index].modified = max(
                Date().millis, database.userProfiles[index].modified + 1
            )
        }
        saveDebounced()
    }

    /// Saves personal information independently from password cards.
    /// - Parameter draft: Edited contact details; an empty draft removes the current profile.
    func savePersonalInfo(_ draft: PersonalInfoDraft) {
        let previous = database.userProfiles.first
        let enabled = previous?.registrationAutofillEnabled ?? settings.registrationAutofillEnabled
        if let profile = draft.makeProfile(autofillEnabled: enabled, updating: previous) {
            if previous != nil {
                database.userProfiles[0] = profile
            } else {
                database.userProfiles.append(profile)
            }
        } else if let previous {
            database.userProfiles.removeAll { $0.id == previous.id }
        }
        saveDebounced()
        Log.info("ui", "personal information saved records=\(database.userProfiles.count)")
    }

    /// Migrates old contact cards and consumes onboarding details after vault unlock.
    func savePendingPersonalInfoIfNeeded() {
        guard phase == .unlocked else { return }
        if database.migrateLegacyPersonalInfo() > 0 { saveDebounced() }
        guard let draft = pendingPersonalInfo else { return }
        pendingPersonalInfo = nil
        guard database.userProfiles.isEmpty else {
            Log.info("ui", "setup: personal information already exists in restored vault")
            return
        }
        savePersonalInfo(draft)
    }
}
