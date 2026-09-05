import Foundation

enum UserRole: String, CaseIterable, Identifiable {
    case research = "research"
    case family = "family"
    case admin = "admin"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .research: return "研究端"
        case .family: return "家属端"
        case .admin: return "管理员端"
        }
    }
    
    var icon: String {
        switch self {
        case .research: return "doc.text.magnifyingglass"
        case .family: return "person.2.fill"
        case .admin: return "person.badge.key"
        }
    }
}
