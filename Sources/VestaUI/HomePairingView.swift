import SwiftUI

public struct HomePairingView: View {
    @State private var controller = PairingController()
    private let paired: () -> Void
    public init(paired: @escaping () -> Void) { self.paired = paired }
    public var body: some View {
        PairingView(controller: controller, onPaired: paired)
            .onDisappear { controller.cancel() }
    }
}
