import SwiftUI

/// A product list that pushes the product on narrow screens and shows it in a second column on wide ones
/// (unfolded iPhone Duo).
struct ProductSplitView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            content
                .navigationDestination(for: Product.self) { ProductDetailView(product: $0).id($0) }
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 420)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ContentUnavailableView("Select a product", systemImage: "bag",
                                   description: Text("Its live price and checkout show here."))
        }
        .navigationSplitViewStyle(.balanced)
    }
}
