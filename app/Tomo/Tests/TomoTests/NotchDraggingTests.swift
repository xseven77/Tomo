import XCTest
import AppKit
@testable import Tomo

final class NotchDraggingTests: XCTestCase {
    @MainActor
    private func makeSettings() -> (AppSettingsStore, UserDefaults, String) {
        let suiteName = "TomoNotchDraggingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettingsStore(defaults: defaults)
        return (settings, defaults, suiteName)
    }

    @MainActor
    func testNotchDraggingSettingsDefaultAndPersistence() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(settings.notchDraggingEnabled, "默认应处于锁定状态（禁止拖拽）")
        XCTAssertTrue(settings.notchDisplayOffsets.isEmpty, "默认没有屏幕偏移量")

        var enabledNotified = false
        settings.onNotchDraggingEnabledChanged = { (enabled: Bool) in enabledNotified = true }
        settings.notchDraggingEnabled = true
        XCTAssertTrue(settings.notchDraggingEnabled)
        XCTAssertTrue(enabledNotified)

        let displayA_UUID = "3D7EAE7C-CAE9-4733-9E14-A00EAD3600AF"
        XCTAssertEqual(settings.notchOffset(for: displayA_UUID), 0)

        var offsetsNotified = false
        settings.onNotchDisplayOffsetsChanged = { offsetsNotified = true }
        settings.setNotchOffset(50.5, for: displayA_UUID)

        XCTAssertTrue(offsetsNotified)
        XCTAssertEqual(settings.notchOffset(for: displayA_UUID), 50.5)

        // 重置单个屏幕
        settings.resetNotchOffset(for: displayA_UUID)
        XCTAssertEqual(settings.notchOffset(for: displayA_UUID), 0)

        // 多个屏幕与一键全重置
        let displayD_UUID = "EC6CE74E-A5E5-4FB8-BCC6-3586C2C0CB61"
        settings.setNotchOffset(100, for: displayA_UUID)
        settings.setNotchOffset(-80, for: displayD_UUID)
        XCTAssertEqual(settings.notchOffset(for: displayA_UUID), 100)
        XCTAssertEqual(settings.notchOffset(for: displayD_UUID), -80)

        settings.resetAllNotchOffsets()
        XCTAssertEqual(settings.notchOffset(for: displayA_UUID), 0)
        XCTAssertEqual(settings.notchOffset(for: displayD_UUID), 0)
        XCTAssertTrue(settings.notchDisplayOffsets.isEmpty)
    }

    @MainActor
    func testPerDisplayOffsetIsolationAcrossEnvironments() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let homeDisplayA = "UUID-HOME-DISPLAY-A"
        let workDisplayD = "UUID-WORK-DISPLAY-D"

        // 1. 在家里的显示器 A 上移动了刘海 (+120pt)
        settings.setNotchOffset(120, for: homeDisplayA)
        XCTAssertEqual(settings.notchOffset(for: homeDisplayA), 120)

        // 2. 断开家里的 A，来到公司连上显示器 D：D 绝对不能串用 A 的位置，初始应为 0
        XCTAssertEqual(settings.notchOffset(for: workDisplayD), 0, "新连接的外接显示器 D 绝不能使用 A 的偏移量")

        // 3. 在公司的显示器 D 上调整了位置 (-45pt)
        settings.setNotchOffset(-45, for: workDisplayD)
        XCTAssertEqual(settings.notchOffset(for: workDisplayD), -45)

        // 4. 家里显示器 A 的偏移依然完好保留
        XCTAssertEqual(settings.notchOffset(for: homeDisplayA), 120, "显示器 A 的独立偏移不受 D 的任何影响")
    }

    @MainActor
    func testPanelClampingForBuiltinScreenIsAlwaysZero() {
        let panel = NotchCapsulePanelController()
        let fakeScreen = NSScreen.main ?? NSScreen.screens.first!

        panel.setDragConfiguration(
            isBuiltin: true,
            isDraggingEnabled: true,
            xOffset: 120
        )

        let clamped = panel.clampedOffset(for: fakeScreen, offset: 120)
        XCTAssertEqual(clamped, 0, "内建物理刘海屏不可发生偏移")
    }

    @MainActor
    func testPanelClampingForExternalScreenRestrictsBounds() {
        let panel = NotchCapsulePanelController()
        let fakeScreen = NSScreen.main ?? NSScreen.screens.first!

        panel.setDragConfiguration(
            isBuiltin: false,
            isDraggingEnabled: true,
            xOffset: 0
        )

        let capsuleWidth = panel.viewModel.closedWidth > 0 ? panel.viewModel.closedWidth : 434
        let maxExpected = max(0, (fakeScreen.frame.width - capsuleWidth) / 2)
        let clampedPositive = panel.clampedOffset(for: fakeScreen, offset: 99999)
        XCTAssertEqual(clampedPositive, maxExpected, "正向偏移可达屏幕最右侧（零边距贴合）")

        let clampedNegative = panel.clampedOffset(for: fakeScreen, offset: -99999)
        XCTAssertEqual(clampedNegative, -maxExpected, "负向偏移可达屏幕最左侧（零边距贴合）")

        let normalOffset: CGFloat = 25
        let clampedNormal = panel.clampedOffset(for: fakeScreen, offset: normalOffset)
        XCTAssertEqual(clampedNormal, normalOffset)
    }

    @MainActor
    func testResetToCenterResetsOffsetAndNotifies() {
        let panel = NotchCapsulePanelController()
        panel.setDragConfiguration(
            isBuiltin: false,
            isDraggingEnabled: true,
            xOffset: 60
        )

        var reportedOffset: CGFloat?
        panel.onOffsetChanged = { reportedOffset = $0 }

        panel.resetToCenter(animated: false)
        XCTAssertEqual(panel.currentXOffset, 0)
        XCTAssertEqual(reportedOffset, 0)
    }

    @MainActor
    func testResolveActiveScreensNonDestructiveRules() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else { return }

        // 1. 用户选择 .off：任何情况下都返回空，保持关闭
        settings.notchDisplayTarget = .off
        let offResolved = NotchDisplayResolver.resolveActiveScreens(from: allScreens, target: .off)
        XCTAssertTrue(offResolved.isEmpty, ".off 状态下绝不展示在任何屏幕")
        XCTAssertEqual(settings.notchDisplayTarget, .off, "配置绝不可被篡改")

        // 2. 用户选择 .allDisplays：返回全部屏幕
        settings.notchDisplayTarget = .allDisplays
        let allResolved = NotchDisplayResolver.resolveActiveScreens(from: allScreens, target: .allDisplays)
        XCTAssertEqual(allResolved.count, allScreens.count)

        // 3. 用户选择首选显示器 A（假设为一个当前未连接的假 UUID）
        let imaginaryDisplayA = "IMAGINARY-DISPLAY-A-UUID"
        settings.notchDisplayTarget = .specificDisplay(imaginaryDisplayA)

        // 裁决：A 断开时
        let fallbackResolved = NotchDisplayResolver.resolveActiveScreens(
            from: allScreens,
            target: settings.notchDisplayTarget,
            knownDisplays: settings.knownDisplays
        )
        XCTAssertFalse(fallbackResolved.isEmpty, "A 断开时应智能漫游到其他外接屏或回退到内建屏")
        XCTAssertEqual(settings.notchDisplayTarget, .specificDisplay(imaginaryDisplayA), "关键验证：系统绝不可将用户的首选项覆写为内建屏！")

        // 4. 当首选显示器当前连接中时，精准命中首选屏幕
        let currentScreen = allScreens.first!
        settings.notchDisplayTarget = .specificDisplay(currentScreen.persistentID)
        let matchedResolved = NotchDisplayResolver.resolveActiveScreens(
            from: allScreens,
            target: settings.notchDisplayTarget,
            knownDisplays: settings.knownDisplays
        )
        XCTAssertEqual(matchedResolved.first?.persistentID, currentScreen.persistentID)
    }
}
