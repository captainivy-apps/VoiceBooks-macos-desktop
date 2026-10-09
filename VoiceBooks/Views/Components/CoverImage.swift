import SwiftUI

/// Displays a book cover from a local file, falling back to a bundled default.
struct CoverImage: View {
    let coverPath: String?

    var body: some View {
        Group {
            if let coverPath, let image = NSImage(contentsOfFile: coverPath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }
}
