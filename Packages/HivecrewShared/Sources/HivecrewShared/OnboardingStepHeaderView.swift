import SwiftUI

public struct OnboardingStepHeaderView: View {
    private let systemImage: String
    private let tint: Color
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey

    public init(
        systemImage: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(tint)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 20)
    }
}
