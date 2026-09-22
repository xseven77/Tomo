import AppKit
import SwiftUI

enum GatewayLayoutMetrics {
    static let sidebarWidth: CGFloat = 166
    static let sidebarTopInset: CGFloat = 14
    static let windowTopInset: CGFloat = 14
    static let windowBottomInset: CGFloat = 26
    static let minWindowWidth: CGFloat = 960
    static let minWindowHeight: CGFloat = 640
}

enum GatewayScrollCoordinateSpace {
    static let name = "gateway-content-scroll"
}

enum GatewayAgentConnectTarget {
    case hermes
    case pi
    case dsh
}

struct GatewayTableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum GatewayHeaderMinYKey: PreferenceKey {
    static let defaultValue = CGFloat.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

struct GatewayToast: Equatable {
    let message: String
    let systemImage: String
    let isSuccess: Bool
}

typealias GatewayToastHandler = (_ message: String, _ systemImage: String, _ isSuccess: Bool) -> Void

func gatewayHeatmapColor(for level: Int) -> Color {
    switch level {
    case 0: Color.codexMist.opacity(0.85)
    case 1: Color(red: 0.09, green: 0.49, blue: 0.98).opacity(0.35)
    case 2: Color(red: 0.09, green: 0.49, blue: 0.98).opacity(0.55)
    case 3: Color(red: 0.09, green: 0.49, blue: 0.98).opacity(0.75)
    default: Color(red: 0.09, green: 0.49, blue: 0.98)
    }
}

struct GatewayDateRangeSelectorView: View {
    @Bindable var store: GatewayStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GatewayDateRange.allCases) { r in
                let isSelected = store.selectedDateRange == r
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        store.selectedDateRange = r
                    }
                } label: {
                    HStack(spacing: 3) {
                        if r == .custom {
                            Image(systemName: "slider.horizontal.below.rectangle")
                                .font(.system(size: 9))
                        }
                        Text(r.shortLabel)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(
                        isSelected
                            ? Color.codexCard
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    )
                    .shadow(color: isSelected ? Color.black.opacity(0.08) : Color.clear, radius: 1.5, y: 0.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .stroke(isSelected ? Color.codexLine.opacity(0.4) : Color.clear, lineWidth: 0.6)
                    )
                    .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
        )
    }
}

struct GatewayCustomDateRangePickerBar: View {
    @Bindable var store: GatewayStore

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexPrimary)

                HStack(spacing: 4) {
                    Text("从")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.codexMuted)
                    DatePicker("", selection: $store.customStartDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .controlSize(.small)
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.codexMuted.opacity(0.8))

                HStack(spacing: 4) {
                    Text("至")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.codexMuted)
                    DatePicker("", selection: $store.customEndDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.codexMist.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
            )

            Button {
                store.applyCustomDateRange(start: store.customStartDate, end: store.customEndDate)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("应用")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexOnPrimary)
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 6))

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                customPresetChip("近1小时", hours: 1)
                customPresetChip("近6小时", hours: 6)
                customPresetChip("近24小时", hours: 24)
                customPresetChip("近3天", days: 3)
                customPresetChip("近7天", days: 7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func customPresetChip(_ label: String, hours: Int? = nil, days: Int? = nil) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                if let hours {
                    store.setCustomPreset(hours: hours)
                } else if let days {
                    store.setCustomPreset(days: days)
                }
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(Color.codexInk)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
    }
}
