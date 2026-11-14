import SwiftUI

enum Route: Hashable {
    case library(MediaLibrary)
    case children(MediaItem)
    case favorites
    case servers
    case downloads
}

extension View {
    /// 所有 NavigationStack 共用的跳转目标
    func mediaDestinations() -> some View {
        navigationDestination(for: MediaItem.self) { item in
            if item.kind.isBrowsable {
                ItemsGridView(source: .children(item))
            } else {
                ItemDetailView(item: item)
            }
        }
        .navigationDestination(for: Route.self) { route in
            switch route {
            case let .library(library): ItemsGridView(source: .library(library))
            case let .children(item): ItemsGridView(source: .children(item))
            case .favorites: ItemsGridView(source: .favorites)
            case .servers: ServersView()
            case .downloads: DownloadsView()
            }
        }
    }
}
