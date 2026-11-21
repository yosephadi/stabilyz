import SwiftUI

/// One optional profile answer, edited on its own screen with onboarding's own
/// `ChoiceCard` and wording. The extra "Not set" row (or onboarding's
/// "I don't know" for K-level) clears the answer.
struct ProfileAnswerEditorView<Value: Hashable>: View {
    let title: String
    let options: [ChoiceCard<Value?>.Option]
    let selection: Value?
    let failure: StabilyzError?
    let choose: (Value?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x4) {
                ChoiceCard(
                    options: options,
                    selection: Binding(get: { selection }, set: { choose($0) })
                )

                if let failure, let presentation = ErrorPresenter.presentation(for: failure) {
                    Text(presentation.message)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.x4)
                }
            }
            .padding(.horizontal, Space.cardMargin)
            .padding(.vertical, Space.x6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(StabilyzColor.bgBase)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
