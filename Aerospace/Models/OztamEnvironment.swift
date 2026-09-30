//
//  OztamEnvironment.swift
//  Aerospace
//
//  The two OzTAM Collection Service tail hosts oztail talks to, matching the
//  `s` / `p` modes of uap.oztail/runoztail.sh.
//

import Foundation

nonisolated enum OztamEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
    case staging
    case production

    var id: String { rawValue }

    var title: String {
        switch self {
        case .staging: return "Staging"
        case .production: return "Production"
        }
    }

    var hostString: String {
        switch self {
        case .staging: return "https://stail.oztam.com.au"
        case .production: return "https://tail.oztam.com.au"
        }
    }

    var host: URL {
        // Both literals are valid; the force-unwrap can never trip.
        URL(string: hostString)!
    }
}
