import SwiftUI

/// Shown on the phone side until a device is open.
struct ConnectView: View {
    @Environment(AppModel.self) private var model

    private var blockedLabel: String? {
        if case .blocked(let label) = model.phase { return label }
        return nil
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill((blockedLabel == nil ? Color.green : Color.orange).opacity(0.12))
                    .frame(width: 132, height: 132)
                Circle()
                    .strokeBorder((blockedLabel == nil ? Color.green : Color.orange).opacity(0.25), lineWidth: 1)
                    .frame(width: 168, height: 168)
                Image(systemName: blockedLabel == nil ? "cable.connector.horizontal" : "exclamationmark.lock.fill")
                    .font(.system(size: 50, weight: .regular))
                    .foregroundStyle(blockedLabel == nil ? Color.green : Color.orange)
                    .symbolEffect(.pulse, options: .repeating, isActive: blockedLabel == nil)
            }

            VStack(spacing: 6) {
                Text(blockedLabel == nil ? "Connect your Android phone" : "\(blockedLabel!) is busy")
                    .font(.title2.weight(.semibold))
                Text(blockedLabel == nil
                     ? "Ferry finds your phone automatically as soon as it's plugged in."
                     : "Ferry can see your phone but can't open it yet.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Step(number: 1, text: "Plug the phone into your Mac with a USB cable.")
                Step(number: 2, text: "Unlock the phone.")
                Step(number: 3, text: "Tap the **USB** notification and choose **File transfer**.")
                if blockedLabel != nil {
                    Step(number: 4, text: "Quit any other app that uses the phone (Android File Transfer, OpenMTP, Image Capture).")
                }
            }
            .padding(18)
            .frame(maxWidth: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))

            if blockedLabel != nil {
                Button {
                    model.freeUpUSB()
                } label: {
                    Label("Quit Apps Holding the Phone", systemImage: "bolt.horizontal.circle")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .help("Quits Android File Transfer, OpenMTP and the macOS camera service (it restarts on its own)")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
