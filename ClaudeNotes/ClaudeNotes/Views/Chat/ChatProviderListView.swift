import SwiftUI

struct ChatProviderListView: View {
    @Binding var selectedProvider: LLMProvider?
    let providers = LLMProvider.allProviders

    var body: some View {
        List(selection: $selectedProvider) {
            Section("AI 对话") {
                ForEach(providers) { provider in
                    ProviderRow(provider: provider)
                        .tag(provider)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Text("登录你的账号即可使用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("会话数据保存在本地")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct ProviderRow: View {
    let provider: LLMProvider

    var body: some View {
        Label {
            Text(provider.name)
        } icon: {
            Image(systemName: provider.iconName)
                .foregroundStyle(Color(hex: provider.colorHex) ?? .accentColor)
        }
    }
}

// MARK: - Color hex extension
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }
}
