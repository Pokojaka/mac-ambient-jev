import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var statusText = "待機中"
}
