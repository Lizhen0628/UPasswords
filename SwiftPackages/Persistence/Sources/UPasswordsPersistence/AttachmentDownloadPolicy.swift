import Foundation

/// Network classes used to decide whether an automatic attachment transfer may start.
public enum AttachmentNetworkKind: Equatable {
    case wifi
    case wired
    case cellular
    case unknown
}

/// Current connectivity facts relevant to attachment transfer policy.
public struct AttachmentNetworkState: Equatable {
    /// Whether the system reports a usable network path.
    public let isAvailable: Bool
    /// Best-known interface class when a path is available.
    public let kind: AttachmentNetworkKind
    /// Whether the system marks the path as constrained or low-data.
    public let isConstrained: Bool

    /// Creates a network state snapshot.
    public init(isAvailable: Bool, kind: AttachmentNetworkKind, isConstrained: Bool) {
        self.isAvailable = isAvailable
        self.kind = kind
        self.isConstrained = isConstrained
    }

    /// No path classification is available yet.
    public static let unknown = AttachmentNetworkState(
        isAvailable: false, kind: .unknown, isConstrained: false)
}

/// Shared policy for background and user-prioritized attachment downloads.
public enum AttachmentDownloadPolicy {
    /// Whether background hydration may use this path under the user's settings.
    public static func allowsBackground(
        on network: AttachmentNetworkState,
        allowsCellular: Bool,
        allowsUnknown: Bool
    ) -> Bool {
        guard network.isAvailable, !network.isConstrained else { return false }
        switch network.kind {
        case .wifi, .wired:
            return true
        case .cellular:
            return allowsCellular
        case .unknown:
            return allowsUnknown
        }
    }

    /// Explicitly opening an item may use any currently available network path.
    public static func allowsPrioritized(_ network: AttachmentNetworkState) -> Bool {
        network.isAvailable
    }
}

/// Serial, deduplicating queue shared by native attachment download workers.
public struct AttachmentDownloadQueue: Equatable {
    /// A card selected for the next download.
    public struct Entry: Equatable {
        /// Stable card identity.
        public let cardID: UUID
        /// Whether the card was promoted by an explicit user action.
        public let isPrioritized: Bool
    }

    /// Creates an empty serial download queue.
    public init() {}

    private(set) var queuedCardIDs: [UUID] = []
    private(set) var prioritizedCardIDs = Set<UUID>()
    public private(set) var inFlightCardID: UUID?
    public private(set) var inFlightIsPrioritized = false
    private var inFlightWasCancelled = false

    /// Whether there is queued work waiting for the serial worker.
    public var isEmpty: Bool { queuedCardIDs.isEmpty }
    /// Identity of the next queued card, if any.
    public var firstCardID: UUID? { queuedCardIDs.first }

    /// Whether a queued card has explicit user priority.
    public func isPrioritized(_ cardID: UUID) -> Bool {
        prioritizedCardIDs.contains(cardID)
    }

    /// Whether this card currently owns an uncancelled worker slot.
    public func isActive(cardID: UUID) -> Bool {
        inFlightCardID == cardID && !inFlightWasCancelled
    }

    /// Adds a card once, moving explicitly requested work ahead of background work.
    public mutating func enqueue(cardID: UUID, prioritized: Bool) {
        if inFlightCardID == cardID, !inFlightWasCancelled {
            if prioritized { inFlightIsPrioritized = true }
            return
        }
        queuedCardIDs.removeAll { $0 == cardID }
        if prioritized {
            prioritizedCardIDs.insert(cardID)
            queuedCardIDs.insert(cardID, at: 0)
        } else if prioritizedCardIDs.contains(cardID) {
            queuedCardIDs.insert(cardID, at: 0)
        } else {
            queuedCardIDs.append(cardID)
        }
    }

    /// Promotes a queued card or upgrades the currently running card.
    public mutating func prioritize(cardID: UUID) {
        enqueue(cardID: cardID, prioritized: true)
    }

    /// Starts the next queued card when no other card is in flight.
    public mutating func takeNext() -> Entry? {
        guard inFlightCardID == nil, !queuedCardIDs.isEmpty else { return nil }
        let cardID = queuedCardIDs.removeFirst()
        let prioritized = prioritizedCardIDs.remove(cardID) != nil
        inFlightCardID = cardID
        inFlightIsPrioritized = prioritized
        return Entry(cardID: cardID, isPrioritized: prioritized)
    }

    /// Returns the current transfer to the front of the queue after a policy pause.
    public mutating func requeueInFlight() {
        guard let cardID = inFlightCardID, !inFlightWasCancelled else { return }
        let prioritized = inFlightIsPrioritized
        inFlightCardID = nil
        inFlightIsPrioritized = false
        inFlightWasCancelled = false
        enqueue(cardID: cardID, prioritized: prioritized)
    }

    /// Marks the active transfer cancelled but keeps its slot until the worker unwinds.
    public mutating func cancelInFlight() {
        guard inFlightCardID != nil else { return }
        inFlightWasCancelled = true
    }

    /// Marks a completed or cancelled transfer as no longer in flight.
    public mutating func finish(cardID: UUID) {
        guard inFlightCardID == cardID else { return }
        inFlightCardID = nil
        inFlightIsPrioritized = false
        inFlightWasCancelled = false
    }

    /// Clears queued work while allowing a cancelled in-flight request to unwind safely.
    public mutating func removeAll() {
        queuedCardIDs.removeAll()
        prioritizedCardIDs.removeAll()
    }
}
