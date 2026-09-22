import AppKit
import SwiftUI

@MainActor
struct GatewayDoctorView: View {
    @Bindable var store: GatewayStore
    var supervisor: GatewaySupervisor = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 8) {
                ForEach(store.doctorChecks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(check.isSuccess ? .green : .orange)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(check.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.codexInk)
                                    .lineLimit(1)
                                Spacer()
                                Text(check.status)
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(check.isSuccess ? Color.green.opacity(0.12) : Color.orange.opacity(0.12), in: Capsule())
                                    .foregroundStyle(check.isSuccess ? Color.green : Color.orange)
                                    .lineLimit(1)
                            }
                            Text(check.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.codexMuted)
                        }
                    }
                    .padding(11)
                    .background(Color.codexCard)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                    )
                }
            }
        }
    }


}
