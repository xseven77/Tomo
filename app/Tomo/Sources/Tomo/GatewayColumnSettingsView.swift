import SwiftUI

public struct GatewayColumnSettingsSheet: View {
    var store: GatewayStore
    @Environment(\.dismiss) private var dismiss

    public init(store: GatewayStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("自定义请求列表显示列")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.codexInk)

                        Text("\(store.visibleColumns.count)/\(GatewayRequestColumn.allCases.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.blue)
                    }

                    Text("勾选需要在实时请求流表格中展示的数据列，配置即时生效并自动记忆")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        store.resetColumnsToDefault()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10))
                            Text("恢复默认")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(Color.codexInk)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
                        )
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 6))
                    .help("恢复为标准 9 个默认展示列")

                    Button {
                        store.selectAllColumns()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10))
                            Text("全选")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(Color.codexInk)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
                        )
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 6))
                    .help("勾选显示全部 16 个字段列")
                }
            }
            .padding(18)
            .background(Color.codexCard)

            Divider()
                .overlay(Color.codexLine.opacity(0.35))

            // Body content with categorized grid
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(GatewayColumnCategory.allCases) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            // Category Title
                            HStack(spacing: 6) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.codexMuted)
                                Text(category.rawValue)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.codexInk)
                            }
                            .padding(.leading, 2)

                            // Category Columns Grid
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                ForEach(category.columns) { column in
                                    columnToggleCard(for: column)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(Color.codexBackground.opacity(0.4))

            Divider()
                .overlay(Color.codexLine.opacity(0.35))

            // Footer
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                    Text("列表将至少保留 1 列，横向宽度超出时支持平滑横向滚动查看")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()

                Button {
                    store.isColumnSettingsPresented = false
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.codexOnPrimary)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 6))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.codexCard)
        }
        .frame(width: 580, height: 530)
    }

    private func columnToggleCard(for column: GatewayRequestColumn) -> some View {
        let isSelected = store.isColumnVisible(column)
        let isDefault = GatewayRequestColumn.defaultColumns.contains(column)

        return Button {
            store.toggleColumn(column)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.blue : Color.codexMuted.opacity(0.5))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(column.title)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)

                        if isDefault {
                            Text("默认")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Color.codexMist, in: Capsule())
                                .foregroundStyle(Color.codexMuted)
                        }

                        Spacer()
                    }

                    Text(column.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.blue.opacity(0.05) : Color.codexCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.blue.opacity(0.35) : Color.codexLine.opacity(0.35), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
