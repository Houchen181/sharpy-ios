import SafariServices
import SwiftUI

enum Palette {
    static let correct = Color(red: 0.13, green: 0.66, blue: 0.38)
    static let wrong = Color(red: 0.89, green: 0.26, blue: 0.27)
    static let trap = Color(red: 0.96, green: 0.58, blue: 0.08)
    static let flame = Color(red: 1.0, green: 0.48, blue: 0.1)
    static let card = Color(.secondarySystemGroupedBackground)
    static let page = Color(.systemGroupedBackground)
}

/// Lays out children left to right, wrapping onto new rows (topic chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct Chip: View {
    let text: String
    var selected = false
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption.weight(.bold)) }
            Text(text)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
        .foregroundStyle(selected ? Color.white : Color.accentColor)
    }
}

struct StreakBadge: View {
    let streak: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
            Text("\(streak)").monospacedDigit()
        }
        .font(.headline)
        .foregroundStyle(streak > 0 ? Palette.flame : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((streak > 0 ? Palette.flame : Color.secondary).opacity(0.14), in: Capsule())
        .accessibilityLabel("\(streak)-day streak")
    }
}

/// One cited source: publisher, page title and the exact excerpt. Tapping opens the page.
struct SourceRow: View {
    let source: ItemSource
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
                    Text(source.publisher).font(.caption.weight(.semibold))
                    Text("·").foregroundStyle(.secondary)
                    Text(source.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                }
                if !source.quote.isEmpty {
                    Text("“\(source.quote)”")
                        .font(.footnote)
                        .italic()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            if let url = URL(string: source.url) {
                SafariView(url: url).ignoresSafeArea()
            }
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Large rounded button used for the main actions.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
