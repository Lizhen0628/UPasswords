import Foundation

/// Classifies download failures without persisting error text or sensitive request information.
public enum AttachmentDownloadFailure {
    /// Returns the retry category and a server-specified minimum delay.
    public static func classify(_ error: Error) -> (
        failure: AttachmentDownloadLedger.Failure, minimumDelay: TimeInterval
    ) {
        if let relayError = error as? RelayClient.RelayError {
            switch relayError {
            case .unauthorized:
                return (.authorization, 0)
            case .rateLimited(let retryAfter):
                return (.transient, TimeInterval(max(0, retryAfter)))
            case .network:
                return (.transient, 0)
            case .server(let status) where status >= 500 && status <= 599:
                return (.transient, 0)
            case .attachmentIntegrityFailure:
                return (.integrity, 0)
            case .notFound, .attachmentDeleted, .attachmentVersionMissing:
                return (.unavailable, 0)
            default:
                return (.permanent, 0)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
                return (.transient, 0)
            default:
                return (.permanent, 0)
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain,
           (error as NSError).code == NSFileWriteOutOfSpaceError {
            return (.storage, 0)
        }
        // Authentication/decryption failures must not create a background retry loop.
        return (.integrity, 0)
    }
}
