import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .playground
    
    enum Tab: String, CaseIterable {
        case playground = "Image Lab"
        case modelManagement = "Model Management"
        
        var icon: String {
            switch self {
            case .playground: return "paintpalette.fill"
            case .modelManagement: return "externaldrive.fill"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Content based on selected tab
            Group {
                switch selectedTab {
                case .playground:
                    ImageLabView()
                case .modelManagement:
                    ModelManagementView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                HStack {
                    Spacer()
                    Picker("", selection: $selectedTab) {
                        ForEach(MainTabView.Tab.allCases, id: \.self) { tab in
                            Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: 420)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    Spacer()
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.04), Color.mint.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()
        )
    }
}

// Remove custom slider; using native segmented control above

#Preview {
    MainTabView()
        .preferredColorScheme(.dark)
}
