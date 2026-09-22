import Foundation
import SQLite3
import SwiftUI
import XCTest
@testable import Tomo

final class TomoTests: XCTestCase {
    func testMenuBarGeometryUsesTheMatchingExternalDisplayHeight() {
        let externalDisplay = CGRect(x: -2560, y: -122, width: 2560, height: 1440)
        let menuBars = [
            CGRect(x: 0, y: 0, width: 1800, height: 39),
            CGRect(x: -5120, y: -30, width: 2560, height: 30),
            CGRect(x: -2560, y: -122, width: 2560, height: 30)
        ]

        XCTAssertEqual(
            MenuBarWindowGeometry.matchingHeight(
                displayBounds: externalDisplay,
                menuBarBounds: menuBars
            ),
            30
        )
    }

    func testMenuBarGeometryDoesNotBorrowAnotherDisplaysHeight() {
        let externalDisplay = CGRect(x: -2560, y: -122, width: 2560, height: 1440)
        let otherDisplayMenuBars = [
            CGRect(x: 0, y: 0, width: 1800, height: 39),
            CGRect(x: -5120, y: -30, width: 2560, height: 30)
        ]

        XCTAssertNil(
            MenuBarWindowGeometry.matchingHeight(
                displayBounds: externalDisplay,
                menuBarBounds: otherDisplayMenuBars
            )
        )
    }

    @MainActor
    func testNotchOverlayPanelKeepsRequestedPhysicalTopEdge() {
        let panel = NotchOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let requested = NSRect(x: 550, y: 839, width: 700, height: 330)

        XCTAssertEqual(panel.constrainFrameRect(requested, to: NSScreen.main), requested)
    }

    @MainActor
    func testNotchPanelRecoversWhenARefreshFindsItHidden() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = NotchCapsulePanelController()
        defer { controller.hide() }

        controller.show(on: screen)
        XCTAssertTrue(controller.isVisible)

        controller.hide()
        XCTAssertFalse(controller.isVisible)

        controller.ensureVisible(on: screen)
        XCTAssertTrue(controller.isVisible)
    }

    @MainActor
    func testThemePreferencesMapToLightDarkAndSystemColorSchemes() {
        XCTAssertNil(AppThemePreference.system.preferredColorScheme)
        XCTAssertEqual(AppThemePreference.light.preferredColorScheme, .light)
        XCTAssertEqual(AppThemePreference.dark.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.system.resolvedColorScheme(system: .light), .light)
        XCTAssertEqual(AppThemePreference.system.resolvedColorScheme(system: .dark), .dark)
        XCTAssertNotNil(AppThemePreference.light.nsAppearance)
        XCTAssertNotNil(AppThemePreference.dark.nsAppearance)
    }

    @MainActor
    func testFollowSystemRefreshesWhenEffectiveAppearanceChanges() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppThemePreference.system.rawValue, forKey: "codexling.theme")

        let settings = AppSettingsStore(defaults: defaults)
        let nextScheme: ColorScheme = settings.systemColorScheme == .light ? .dark : .light
        var callbackCount = 0
        settings.onThemeChanged = { _ in callbackCount += 1 }

        settings.refreshSystemAppearanceIfNeeded(nextScheme)

        XCTAssertEqual(settings.resolvedColorScheme, nextScheme)
        XCTAssertEqual(callbackCount, 1)
    }

    func testCodexV2AnimationContractMatchesStandardRows() throws {
        let running = PetAnimationContract.sequence(for: .running, reducedMotion: false)
        XCTAssertEqual(running.frames.count, 24)
        XCTAssertEqual(running.loopStartIndex, 18)
        XCTAssertEqual(running.frames.first?.row, 7)
        XCTAssertEqual(try XCTUnwrap(running.frames.first?.duration), 0.12, accuracy: 0.0001)
        XCTAssertEqual(running.frames[5].duration, 0.22, accuracy: 0.0001)

        let waiting = PetAnimationContract.sequence(for: .waiting, reducedMotion: true)
        XCTAssertEqual(waiting.frames, [PetAnimationFrame(row: 6, column: 0, duration: 0.15)])
        XCTAssertNil(waiting.loopStartIndex)

        let wavingOneShot = PetAnimationContract.oneShotSequence(for: .waving, reducedMotion: false)
        XCTAssertEqual(wavingOneShot.frames.count, 12)
        XCTAssertNil(wavingOneShot.loopStartIndex)
        XCTAssertEqual(wavingOneShot.frames.first?.row, 3)
    }

    func testAutomaticPetBackgroundMapsQuotaHealth() {
        let automatic = StatusBarPetBackgroundColor.automatic
        XCTAssertEqual(automatic.resolved(for: .gray), .gray)
        XCTAssertEqual(automatic.resolved(for: .green), .green)
        XCTAssertEqual(automatic.resolved(for: .yellow), .yellow)
        XCTAssertEqual(automatic.resolved(for: .red), .red)
        XCTAssertEqual(StatusBarPetBackgroundColor.neutral.resolved(for: .red), .neutral)
    }

    func testActivityShimmerMotionAdvancesAndWrapsDeterministically() {
        let start = ActivityShimmerMotion.offset(
            canvasWidth: 100,
            bandWidth: 40,
            at: 0
        )
        let halfway = ActivityShimmerMotion.offset(
            canvasWidth: 100,
            bandWidth: 40,
            at: ActivityShimmerMotion.duration / 2
        )
        let wrapped = ActivityShimmerMotion.offset(
            canvasWidth: 100,
            bandWidth: 40,
            at: ActivityShimmerMotion.duration
        )

        XCTAssertEqual(start, -40, accuracy: 0.0001)
        XCTAssertGreaterThan(halfway, start)
        XCTAssertEqual(wrapped, start, accuracy: 0.0001)
    }

    func testStatusCapsuleReminderColorOnlyDefinesForeground() {
        XCTAssertNotEqual(
            StatusBarPetBackgroundColor.green.foregroundColor(for: .light),
            StatusBarPetBackgroundColor.yellow.foregroundColor(for: .light)
        )
        XCTAssertNotEqual(
            StatusBarPetBackgroundColor.yellow.foregroundColor(for: .light),
            StatusBarPetBackgroundColor.red.foregroundColor(for: .light)
        )
        XCTAssertNotEqual(
            StatusBarPetBackgroundColor.gray.foregroundColor(for: .light),
            StatusBarPetBackgroundColor.gray.foregroundColor(for: .dark)
        )
    }

    @MainActor
    func testStatusCapsuleUsesThemeLockedNeutralSurface() {
        let view = StatusCapsuleView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 26)
        )
        XCTAssertTrue(
            view.usesThemeLockedNeutralSurfaceForTesting,
            "状态栏胶囊必须使用不随壁纸明暗翻转的主题中性色"
        )
    }

    @MainActor
    func testPetBackgroundDefaultsToNeutralAndListsItFirst() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.petBackgroundColor, .neutral)
        XCTAssertEqual(StatusBarPetBackgroundColor.allCases.first, .neutral)
    }

    @MainActor
    func testAccountCarouselDefaultsOffAndPersistsInterval() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.accountCarouselInterval, .off)

        settings.accountCarouselInterval = .seconds10

        XCTAssertEqual(defaults.integer(forKey: "codexling.accountCarouselInterval"), 10)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).accountCarouselInterval, .seconds10)
    }

    @MainActor
    func testProviderCarouselSettingsDefaultsAndPersist() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(settings.mainWindowProviderCarouselEnabled)
        XCTAssertTrue(settings.notchProviderCarouselEnabled)

        var mainChanged: Bool?
        var notchChanged: Bool?
        settings.onMainWindowProviderCarouselEnabledChanged = { mainChanged = $0 }
        settings.onNotchProviderCarouselEnabledChanged = { notchChanged = $0 }

        settings.mainWindowProviderCarouselEnabled = false
        settings.notchProviderCarouselEnabled = false

        XCTAssertEqual(mainChanged, false)
        XCTAssertEqual(notchChanged, false)
        XCTAssertFalse(defaults.bool(forKey: "codexling.mainWindowProviderCarouselEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "codexling.notchProviderCarouselEnabled"))

        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.mainWindowProviderCarouselEnabled)
        XCTAssertFalse(restored.notchProviderCarouselEnabled)
    }

    @MainActor
    func testSilentLaunchDefaultsOffAndPersists() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.silentLaunchEnabled)
        XCTAssertTrue(settings.shouldOpenMainWindowAtLaunch)

        settings.silentLaunchEnabled = true

        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(restored.silentLaunchEnabled)
        XCTAssertFalse(restored.shouldOpenMainWindowAtLaunch)
    }

    @MainActor
    func testNetworkProxySettingsPersistAndBuildScopedConfiguration() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.networkProxyEnabled)
        XCTAssertEqual(settings.networkProxyProtocol, .socks5h)
        XCTAssertEqual(settings.networkProxyHost, "127.0.0.1")
        XCTAssertEqual(settings.networkProxyPort, 7897)

        settings.networkProxyEnabled = true
        settings.networkProxyProtocol = .http
        settings.networkProxyPort = 7897

        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(restored.networkProxyEnabled)
        XCTAssertEqual(restored.networkProxyProtocol, .http)
        XCTAssertEqual(restored.networkProxyPort, 7897)

        let proxy = AppNetworkProxyConfiguration.load(from: defaults)
        XCTAssertEqual(proxy.proxyURL, "http://127.0.0.1:7897")
        let environment = proxy.applying(to: ["KEEP": "value"])
        XCTAssertEqual(environment["HTTPS_PROXY"], proxy.proxyURL)
        XCTAssertEqual(environment["CODEXLING_GEMINI_PROXY"], proxy.proxyURL)
        XCTAssertEqual(
            environment["NO_PROXY"],
            "localhost,127.0.0.1,::1,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16"
        )
        XCTAssertEqual(proxy.urlSessionProxyDictionary["ExcludeSimpleHostnames"] as? Int, 1)
        XCTAssertTrue((proxy.urlSessionProxyDictionary["ExceptionsList"] as? [String])?.contains("172.16.0.0/12") == true)
        XCTAssertEqual(environment["KEEP"], "value")
    }

    func testConnectionCarouselAdvancesWrapsAndRecoversMissingSelection() {
        let keys = ["codex.first", "codex.second", "deepseek.first"]

        XCTAssertEqual(ConnectionCarousel.nextKey(after: keys[0], availableKeys: keys), keys[1])
        XCTAssertEqual(ConnectionCarousel.nextKey(after: keys[2], availableKeys: keys), keys[0])
        XCTAssertEqual(ConnectionCarousel.nextKey(after: "missing", availableKeys: keys), keys[0])
        XCTAssertNil(ConnectionCarousel.nextKey(after: keys[0], availableKeys: [keys[0]]))
        XCTAssertNil(ConnectionCarousel.nextKey(after: keys[0], availableKeys: []))
    }

    func testStatusPetBadgeKeepsPetVisibleOnWhiteBackdrop() {
        let pet = NSImage(size: NSSize(width: 24, height: 21))
        pet.lockFocus()
        NSColor.purple.setFill()
        NSBezierPath(rect: NSRect(x: 7, y: 4, width: 10, height: 13)).fill()
        pet.unlockFocus()

        let badge = StatusPetBadgeRenderer.render(pet)
        XCTAssertEqual(badge.size, StatusPetBadgeRenderer.size)
        XCTAssertFalse(badge.isTemplate)

        guard let tiff = badge.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return XCTFail("Pet badge should be renderable")
        }
        let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        let edge = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)
        XCTAssertNotNil(center)
        XCTAssertNotNil(edge)
        XCTAssertGreaterThan(edge?.alphaComponent ?? 0, 0.5)
    }

    func testStatusPetFrameIsGeometricallyCenteredWithoutAssetCompensation() {
        let container = NSRect(x: 0, y: 0, width: 22, height: 22)
        let petRect = StatusPetBadgeRenderer.centeredRect(
            contentSize: NSSize(width: 13, height: 15),
            in: container
        )

        XCTAssertEqual(petRect.midX, container.midX, accuracy: 0.0001)
        XCTAssertEqual(petRect.midY, container.midY, accuracy: 0.0001)
    }

    func testHoverSafeTriangleKeepsPointerPathTowardCardOpen() {
        let triangle = HoverSafeTriangle(
            origin: CGPoint(x: 100, y: 200),
            targetFrame: CGRect(x: 20, y: 80, width: 200, height: 80),
            buffer: 4
        )

        XCTAssertTrue(triangle.contains(CGPoint(x: 100, y: 190)))
        XCTAssertTrue(triangle.contains(CGPoint(x: 60, y: 165)))
    }

    func testHoverSafeTriangleRejectsPointerMovingAwayFromCard() {
        let triangle = HoverSafeTriangle(
            origin: CGPoint(x: 100, y: 200),
            targetFrame: CGRect(x: 20, y: 80, width: 200, height: 80),
            buffer: 4
        )

        XCTAssertFalse(triangle.contains(CGPoint(x: 100, y: 210)))
        XCTAssertFalse(triangle.contains(CGPoint(x: 10, y: 190)))
    }

    func testHoverSafeTriangleToleratesJitterNearDeparturePoint() {
        let safeArea = HoverSafeTriangle(
            origin: CGPoint(x: 100, y: 200),
            targetFrame: CGRect(x: 20, y: 80, width: 200, height: 80),
            buffer: 8
        )

        XCTAssertTrue(safeArea.contains(CGPoint(x: 106, y: 199)))
        XCTAssertTrue(safeArea.contains(CGPoint(x: 94, y: 198)))
    }

    func testHoverSafeTriangleSupportsMovingBackUpToStatusCapsule() {
        let safeArea = HoverSafeTriangle(
            origin: CGPoint(x: 100, y: 100),
            targetFrame: CGRect(x: 80, y: 150, width: 40, height: 22),
            buffer: 8
        )

        XCTAssertTrue(safeArea.contains(CGPoint(x: 101, y: 120)))
        XCTAssertTrue(safeArea.contains(CGPoint(x: 96, y: 145)))
        XCTAssertFalse(safeArea.contains(CGPoint(x: 145, y: 115)))
    }

    func testCompanionPanelRoutesOverlappingAnchorClickToDismiss() throws {
        let anchor = NSRect(x: 100, y: 300, width: 120, height: 30)
        let overlappingPanel = NSRect(x: 80, y: 160, width: 286, height: 150)
        let capture = try XCTUnwrap(
            CompanionPanelAnchorClickRouting.captureRect(
                anchorFrame: anchor,
                panelFrame: overlappingPanel
            )
        )
        XCTAssertEqual(capture, NSRect(x: 20, y: 140, width: 120, height: 10))

        let detachedPanel = NSRect(x: 80, y: 140, width: 286, height: 150)
        XCTAssertNil(
            CompanionPanelAnchorClickRouting.captureRect(
                anchorFrame: anchor,
                panelFrame: detachedPanel
            )
        )
    }

    @MainActor
    func testStatusCapsulePressInvokesClickAction() async {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        var clickCount = 0
        let pressed = expectation(description: "accessibility press finishes asynchronously")
        view.onClick = {
            clickCount += 1
            pressed.fulfill()
        }

        XCTAssertTrue(view.accessibilityPerformPress())
        await fulfillment(of: [pressed], timeout: 1)
        XCTAssertEqual(clickCount, 1)
    }

    @MainActor
    func testStatusCapsuleMouseUpInsideInvokesClickAction() throws {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        var clickCount = 0
        view.onClick = { clickCount += 1 }

        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 12),
            modifierFlags: [],
            timestamp: 10,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 20, y: 12),
            modifierFlags: [],
            timestamp: 10.05,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))

        view.mouseDown(with: mouseDown)
        view.mouseUp(with: mouseUp)
        XCTAssertEqual(clickCount, 1)
    }

    @MainActor
    func testStatusCapsuleHoverCallbacksRemainConnected() throws {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        var entries = 0
        var exits = 0
        view.onMouseEntered = { entries += 1 }
        view.onMouseExited = { exits += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 20, y: 12),
            modifierFlags: [],
            timestamp: 10,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseEntered(with: event)
        view.mouseExited(with: event)

        XCTAssertEqual(entries, 1)
        XCTAssertEqual(exits, 1)
    }

    @MainActor
    func testStatusCapsuleReceivesPointerEvents() {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        XCTAssertTrue(view.hitTest(NSPoint(x: 40, y: 12)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 140, y: 12)))
    }

    @MainActor
    func testStatusCapsulePressCreatesMaterialRipple() throws {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 40, y: 12),
            modifierFlags: [],
            timestamp: 10,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        view.mouseDown(with: event)

        XCTAssertEqual(view.activeMaterialRippleCountForTesting, 1)
    }

    @MainActor
    func testStatusCapsuleUsesTheSharedRotatingBorderFlow() {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        XCTAssertEqual(
            view.activityFlowPresentationForTesting,
            .rotatingBorder(lineWidth: 2)
        )
    }

    func testActivityWaveTimingsRemainSharedAcrossSurfaces() {
        XCTAssertEqual(ActivityWaveTiming.duration, 3.6)
        XCTAssertEqual(ActivityWaveTiming.capsuleDuration, 1.8)
        XCTAssertEqual(ActivityWaveTiming.rotatingBorderDuration, 2.4)
        XCTAssertEqual(ActivityWaveTiming.progress(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.progress(at: 1.8), 0.5, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.progress(at: 3.6), 0, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.capsuleProgress(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.capsuleProgress(at: 0.9), 0.5, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.capsuleProgress(at: 1.8), 0, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.capsuleProgress(at: 3.6), 0, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.rotatingBorderProgress(at: 1.2), 0.5, accuracy: 0.001)
        XCTAssertEqual(ActivityWaveTiming.rotatingBorderProgress(at: 2.4), 0, accuracy: 0.001)
    }

    func testOnlyActiveCodexStatesShowTheSharedActivityWave() {
        XCTAssertFalse(CodexActivityState.unavailable.showsActivityWave)
        XCTAssertFalse(CodexActivityState.idle.showsActivityWave)

        let activeStates: [CodexActivityState] = [
            .thinking,
            .executing,
            .reviewing,
            .waitingForUser,
            .completed,
            .interrupted,
        ]
        XCTAssertTrue(activeStates.allSatisfy(\.showsActivityWave))
    }

    @MainActor
    func testPetBackgroundSelectionPersists() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.petBackgroundColor = .yellow

        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.petBackgroundColor, .yellow)
    }

    @MainActor
    func testStatusBarWaveDefaultsOnAndPersists() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(settings.statusBarWaveEnabled)

        settings.statusBarWaveEnabled = false
        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.statusBarWaveEnabled)
    }

    @MainActor
    func testStatusBarIndicatorDefaultsToActivityStateAndPersists() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.statusBarIndicatorColorMode, .activityState)

        settings.statusBarIndicatorColorMode = .quotaHealth
        XCTAssertEqual(
            AppSettingsStore(defaults: defaults).statusBarIndicatorColorMode,
            .quotaHealth
        )
    }

    @MainActor
    func testStatusCapsuleSolidColorsPersistAndLegacyNeutralMigrates() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.statusBarIndicatorColorMode = .cyan
        settings.statusBarWaveColorMode = .orange

        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.statusBarIndicatorColorMode, .cyan)
        XCTAssertEqual(restored.statusBarWaveColorMode, .orange)
        XCTAssertFalse(StatusCapsuleColorMode.allCases.map(\.rawValue).contains("neutral"))
        XCTAssertFalse(StatusCapsuleColorMode.activityFlowCases.contains(.quotaHealth))

        defaults.set("neutral", forKey: "codexling.statusBarWaveColorMode")
        XCTAssertEqual(
            AppSettingsStore(defaults: defaults).statusBarWaveColorMode,
            .activityState
        )

        defaults.set("quotaHealth", forKey: "codexling.statusBarWaveColorMode")
        XCTAssertEqual(
            AppSettingsStore(defaults: defaults).statusBarWaveColorMode,
            .activityState
        )
    }

    @MainActor
    func testStatusCapsuleAutomaticForegroundFollowsMenuBarAppearanceWithoutVibrancy() throws {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let vibrantLight = try XCTUnwrap(NSAppearance(named: .vibrantLight))
        let vibrantDark = try XCTUnwrap(NSAppearance(named: .vibrantDark))

        XCTAssertFalse(view.allowsVibrancy)
        XCTAssertEqual(
            StatusCapsuleView.automaticMenuBarForegroundColor(appearance: vibrantLight),
            .black
        )
        XCTAssertEqual(
            StatusCapsuleView.automaticMenuBarForegroundColor(appearance: vibrantDark),
            .white
        )
    }

    @MainActor
    func testStatusCapsuleWithProviderLogoDoesNotCrashOnRotationAndDealloc() throws {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let dummyImage = NSImage(size: NSSize(width: 13, height: 13))

        // Measure width without logo
        view.update(
            background: .neutral,
            text: "5h 90%·周 90%",
            reservedText: "5h 99%·周 99%",
            foregroundColor: .white,
            showsPet: false,
            indicatorColor: .systemGreen,
            showsWave: false,
            cornerRatio: 0.5,
            providerLogo: nil
        )
        let widthWithoutLogo = view.preferredWidth

        // Measure width with logo
        view.update(
            background: .neutral,
            text: "5h 90%·周 90%",
            reservedText: "5h 99%·周 99%",
            foregroundColor: .white,
            showsPet: false,
            indicatorColor: .systemGreen,
            showsWave: false,
            cornerRatio: 0.5,
            providerLogo: dummyImage
        )
        let widthWithLogo = view.preferredWidth

        // Verify that the width increases when provider logo is present
        XCTAssertGreaterThan(widthWithLogo, widthWithoutLogo)
        XCTAssertEqual(widthWithLogo - widthWithoutLogo, StatusCapsuleView.providerLogoPlaceholderWidth, accuracy: 3.0)

        // Simulate carousel rotation across multiple providers and autorelease pool drains
        for i in 0..<50 {
            autoreleasepool {
                view.update(
                    background: .neutral,
                    text: "Provider \(i)·\(i * 2)%",
                    reservedText: "Provider 99·99%",
                    foregroundColor: .white,
                    showsPet: false,
                    indicatorColor: .systemGreen,
                    showsWave: false,
                    cornerRatio: 0.5,
                    providerLogo: dummyImage
                )
                _ = view.preferredWidth
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                if let rep {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
            }
        }
    }

    @MainActor
    func testStatusCapsuleWithGeminiAndVariableQuotaTextsDoesNotCrash() throws {
        let view = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let geminiLogo = BrandAssetCatalog.image(for: .googleGemini) ?? NSImage(size: NSSize(width: 13, height: 13))
        let agentLogo = BrandAssetCatalog.image(for: .codex)

        let testCases: [(text: String, reservedText: String, hasAgentPrefix: Bool, agentLogo: NSImage?)] = [
            // Gemini without agent task (hasAgentPrefix = false) with short/long reserved texts
            ("5h 80%·周 90%", "无额度", false, nil),
            ("5h 80%·周 90%", "未登录", false, nil),
            ("5h 80%·周 90%", "5h 99%·周 99%", false, nil),
            ("周 90%", "无额度", false, nil),
            ("5h 80%", "无额度", false, nil),
            ("限流中", "无额度", false, nil),
            ("额度暂不可用", "无额度", false, nil),
            ("需要验证账号", "无额度", false, nil),
            ("Gemini Advanced", "无额度", false, nil),
            ("Google One AI Premium", "5h 99%·周 99%", false, nil),

            // Gemini with active agent task (hasAgentPrefix = true)
            ("思考中·5h 80%·周 90%", "思考中·无额度", true, agentLogo),
            ("思考中·5h 80%·周 90%", "思考中·5h 99%·周 99%", true, agentLogo),
            ("思考中·额度暂不可用", "思考中·无额度", true, agentLogo),
            ("工作中·限流中", "思考中·无额度", true, agentLogo),
            ("工作中·Gemini Advanced", "思考中·5h 99%·周 99%", true, agentLogo),
        ]

        for testCase in testCases {
            autoreleasepool {
                view.update(
                    background: .neutral,
                    text: testCase.text,
                    reservedText: testCase.reservedText,
                    foregroundColor: .white,
                    showsPet: false,
                    indicatorColor: .systemGreen,
                    showsWave: false,
                    cornerRatio: 0.5,
                    providerLogo: geminiLogo,
                    agentLogo: testCase.agentLogo,
                    hasAgentPrefix: testCase.hasAgentPrefix
                )
                XCTAssertGreaterThan(view.preferredWidth, 0)
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                if let rep {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
            }
        }
    }

    func testTaskHoverDismissalLastsUntilActiveTasksEnd() {
        var state = TaskHoverPresentationState()
        state.update(hasActiveTasks: true)
        XCTAssertTrue(state.shouldAutoPresent(isEnabled: true))

        state.dismiss()
        XCTAssertFalse(state.shouldAutoPresent(isEnabled: true))
        state.update(hasActiveTasks: true)
        XCTAssertFalse(state.shouldAutoPresent(isEnabled: true))

        state.update(hasActiveTasks: false)
        state.update(hasActiveTasks: true)
        XCTAssertTrue(state.shouldAutoPresent(isEnabled: true))
        XCTAssertFalse(state.shouldAutoPresent(isEnabled: false))
    }

    func testTaskHoverCloseButtonStaysInsideCardAndClearOfContent() {
        let cardSize = NSSize(width: 340, height: 112)
        let cardBounds = NSRect(origin: .zero, size: cardSize)
        let closeFrame = PetHoverCloseButtonLayout.frame(in: cardSize)
        let contentMaxX =
            cardSize.width - PetHoverCloseButtonLayout.activeContentTrailingPadding

        XCTAssertTrue(cardBounds.contains(closeFrame))
        XCTAssertEqual(
            cardBounds.maxX - closeFrame.maxX,
            PetHoverCloseButtonLayout.edgeInset
        )
        XCTAssertEqual(
            cardBounds.maxY - closeFrame.maxY,
            PetHoverCloseButtonLayout.edgeInset
        )
        XCTAssertGreaterThanOrEqual(
            closeFrame.minX - contentMaxX,
            PetHoverCloseButtonLayout.edgeInset
        )
    }

    @MainActor
    func testStatusBarCornerPercentDefaultsPersistsAndClamps() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.statusBarCornerPercent, 50)

        settings.statusBarCornerPercent = 32
        XCTAssertEqual(AppSettingsStore(defaults: defaults).statusBarCornerPercent, 32)

        defaults.set(90.0, forKey: "codexling.statusBarCornerPercent")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).statusBarCornerPercent, 50)
    }

    @MainActor
    func testStatusBarOpacityDefaultsToTwentyPersistsAndClamps() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.statusBarOpacityPercent, 20)

        settings.statusBarOpacityPercent = 45
        XCTAssertEqual(AppSettingsStore(defaults: defaults).statusBarOpacityPercent, 45)

        defaults.set(140.0, forKey: "codexling.statusBarOpacityPercent")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).statusBarOpacityPercent, 50)
    }

    @MainActor
    func testDetachedWindowHeightsRespectVisibleViewport() {
        let dashboardMaximum = DetachedWindowMetrics.maximumContentHeight(for: NSScreen.main)
        if let visibleHeight = NSScreen.main?.visibleFrame.height {
            XCTAssertLessThanOrEqual(dashboardMaximum, visibleHeight - 32)
        }

        let clamped = DetachedWindowMetrics.clampSettingsContentSize(
            NSSize(width: 460, height: 10_000),
            screen: NSScreen.main
        )
        let settingsMaximum = DetachedWindowMetrics.maximumSettingsWindowHeight(for: NSScreen.main)
        XCTAssertGreaterThanOrEqual(clamped.width, DetachedWindowMetrics.dashboardWidth)
        XCTAssertLessThanOrEqual(clamped.height, settingsMaximum)
    }

    @MainActor
    func testSettingsWindowStartsCompactAndUsesNaturalContentHeight() {
        let settingsMaximum = DetachedWindowMetrics.maximumSettingsWindowHeight(for: NSScreen.main)
        let provisional = DetachedWindowMetrics.settingsWindowProvisionalHeight(screen: NSScreen.main)
        XCTAssertEqual(provisional, min(DetachedWindowMetrics.settingsDefaultHeight, settingsMaximum))

        let shortContent = DetachedWindowMetrics.preferredSettingsWindowSize(
            contentHeight: 240,
            screen: NSScreen.main
        )
        XCTAssertEqual(shortContent.height, min(DetachedWindowMetrics.settingsDefaultHeight, settingsMaximum))

        let naturalContentHeight = min(960, settingsMaximum)
        let naturalContent = DetachedWindowMetrics.preferredSettingsWindowSize(
            contentHeight: naturalContentHeight,
            screen: NSScreen.main
        )
        XCTAssertEqual(naturalContent.height, max(
            min(naturalContentHeight + 24, settingsMaximum),
            min(DetachedWindowMetrics.settingsDefaultHeight, settingsMaximum)
        ))

        // 验证设置窗口初始默认宽度等于设定最小宽度
        let defaultInitialSize = DetachedWindowMetrics.settingsWindowInitialSize(for: .general, screen: NSScreen.main)
        XCTAssertEqual(defaultInitialSize.width, DetachedWindowMetrics.settingsMinWidth)
        XCTAssertEqual(DetachedWindowMetrics.settingsDefaultWidth, DetachedWindowMetrics.settingsMinWidth)

        // 验证移动端伴生页面亦遵循设定宽度
        let mobileInitialSize = DetachedWindowMetrics.settingsWindowInitialSize(for: .mobile, screen: NSScreen.main)
        XCTAssertEqual(mobileInitialSize.width, DetachedWindowMetrics.settingsMinWidth)
        XCTAssertEqual(mobileInitialSize.height, min(DetachedWindowMetrics.settingsMobileHeight, settingsMaximum))

        let mobilePreferred = DetachedWindowMetrics.preferredSettingsWindowSize(
            contentHeight: 700,
            tab: .mobile,
            screen: NSScreen.main
        )
        XCTAssertEqual(mobilePreferred.width, DetachedWindowMetrics.settingsMobileWidth)
        XCTAssertEqual(mobilePreferred.height, min(DetachedWindowMetrics.settingsMobileHeight, settingsMaximum))

        // 验证设置窗口允许用户自由拖拽拉大，maxSize.height 不应被限制在 measuredContentHeight
        let limits = DetachedWindowMetrics.settingsWindowSizeLimits(
            measuredContentHeight: 480,
            screen: NSScreen.main
        )
        XCTAssertEqual(limits.max.height, settingsMaximum)
        XCTAssertGreaterThanOrEqual(limits.max.width, DetachedWindowMetrics.settingsDefaultWidth)

        // 验证 clamp 允许放宽到屏幕或大宽度
        let clamped = DetachedWindowMetrics.clampSettingsContentSize(
            NSSize(width: 950, height: 860),
            screen: NSScreen.main
        )
        XCTAssertEqual(clamped.width, 950)
        XCTAssertEqual(clamped.height, min(860, settingsMaximum))
    }

    @MainActor
    func testNativeWindowDraggingDoesNotInjectTitlebarHitTestOverlays() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let originalSubviews = frameView.subviews

        WindowDraggingPolicy.apply(to: window)

        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertEqual(frameView.subviews, originalSubviews)
    }

    @MainActor
    func testLogoRowHoverCanTemporarilyDisableNativeWindowDragging() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        WindowDraggingPolicy.apply(to: window, isEnabled: false)
        XCTAssertFalse(window.isMovableByWindowBackground)

        WindowDraggingPolicy.apply(to: window, isEnabled: true)
        XCTAssertTrue(window.isMovableByWindowBackground)
    }

    @MainActor
    func testTrafficLightsAndCustomTitleControlsRemainClickableWithNativeDragging() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        WindowDraggingPolicy.apply(to: window)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let closeCenter = frameView.convert(
            NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            from: closeButton
        )
        XCTAssertTrue(frameView.hitTest(closeCenter) === closeButton)

        let controls = TitleControlsView(onToggleOrientation: {}, onTogglePin: {})
        controls.frame = NSRect(x: 200, y: 388, width: 66, height: 28)
        frameView.addSubview(controls, positioned: .above, relativeTo: nil)
        controls.update(
            orientation: .horizontal,
            isPinned: false,
            appearance: try XCTUnwrap(NSAppearance(named: .aqua))
        )
        let titleButtons = controls.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(titleButtons.count, 2)
        XCTAssertTrue(titleButtons.allSatisfy { !$0.mouseDownCanMoveWindow })
    }

    @MainActor
    func testClosingAndRecreatingWindowPreservesDraggingAndTrafficLightHitTesting() throws {
        func makeWindow() throws -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 610, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            WindowDraggingPolicy.apply(to: window)
            return window
        }

        let first = try makeWindow()
        first.close()
        let reopened = try makeWindow()
        let frameView = try XCTUnwrap(reopened.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let closeButton = try XCTUnwrap(reopened.standardWindowButton(.closeButton))
        let closeCenter = frameView.convert(
            NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            from: closeButton
        )

        XCTAssertTrue(reopened.isMovableByWindowBackground)
        XCTAssertTrue(frameView.hitTest(closeCenter) === closeButton)
    }

    @MainActor
    func testWindowEventScopeKeepsMainAndSettingsWindowsIndependent() {
        let mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(WindowEventScope.matches(eventWindow: mainWindow, targetWindow: mainWindow))
        XCTAssertTrue(WindowEventScope.matches(eventWindow: settingsWindow, targetWindow: settingsWindow))
        XCTAssertFalse(WindowEventScope.matches(eventWindow: settingsWindow, targetWindow: mainWindow))
        XCTAssertFalse(WindowEventScope.matches(eventWindow: mainWindow, targetWindow: settingsWindow))
        XCTAssertFalse(WindowEventScope.matches(eventWindow: nil, targetWindow: mainWindow))
    }

    func testQuotaHealthColorThresholdsDriveRootGradient() {
        let window = UsageWindow(
            label: "周额度",
            remaining: 0,
            total: 100,
            resetsAt: ""
        )
        XCTAssertEqual(QuotaHealthLevel.from(window: window, isLoggedIn: false), .gray)
        XCTAssertEqual(
            QuotaHealthLevel.from(
                window: UsageWindow(label: "周额度", remaining: 60, total: 100, resetsAt: ""),
                isLoggedIn: true
            ),
            .green
        )
        XCTAssertEqual(
            QuotaHealthLevel.from(
                window: UsageWindow(label: "周额度", remaining: 30, total: 100, resetsAt: ""),
                isLoggedIn: true
            ),
            .yellow
        )
        XCTAssertEqual(
            QuotaHealthLevel.from(
                window: UsageWindow(label: "周额度", remaining: 10, total: 100, resetsAt: ""),
                isLoggedIn: true
            ),
            .red
        )
    }

    func testGeminiNotchQuotaSegmentsUseIndependentHealthColors() {
        let connection = GeminiAccountConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "Gemini Test",
            credentialHandle: "gemini-test",
            authenticationState: .connected,
            planName: "Google AI Pro",
            geminiWeeklyRemaining: 0.70,
            geminiFiveHourRemaining: 0.10,
            createdAt: Date()
        )

        let tick = StatusBarProviderTickFactory.geminiTick(connection)

        XCTAssertEqual(tick.providerName, "Gemini")
        XCTAssertEqual(tick.detailText, "Google AI Pro")
        XCTAssertEqual(tick.quotaText, "5h 10% · 周 70%")
        XCTAssertEqual(tick.quotaSegments, [
            StatusBarQuotaSegment(text: "5h 10%", health: .red),
            StatusBarQuotaSegment(text: "周 70%", health: .green)
        ])
    }

    func testGeminiNotchUsesGrayUnavailableCopyInsteadOfCachedOrPartialQuota() {
        let staleConnection = GeminiAccountConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "Gemini Stale",
            credentialHandle: "gemini-stale",
            authenticationState: .connected,
            planName: "Antigravity Free",
            geminiWeeklyRemaining: 1,
            geminiFiveHourRemaining: 1,
            rateLimitState: "quota_unavailable",
            createdAt: Date()
        )
        let partialConnection = GeminiAccountConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "Gemini Partial",
            credentialHandle: "gemini-partial",
            authenticationState: .connected,
            planName: "Antigravity Free",
            geminiWeeklyRemaining: 1,
            rateLimitState: "normal",
            createdAt: Date()
        )

        for tick in [
            StatusBarProviderTickFactory.geminiTick(staleConnection),
            StatusBarProviderTickFactory.geminiTick(partialConnection)
        ] {
            XCTAssertEqual(tick.quotaText, "额度暂不可查询")
            XCTAssertEqual(tick.quotaHealth, .gray)
            XCTAssertEqual(tick.quotaSegments, [
                StatusBarQuotaSegment(text: "额度暂不可查询", health: .gray)
            ])
        }
    }

    func testGeminiQuotaPrefersIndependentAbsoluteResetTimesWhenFiveHourQuotaIsExhausted() throws {
        let response: [String: Any] = [
            "groups": [[
                "displayName": "Gemini Models",
                "buckets": [
                    [
                        "bucketId": "gemini-weekly",
                        "displayName": "Weekly Limit Remaining",
                        "window": "weekly",
                        "remainingFraction": 0.81,
                        // Reproduces the transient upstream description mix-up.
                        "description": "It will fully refresh in 34 minutes.",
                        "resetTime": "2026-09-17T18:21:26Z"
                    ],
                    [
                        "bucketId": "gemini-5h",
                        "displayName": "Five Hour Limit Remaining",
                        "window": "5h",
                        "remainingFraction": 0.0,
                        "description": "It will fully refresh in 34 minutes.",
                        "resetTime": "2026-09-13T05:35:00Z"
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        let quota = try AntigravityRemoteQuota.parse(data: data)

        XCTAssertEqual(quota.geminiWeekly, 0.81)
        XCTAssertEqual(quota.geminiWeeklyReset, "2026-09-17T18:21:26Z")
        XCTAssertEqual(quota.geminiFiveHour, 0.0)
        XCTAssertEqual(quota.geminiFiveHourReset, "2026-09-13T05:35:00Z")
        XCTAssertNotEqual(quota.geminiWeeklyReset, quota.geminiFiveHourReset)
    }

    func testModelCheckStatusDecodesLiveResultsAndSupportsLegacyPayloads() throws {
        let liveData = Data(#"""
        {
          "running": true,
          "scope": "all",
          "done": 1,
          "total": 2,
          "current": "google/gemini-pro@example",
          "results": [{
            "scopedId": "google/gemini-pro@example",
            "status": "available",
            "latencyMs": 84
          }],
          "startedAt": 1800000000
        }
        """#.utf8)
        let live = try JSONDecoder().decode(GatewayModelCheckJobStatus.self, from: liveData)
        XCTAssertEqual(live.results.count, 1)
        XCTAssertEqual(live.results[0].status, "available")
        XCTAssertEqual(live.results[0].latencyMs, 84)

        let legacyData = Data(#"""
        {
          "running": true,
          "scope": "all",
          "done": 0,
          "total": 2,
          "current": "正在启动探测...",
          "startedAt": 1800000000
        }
        """#.utf8)
        let legacy = try JSONDecoder().decode(GatewayModelCheckJobStatus.self, from: legacyData)
        XCTAssertTrue(legacy.results.isEmpty)
    }

    func testCodexNotchQuotaSegmentsUseIndependentHealthColors() throws {
        var snapshot = CodexUsageSnapshot.preview
        snapshot.weekly = UsageWindow(label: "周额度", remaining: 70, total: 100, resetsAt: "")
        snapshot.shortWindow = UsageWindow(label: "5 小时", remaining: 10, total: 100, resetsAt: "")

        let tick = try XCTUnwrap(StatusBarProviderTickFactory.codexTick(
            id: "codex.test",
            label: "Codex Test",
            accountName: "Codex Test",
            usage: snapshot,
            isConnected: true
        ))

        XCTAssertEqual(tick.providerName, "Codex")
        XCTAssertEqual(tick.quotaText, "周 70% · 5h 10%")
        XCTAssertEqual(tick.detailText, "plus")
        XCTAssertEqual(tick.quotaSegments, [
            StatusBarQuotaSegment(text: "周 70%", health: .green),
            StatusBarQuotaSegment(text: "5h 10%", health: .red)
        ])
    }

    func testNotchProviderTickFactoryPopulatesResetTimeText() throws {
        // 1. Gemini with reset desc
        let gemini = GeminiAccountConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "Gemini Pro",
            credentialHandle: "gemini-pro",
            authenticationState: .connected,
            planName: "Google AI Pro",
            geminiWeeklyRemaining: 0.85,
            geminiWeeklyResetDesc: "2 days",
            geminiFiveHourRemaining: 0.90,
            geminiFiveHourResetDesc: "3 hours",
            createdAt: Date()
        )
        let geminiTick = StatusBarProviderTickFactory.geminiTick(gemini)
        XCTAssertNotNil(geminiTick.resetTimeText)
        XCTAssertTrue(geminiTick.resetTimeText?.contains("后重置") == true)

        // 2. Codex with reset time
        var snapshot = CodexUsageSnapshot.preview
        snapshot.shortWindow = UsageWindow(label: "5 小时", remaining: 10, total: 100, resetsAt: "2026-07-07 18:30:00")
        let codexTick = try XCTUnwrap(StatusBarProviderTickFactory.codexTick(
            id: "codex.test",
            label: "Codex Test",
            accountName: "Codex Test",
            usage: snapshot,
            isConnected: true
        ))
        XCTAssertNotNil(codexTick.resetTimeText)
        XCTAssertTrue(codexTick.resetTimeText?.hasSuffix("重置") == true)

        // 3. DeepSeek has no reset time
        let deepSeek = DeepSeekAPIConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "DeepSeek Primary",
            credentialHandle: "ds-handle",
            keySuffix: "1234",
            authenticationState: .connected,
            balance: ProviderBalanceSnapshot(
                connectionID: ConnectionID(rawValue: UUID()),
                providerID: .deepSeek,
                scope: .account,
                currency: "CNY",
                total: 50,
                granted: 10,
                toppedUp: 40,
                fetchedAt: Date()
            ),
            createdAt: Date()
        )
        let deepSeekTick = try XCTUnwrap(StatusBarProviderTickFactory.deepSeekTick(deepSeek))
        XCTAssertNil(deepSeekTick.resetTimeText)
    }

    func testUsageParserReadsRateLimitInsideUsageAndOmitsMissingSecondaryWindow() throws {
        let payload: [String: Any] = [
            "plan_type": "free",
            "usage": [
                "rate_limit": [
                    "primary_window": [
                        "limit_window_seconds": 2_592_000,
                        "used_percent": 26,
                        "reset_after_seconds": 3_600
                    ]
                ]
            ]
        ]

        let snapshot = TomoParser().parse(
            usagePayload: payload,
            resetCreditsPayload: nil,
            email: nil,
            accountName: nil
        )

        let primary = try XCTUnwrap(snapshot.shortWindow)
        XCTAssertEqual(primary.label, "30 天")
        XCTAssertEqual(primary.remaining, 74)
        XCTAssertEqual(primary.total, 100)
        XCTAssertFalse(snapshot.hasWeeklyWindow)
    }

    func testSubscriptionParserReadsActiveUntilAndWillRenew() {
        let payload: [String: Any] = [
            "plan_type": "plus",
            "active_until": "2026-08-21T06:22:29Z",
            "will_renew": 1,
        ]
        let parsed = TomoParser().parseSubscription(payload)
        XCTAssertEqual(parsed.activeUntilISO, "2026-08-21T06:22:29Z")
        XCTAssertEqual(parsed.willRenew, true)
    }

    func testSubscriptionExpiryReminderWithinSevenDays() {
        let expiry = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let iso = ISO8601DateFormatter().string(from: expiry)
        var snapshot = CodexUsageSnapshot.preview
        snapshot.subscriptionActiveUntilISO = iso
        snapshot.subscriptionWillRenew = false
        XCTAssertTrue(snapshot.showsSubscriptionExpiryReminder)
        XCTAssertNotNil(snapshot.subscriptionExpiryReminderMessage)
    }

    func testUsageParserKeepsAvailableResetCouponsSortedByExpiration() {
        let formatter = ISO8601DateFormatter()
        let soon = formatter.string(from: Date().addingTimeInterval(3_600))
        let later = formatter.string(from: Date().addingTimeInterval(7_200))
        let expired = formatter.string(from: Date().addingTimeInterval(-3_600))
        let resetPayload: [String: Any] = [
            "credits": [
                ["id": "later", "expires_at": later, "status": "available"],
                ["id": "expired", "expires_at": expired, "status": "available"],
                ["id": "soon", "expires_at": soon, "status": "available"]
            ]
        ]

        let snapshot = TomoParser().parse(
            usagePayload: [String: Any](),
            resetCreditsPayload: resetPayload,
            email: nil,
            accountName: nil
        )

        XCTAssertEqual(snapshot.resetCoupons.count, 2)
        XCTAssertEqual(snapshot.resetCoupons.reduce(0) { $0 + $1.count }, 2)
        XCTAssertLessThan(snapshot.resetCoupons[0].expiresAt, snapshot.resetCoupons[1].expiresAt)
    }

    func testResetCouponTimelineHasATenDayMinimumAndPreservesLongerExpiry() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-07-30T12:00:00Z"))
        let today = calendar.startOfDay(for: now)

        let shortCoupon = ResetCoupon(
            name: "Short",
            count: 1,
            expiresAt: formatter.string(from: calendar.date(byAdding: .day, value: 2, to: today)!),
            source: "Codex"
        )
        let minimumRange = ResetCouponDateParser.timelineRange(
            for: [shortCoupon],
            relativeTo: now,
            calendar: calendar
        )
        XCTAssertEqual(
            calendar.dateComponents([.day], from: minimumRange.min, to: minimumRange.max).day,
            10
        )
        let shortExpiry = try XCTUnwrap(ResetCouponDateParser.date(from: shortCoupon.expiresAt))
        XCTAssertEqual(
            ResetCouponDateParser.fraction(of: shortExpiry, in: minimumRange),
            0.2,
            accuracy: 0.0001
        )

        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        let tomorrowRange = ResetCouponDateParser.timelineRange(
            for: [shortCoupon],
            relativeTo: tomorrow,
            calendar: calendar
        )
        XCTAssertEqual(
            ResetCouponDateParser.fraction(of: shortExpiry, in: tomorrowRange),
            0.1,
            accuracy: 0.0001
        )

        let laterExpiry = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: today))
        let longCoupon = ResetCoupon(
            name: "Long",
            count: 1,
            expiresAt: formatter.string(from: laterExpiry),
            source: "Codex"
        )
        let extendedRange = ResetCouponDateParser.timelineRange(
            for: [longCoupon],
            relativeTo: now,
            calendar: calendar
        )
        XCTAssertEqual(extendedRange.max, laterExpiry)
    }

    @MainActor
    func testRefreshStateKeepsLastSuccessfulFetchTimeUntilApply() {
        var snapshot = CodexUsageSnapshot.preview
        snapshot.fetchedAt = Date(timeIntervalSince1970: 123)
        let store = UsageSnapshotStore(
            snapshot: snapshot,
            isLoggedIn: true,
            persistsCache: false
        )

        store.markRefreshing(allowsAuthorization: false)
        XCTAssertEqual(store.snapshot.fetchedAt, snapshot.fetchedAt)

        store.markFailed("网络不可用")
        XCTAssertEqual(store.snapshot.fetchedAt, snapshot.fetchedAt)

        var refreshed = snapshot
        refreshed.fetchedAt = Date(timeIntervalSince1970: 456)
        store.apply(refreshed)
        XCTAssertEqual(store.snapshot.fetchedAt, refreshed.fetchedAt)
    }

    func testStatusBarQuotaTextOmitsZeroTotalSecondaryWindow() {
        var snapshot = CodexUsageSnapshot.preview
        snapshot.planName = "plus"
        snapshot.shortWindow = UsageWindow(label: "5 小时", remaining: 71, total: 100, resetsAt: "")
        snapshot.weekly = UsageWindow(label: "周额度", remaining: 0, total: 0, resetsAt: "")

        XCTAssertEqual(statusBarQuotaText(snapshot: snapshot, isLoggedIn: true), "5h 71%")
    }

    func testStatusBarQuotaTextUsesTheActualPrimaryWindowLabel() {
        var snapshot = CodexUsageSnapshot.preview
        snapshot.planName = "plus"
        snapshot.shortWindow = UsageWindow(label: "周额度", remaining: 51, total: 100, resetsAt: "")
        snapshot.weekly = UsageWindow(label: "周额度", remaining: 0, total: 0, resetsAt: "")

        XCTAssertEqual(statusBarQuotaText(snapshot: snapshot, isLoggedIn: true), "周 51%")
    }

    func testStatusBarQuotaTextHandlesNoValidQuota() {
        var snapshot = CodexUsageSnapshot.preview
        snapshot.shortWindow = nil
        snapshot.weekly = UsageWindow(label: "周额度", remaining: 0, total: 0, resetsAt: "未知")

        XCTAssertEqual(statusBarQuotaText(snapshot: snapshot, isLoggedIn: true), "无额度")
        XCTAssertEqual(statusBarQuotaText(snapshot: snapshot, isLoggedIn: false), "未登录")
    }

    @MainActor
    func testStatusCapsuleReservesStableWidthForEachQuotaLayout() {
        var snapshot = CodexUsageSnapshot.preview
        snapshot.shortWindow = UsageWindow(label: "5 小时", remaining: 71, total: 100, resetsAt: "")
        snapshot.weekly = UsageWindow(label: "周额度", remaining: 0, total: 0, resetsAt: "")
        XCTAssertEqual(
            statusCapsuleReservedText(snapshot: snapshot, isLoggedIn: true, showsActivity: false),
            "5h 99%"
        )

        snapshot.shortWindow = nil
        snapshot.weekly = UsageWindow(label: "周额度", remaining: 51, total: 100, resetsAt: "")
        XCTAssertEqual(
            statusCapsuleReservedText(snapshot: snapshot, isLoggedIn: true, showsActivity: false),
            "周 99%"
        )

        snapshot.shortWindow = UsageWindow(label: "5 小时", remaining: 71, total: 100, resetsAt: "")
        XCTAssertEqual(
            statusCapsuleReservedText(snapshot: snapshot, isLoggedIn: true, showsActivity: false),
            "5h 99%·周 99%"
        )
        XCTAssertEqual(
            statusCapsuleReservedText(snapshot: snapshot, isLoggedIn: true, showsActivity: true),
            "思考中·5h 99%·周 99%"
        )

        if let outputPath = ProcessInfo.processInfo.environment["CODEXLING_CAPSULE_DEBUG_OUTPUT"] {
            try? renderStatusCapsuleDebugGallery(to: outputPath)
        }
    }

    @MainActor
    func testEveryActivityStateUsesTheExpectedCompactCapsuleWidth() {
        let expectedLabels: [CodexActivityState: String?] = [
            .unavailable: nil,
            .idle: nil,
            .thinking: "思考中",
            .executing: "工作中",
            .reviewing: "检查中",
            .waitingForUser: "待确认",
            .completed: "已完成",
            .interrupted: "已中止",
        ]
        XCTAssertEqual(CodexActivityState.allCases.count, expectedLabels.count)

        var widths: [CGFloat] = []
        for state in CodexActivityState.allCases {
            XCTAssertEqual(state.statusBarText, expectedLabels[state] ?? nil)
            guard let statusText = state.statusBarText else { continue }
            XCTAssertEqual(statusText.count, 3, "\(state.rawValue) 不应超过三个字符")

            let capsule = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 1, height: 26))
            capsule.update(
                background: .neutral,
                text: "\(statusText)·周 90%",
                reservedText: "思考中·周 99%",
                foregroundColor: StatusBarPetBackgroundColor.neutral.foregroundColor,
                showsPet: false,
                indicatorColor: .systemGreen,
                showsWave: false,
                cornerRatio: 0.5
            )
            widths.append(capsule.preferredWidth)
        }

        XCTAssertEqual(Set(widths).count, 1, "所有有文案的活动状态必须保持相同胶囊宽度")

        if let outputPath = ProcessInfo.processInfo.environment[
            "CODEXLING_CAPSULE_COLOR_DEBUG_OUTPUT"
        ] {
            try? renderStatusCapsuleColorAndIndicatorGallery(to: outputPath)
        }
    }

    @MainActor
    private func renderStatusCapsuleDebugGallery(to outputPath: String) throws {
        var cases: [(String, String, String)] = [
            ("仅周 · 单位数", "周 9%", "周 99%"),
            ("仅周 · 常态", "周 90%", "周 99%"),
            ("仅周 · 满额", "周 100%", "周 99%"),
            ("仅 5h", "5h 90%", "5h 99%"),
            ("双额度", "5h 90%·周 90%", "5h 99%·周 99%"),
        ]
        cases.append(contentsOf: CodexActivityState.allCases.map { state in
            let text = state.statusBarText.map { "\($0)·周 90%" } ?? "周 90%"
            let reserved = state.statusBarText == nil ? "周 99%" : "思考中·周 99%"
            return ("状态 · \(state.rawValue)", text, reserved)
        })
        cases.append(
            ("状态 + 双额度", "工作中·5h 90%·周 90%", "思考中·5h 99%·周 99%")
        )
        let rowHeight: CGFloat = 44
        let canvasSize = NSSize(width: 470, height: rowHeight * CGFloat(cases.count) + 20)
        let image = NSImage(size: canvasSize)

        image.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        for (index, item) in cases.enumerated() {
            let y = canvasSize.height - 20 - rowHeight * CGFloat(index + 1)
            item.0.draw(
                at: NSPoint(x: 16, y: y + 13),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )

            let capsule = StatusCapsuleView(frame: NSRect(x: 0, y: 0, width: 1, height: 26))
            capsule.update(
                background: .neutral,
                text: item.1,
                reservedText: item.2,
                foregroundColor: StatusBarPetBackgroundColor.neutral.foregroundColor,
                showsPet: false,
                indicatorColor: .systemGreen,
                showsWave: false,
                cornerRatio: 0.5
            )
            capsule.frame.size.width = capsule.preferredWidth
            guard let representation = capsule.bitmapImageRepForCachingDisplay(in: capsule.bounds) else {
                continue
            }
            capsule.cacheDisplay(in: capsule.bounds, to: representation)
            representation.draw(
                in: NSRect(
                    x: 150,
                    y: y + 8,
                    width: capsule.bounds.width,
                    height: capsule.bounds.height
                )
            )
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @MainActor
    private func renderStatusCapsuleColorAndIndicatorGallery(to outputPath: String) throws {
        let backgrounds: [(String, StatusBarPetBackgroundColor)] = [
            ("健康绿", .green),
            ("提醒黄", .yellow),
            ("告警红", .red),
            ("未知灰", .gray),
        ]
        let states = CodexActivityState.allCases
        let columnWidth: CGFloat = 220
        let rowHeight: CGFloat = 47
        let canvasSize = NSSize(
            width: 132 + columnWidth * CGFloat(backgrounds.count),
            height: 100 + rowHeight * CGFloat(states.count)
        )
        let image = NSImage(size: canvasSize)

        image.lockFocus()
        NSGradient(colors: [
            NSColor(srgbRed: 0.93, green: 0.95, blue: 0.87, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1),
        ])?.draw(
            from: NSPoint(x: canvasSize.width / 2, y: 0),
            to: NSPoint(x: canvasSize.width / 2, y: canvasSize.height),
            options: []
        )

        "固定中性底 × 提醒文字色 × 任务圆灯".draw(
            at: NSPoint(x: 20, y: canvasSize.height - 34),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        for (column, background) in backgrounds.enumerated() {
            background.0.draw(
                at: NSPoint(
                    x: 132 + CGFloat(column) * columnWidth + 72,
                    y: canvasSize.height - 64
                ),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: background.1.foregroundColor,
                ]
            )
        }

        for (row, state) in states.enumerated() {
            let rowY = canvasSize.height - 94 - rowHeight * CGFloat(row + 1)
            state.rawValue.draw(
                at: NSPoint(x: 20, y: rowY + 9),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )

            for (column, background) in backgrounds.enumerated() {
                let statusText = state.statusBarText
                let text = statusText.map { "\($0)·周 82%" } ?? "周 82%"
                let reservedText = statusText == nil ? "周 99%" : "思考中·周 99%"
                let capsule = StatusCapsuleView(
                    frame: NSRect(x: 0, y: 0, width: 1, height: 26)
                )
                capsule.update(
                    background: background.1,
                    text: text,
                    reservedText: reservedText,
                    foregroundColor: background.1.foregroundColor,
                    showsPet: false,
                    indicatorColor: state.statusNSColor,
                    showsWave: false,
                    cornerRatio: 0.5
                )
                capsule.frame.size.width = capsule.preferredWidth

                let x = 132
                    + CGFloat(column) * columnWidth
                    + (columnWidth - capsule.bounds.width) / 2
                let scale: CGFloat = 2
                guard let representation = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(capsule.bounds.width * scale),
                    pixelsHigh: Int(capsule.bounds.height * scale),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else {
                    continue
                }
                representation.size = capsule.bounds.size
                if let bitmapContext = NSGraphicsContext(bitmapImageRep: representation) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = bitmapContext
                    NSColor.clear.setFill()
                    capsule.bounds.fill(using: .copy)
                    NSGraphicsContext.restoreGraphicsState()
                }
                capsule.cacheDisplay(in: capsule.bounds, to: representation)
                let targetRect = NSRect(
                    x: x,
                    y: rowY + 3,
                    width: capsule.bounds.width,
                    height: capsule.bounds.height
                )
                NSGraphicsContext.saveGraphicsState()
                let capsuleClipRect = targetRect.insetBy(dx: 0.5, dy: 0.5)
                NSBezierPath(
                    roundedRect: capsuleClipRect,
                    xRadius: capsuleClipRect.height / 2,
                    yRadius: capsuleClipRect.height / 2
                ).addClip()
                representation.draw(in: targetRect)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    func testDetailWindowFallsBackToThePrimaryWindow() throws {
        var snapshot = CodexUsageSnapshot.preview
        snapshot.shortWindow = UsageWindow(label: "周额度", remaining: 50, total: 100, resetsAt: "2026-07-21 15:12:08")
        snapshot.weekly = UsageWindow(label: "周额度", remaining: 0, total: 0, resetsAt: "未知")

        let detailWindow = try XCTUnwrap(snapshot.detailWindow)
        XCTAssertEqual(detailWindow.label, "周额度")
        XCTAssertEqual(detailWindow.resetsAt, "2026-07-21 15:12:08")
    }

    func testActivityParserDetectsWaitingForUser() {
        let jsonl = """
        {"timestamp":"2026-07-17T08:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-17T08:00:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"我正在检查项目。"}}
        {"timestamp":"2026-07-17T08:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"request_user_input","arguments":"{}"}}
        """
        let result = CodexActivityEventParser().parse(
            data: Data(jsonl.utf8),
            title: "测试任务",
            now: ISO8601DateFormatter().date(from: "2026-07-17T08:00:03Z")!
        )

        XCTAssertEqual(result.state, .waitingForUser)
        XCTAssertTrue(result.isActive)
        XCTAssertEqual(result.detail, "需要你的确认后才能继续")
    }

    func testActivityParserPreservesStableThreadID() {
        let jsonl = """
        {"timestamp":"2026-07-17T08:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        """
        let result = CodexActivityEventParser().parse(
            data: Data(jsonl.utf8),
            id: "thread-stable-id",
            title: "测试任务"
        )

        XCTAssertEqual(result.id, "thread-stable-id")
    }

    @MainActor
    func testCompanionStatsAccumulateOnlyActiveIntervalsAndPersist() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-22T08:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = CompanionStatsStore(fileURL: fileURL, now: start, calendar: calendar)

        store.setActivityState(.executing, now: start)
        store.tick(now: start.addingTimeInterval(60))
        store.setActivityState(.idle, now: start.addingTimeInterval(120))
        store.tick(now: start.addingTimeInterval(300))

        XCTAssertEqual(store.todayMinutes, 2)
        let restored = CompanionStatsStore(
            fileURL: fileURL,
            now: start.addingTimeInterval(300),
            calendar: calendar
        )
        XCTAssertEqual(restored.todayMinutes, 2)
    }

    @MainActor
    func testCompanionStatsCapSleepIntervalsAndResetAcrossDay() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-22T22:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = CompanionStatsStore(fileURL: fileURL, now: start, calendar: calendar)

        store.setActivityState(.thinking, now: start)
        store.tick(now: start.addingTimeInterval(600))
        XCTAssertEqual(store.todaySeconds, 90, accuracy: 0.001)

        store.tick(now: start.addingTimeInterval(7_200))
        XCTAssertEqual(store.todaySeconds, 0, accuracy: 0.001)
    }

    func testActivityParserKeepsRecentCompletionThenReturnsIdle() {
        let jsonl = """
        {"timestamp":"2026-07-17T08:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-17T08:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}
        """
        let parser = CodexActivityEventParser()
        let formatter = ISO8601DateFormatter()

        let recent = parser.parse(
            data: Data(jsonl.utf8),
            title: "测试任务",
            now: formatter.date(from: "2026-07-17T08:00:10Z")!
        )
        XCTAssertEqual(recent.state, .completed)

        let expired = parser.parse(
            data: Data(jsonl.utf8),
            title: "测试任务",
            now: formatter.date(from: "2026-07-17T08:00:30Z")!
        )
        XCTAssertEqual(expired.state, .idle)
    }

    func testActivityReaderExpandsPastFourMegabytesToKeepTaskState() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-activity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var data = Data("{\"timestamp\":\"2026-07-17T08:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".utf8)
        let filler = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8)
        while data.count < 5 * 1_024 * 1_024 {
            data.append(filler)
        }
        data.append(Data("{\"timestamp\":\"2026-07-17T08:01:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"exec_command\",\"arguments\":\"{}\"}}\n".utf8))
        try data.write(to: fileURL)

        let service = CodexActivityService(databaseURLs: [])
        let parsed = CodexActivityEventParser().parse(
            data: try XCTUnwrap(service.readTail(of: fileURL)),
            title: "长任务"
        )

        XCTAssertEqual(parsed.state, .executing)
        XCTAssertTrue(parsed.isActive)
    }

    func testActivityServiceReturnsAllActiveTasksWithStableIDsAndPriority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-activity-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executingURL = directory.appendingPathComponent("executing.jsonl")
        let waitingURL = directory.appendingPathComponent("waiting.jsonl")
        try Data("""
        {"timestamp":"2026-07-22T08:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-22T08:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"exec_command","arguments":"{}"}}
        """.utf8).write(to: executingURL)
        try Data("""
        {"timestamp":"2026-07-22T08:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-22T08:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"call-2","name":"request_user_input","arguments":"{}"}}
        """.utf8).write(to: waitingURL)

        let databaseURL = directory.appendingPathComponent("state.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            title TEXT NOT NULL,
            archived INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """, nil, nil, nil), SQLITE_OK)
        let insert = """
        INSERT INTO threads VALUES
        ('thread-executing', '\(executingURL.path)', '执行任务', 0, 1),
        ('thread-waiting', '\(waitingURL.path)', '等待任务', 0, 2);
        """
        XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)

        let snapshot = CodexActivityService(databaseURLs: [databaseURL]).loadSnapshot(
            now: ISO8601DateFormatter().date(from: "2026-07-22T08:00:03Z")!
        )

        XCTAssertEqual(snapshot.activeTaskCount, 2)
        XCTAssertEqual(snapshot.activeTasks.map(\.id), ["thread-waiting", "thread-executing"])
        XCTAssertEqual(snapshot.activeTasks.map(\.state), [.waitingForUser, .executing])
        XCTAssertEqual(snapshot.state, .waitingForUser)
    }

    func testActivityServiceCountsOnlyConcurrentUserThreads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-concurrent-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func writeActivity(_ name: String, tool: String) throws -> URL {
            let url = directory.appendingPathComponent("\(name).jsonl")
            try Data("""
            {"timestamp":"2026-07-22T08:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"2026-07-22T08:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"\(name)","name":"\(tool)","arguments":"{}"}}
            """.utf8).write(to: url)
            return url
        }

        let firstURL = try writeActivity("first", tool: "exec_command")
        let secondURL = try writeActivity("second", tool: "view_image")
        let subagentURL = try writeActivity("guardian", tool: "exec_command")
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            title TEXT NOT NULL,
            archived INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            thread_source TEXT
        );
        """, nil, nil, nil), SQLITE_OK)
        let insert = """
        INSERT INTO threads VALUES
        ('thread-first', '\(firstURL.path)', '任务一', 0, 3, 'user'),
        ('thread-second', '\(secondURL.path)', '任务二', 0, 2, 'user'),
        ('thread-guardian', '\(subagentURL.path)', '守护进程', 0, 1, 'subagent');
        """
        XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)

        let snapshot = CodexActivityService(databaseURLs: [databaseURL]).loadSnapshot(
            now: ISO8601DateFormatter().date(from: "2026-07-22T08:00:03Z")!
        )

        XCTAssertEqual(snapshot.activeTaskCount, 2)
        XCTAssertEqual(Set(snapshot.activeTasks.map(\.id)), ["thread-first", "thread-second"])
        XCTAssertFalse(snapshot.activeTasks.contains { $0.id == "thread-guardian" })
    }

    func testActivitySnapshotStabilizerIgnoresOneTransientTaskRemoval() {
        let now = Date()
        let first = CodexTaskActivity(
            id: "first",
            state: .thinking,
            detail: "分析中",
            title: "任务一",
            updatedAt: now
        )
        let second = CodexTaskActivity(
            id: "second",
            state: .executing,
            detail: "执行中",
            title: "任务二",
            updatedAt: now
        )
        let current = CodexActivitySnapshot(
            state: .thinking,
            detail: first.detail,
            threadTitle: first.title,
            activeTaskCount: 2,
            updatedAt: now,
            activeTasks: [first, second]
        )
        let transient = CodexActivitySnapshot(
            state: .thinking,
            detail: first.detail,
            threadTitle: first.title,
            activeTaskCount: 1,
            updatedAt: now,
            activeTasks: [first]
        )
        var stabilizer = CodexActivitySnapshotStabilizer()

        XCTAssertNil(stabilizer.resolve(current: current, candidate: transient))
        XCTAssertEqual(
            stabilizer.resolve(current: current, candidate: current),
            current
        )
        XCTAssertNil(stabilizer.resolve(current: current, candidate: transient))
    }

    func testActivitySnapshotStabilizerAcceptsConfirmedTaskRemoval() {
        let now = Date()
        let task = CodexTaskActivity(
            id: "task",
            state: .executing,
            detail: "执行中",
            title: "任务",
            updatedAt: now
        )
        let current = CodexActivitySnapshot(
            state: .executing,
            detail: task.detail,
            threadTitle: task.title,
            activeTaskCount: 1,
            updatedAt: now,
            activeTasks: [task]
        )
        let idle = CodexActivitySnapshot(
            state: .idle,
            detail: "当前没有正在执行的 Codex 任务",
            threadTitle: task.title,
            activeTaskCount: 0,
            updatedAt: now
        )
        var stabilizer = CodexActivitySnapshotStabilizer()

        XCTAssertNil(stabilizer.resolve(current: current, candidate: idle))
        XCTAssertEqual(
            stabilizer.resolve(current: current, candidate: idle),
            idle
        )
    }

    func testActiveAgentStatusesGroupTasksAndKeepFreshestAgentState() {
        let now = Date()
        let snapshot = CodexActivitySnapshot(
            state: .executing,
            detail: "多个 Agent 正在工作",
            threadTitle: "多 Agent",
            activeTaskCount: 3,
            updatedAt: now,
            activeTasks: [
                CodexTaskActivity(
                    id: "codex-task",
                    state: .thinking,
                    detail: "Codex 正在思考",
                    title: "规划轮播状态",
                    updatedAt: now.addingTimeInterval(-2),
                    model: "gpt-5.6-sol"
                ),
                CodexTaskActivity(
                    id: "hermes-new",
                    state: .executing,
                    detail: "Hermes 正在使用工具",
                    title: "Hermes · CLI",
                    updatedAt: now,
                    model: "Hermes"
                ),
                CodexTaskActivity(
                    id: "hermes-old",
                    state: .thinking,
                    detail: "Hermes 正在思考",
                    title: "Hermes · CLI",
                    updatedAt: now.addingTimeInterval(-5),
                    model: "Hermes"
                )
            ]
        )

        XCTAssertEqual(snapshot.activeAgentStatuses.map(\.agentName), ["Hermes", "Codex"])
        XCTAssertEqual(snapshot.activeAgentStatuses[0].state, .executing)
        XCTAssertEqual(snapshot.activeAgentStatuses[0].taskCount, 2)
        XCTAssertEqual(snapshot.activeAgentStatuses[1].taskCount, 1)
    }

    func testStatusBarTaskTicksKeepMultipleTasksFromTheSameAgentNavigable() {
        let now = Date()
        let snapshot = CodexActivitySnapshot(
            state: .waitingForUser,
            detail: "多个任务",
            threadTitle: "等待任务",
            activeTaskCount: 2,
            updatedAt: now,
            activeTasks: [
                CodexTaskActivity(
                    id: "codex-waiting",
                    state: .waitingForUser,
                    detail: "等待确认",
                    title: "任务二",
                    updatedAt: now
                ),
                CodexTaskActivity(
                    id: "codex-executing",
                    state: .executing,
                    detail: "执行工具",
                    title: "任务一",
                    updatedAt: now.addingTimeInterval(-1)
                )
            ]
        )

        XCTAssertEqual(snapshot.activeAgentStatuses.count, 1)
        XCTAssertEqual(snapshot.statusBarTaskTicks.count, 2)
        XCTAssertEqual(snapshot.statusBarTaskTicks.map(\.id), ["codex-waiting", "codex-executing"])
        XCTAssertEqual(snapshot.statusBarTaskTicks.map(\.taskTitle), ["任务二", "任务一"])
        XCTAssertEqual(snapshot.statusBarTaskTicks.map(\.taskCount), [2, 2])
    }

    func testActivityServicePrefersIndexedThreadNameAndLoadsTaskMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-title-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rolloutURL = directory.appendingPathComponent("activity.jsonl")
        try Data("""
        {"timestamp":"2026-07-22T08:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        """.utf8).write(to: rolloutURL)
        let sessionIndexURL = directory.appendingPathComponent("session_index.jsonl")
        try Data("""
        {"id":"thread-title","thread_name":"评估并更新 Tomo UI","updated_at":"2026-07-22T08:00:00Z"}
        """.utf8).write(to: sessionIndexURL)

        let databaseURL = directory.appendingPathComponent("state.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            title TEXT NOT NULL,
            name TEXT,
            cwd TEXT,
            git_branch TEXT,
            model TEXT,
            archived INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        INSERT INTO threads VALUES (
            'thread-title',
            '\(rolloutURL.path)',
            '/goal /tmp/Tomo',
            '',
            '/tmp/Tomo',
            'main',
            'gpt-5.6-sol',
            0,
            1
        );
        """, nil, nil, nil), SQLITE_OK)

        let snapshot = CodexActivityService(
            databaseURLs: [databaseURL],
            sessionIndexURLs: [sessionIndexURL]
        ).loadSnapshot(now: ISO8601DateFormatter().date(from: "2026-07-22T08:00:01Z")!)

        XCTAssertEqual(snapshot.threadTitle, "评估并更新 Tomo UI")
        XCTAssertEqual(snapshot.activeTasks.first?.title, "评估并更新 Tomo UI")
        XCTAssertEqual(snapshot.activeTasks.first?.workspaceName, "Tomo")
        XCTAssertEqual(snapshot.activeTasks.first?.gitBranch, "main")
        XCTAssertEqual(snapshot.activeTasks.first?.model, "gpt-5.6-sol")
    }

    func testHoverContentUsesThreadTitleAndVisibleExecutionSummary() {
        let snapshot = CodexActivitySnapshot(
            state: .executing,
            detail: "正在运行本地命令",
            threadTitle: "规划状态栏 Pets 状态展示",
            activeTaskCount: 1,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.hoverDisplayTitle, "规划状态栏 Pets 状态展示")
        XCTAssertEqual(snapshot.hoverSubtitle, "正在运行本地命令")
    }

    func testBuiltInPetsAreDiscoverableStandaloneWithoutCodex() throws {
        let catalog = CodexPetCatalog()
        let builtIns = catalog.discover().filter { $0.source == .codexBuiltIn }

        XCTAssertGreaterThanOrEqual(builtIns.count, 10)
        XCTAssertTrue(builtIns.allSatisfy { $0.rowCount >= 9 })
        XCTAssertTrue(builtIns.contains { $0.assetID == "codexling" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "codex" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "dewey" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "fireball" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "hoots" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "null-signal" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "rocky" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "seedy" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "stacky" })
        XCTAssertTrue(builtIns.contains { $0.assetID == "bsod" })
    }

    @MainActor
    func testPetBidirectionalSyncManagerPerformsTwoWaySync() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-test-\(UUID().uuidString)", isDirectory: true)
        let appSupportPets = tempDir.appendingPathComponent("AppSupport/Tomo/Pets", isDirectory: true)
        let codexPets = tempDir.appendingPathComponent(".codex/pets", isDirectory: true)
        let configURL = tempDir.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: appSupportPets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexPets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Setup custom-dog in AppSupport
        let dogDir = appSupportPets.appendingPathComponent("custom-dog", isDirectory: true)
        try FileManager.default.createDirectory(at: dogDir, withIntermediateDirectories: true)
        try """
        {"id":"custom-dog","displayName":"Doggo","spriteVersionNumber":2,"spritesheetPath":"spritesheet.webp"}
        """.write(to: dogDir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        try "dummy-dog-sheet".write(to: dogDir.appendingPathComponent("spritesheet.webp"), atomically: true, encoding: .utf8)

        // Setup custom-cat in Codex
        let catDir = codexPets.appendingPathComponent("custom-cat", isDirectory: true)
        try FileManager.default.createDirectory(at: catDir, withIntermediateDirectories: true)
        try """
        {"id":"custom-cat","displayName":"Kitty","spriteVersionNumber":2,"spritesheetPath":"spritesheet.webp"}
        """.write(to: catDir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        try "dummy-cat-sheet".write(to: catDir.appendingPathComponent("spritesheet.webp"), atomically: true, encoding: .utf8)

        let syncManager = PetBidirectionalSyncManager(
            appSupportPetsRoot: appSupportPets,
            codexPetsRoot: codexPets,
            configURL: configURL
        )

        let firstResult = syncManager.performBidirectionalSync()
        XCTAssertGreaterThanOrEqual(firstResult.forwardCount, 1)
        XCTAssertGreaterThanOrEqual(firstResult.reverseCount, 1)

        // Verify custom-dog was synced forward to .codex/pets
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexPets.appendingPathComponent("custom-dog/pet.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexPets.appendingPathComponent("custom-dog/spritesheet.webp").path))

        // Verify custom-cat was synced in reverse to AppSupport/Tomo/Pets
        XCTAssertTrue(FileManager.default.fileExists(atPath: appSupportPets.appendingPathComponent("custom-cat/pet.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appSupportPets.appendingPathComponent("custom-cat/spritesheet.webp").path))

        // Re-running sync should be idempotent and produce 0 changes
        let secondResult = syncManager.performBidirectionalSync()
        XCTAssertEqual(secondResult.forwardCount, 0)
        XCTAssertEqual(secondResult.reverseCount, 0)
    }

    func testCodexPetSelectionSyncReadsAndMapsPetIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try """
        model = "gpt-5"

        [desktop]
        selected-avatar-id = "custom:nimbus"
        avatar-overlay-mascot-width-px = 155
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let sync = CodexPetSelectionSync(configURL: configURL)
        XCTAssertEqual(sync.readSelectedPetID(), "custom:nimbus")
        XCTAssertEqual(sync.codexPetID(fromAppID: "builtin:hoots"), "hoots")
        XCTAssertEqual(sync.appPetID(fromCodexID: "hoots"), "builtin:hoots")
    }

    func testCodexPetSelectionSyncUpdatesOnlyDesktopSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try """
        selected-avatar-id = "leave-this-alone"

        [desktop]
        selected-avatar-id = "custom:nimbus"
        avatar-overlay-mascot-width-px = 155

        [desktop.open-in-target-preferences]
        global = "cursor"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let sync = CodexPetSelectionSync(configURL: configURL)
        XCTAssertTrue(try sync.writeSelectedPetID("builtin:hoots"))
        let updated = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertTrue(updated.contains("selected-avatar-id = \"leave-this-alone\""))
        XCTAssertTrue(updated.contains("[desktop]\nselected-avatar-id = \"hoots\""))
        XCTAssertTrue(updated.contains("avatar-overlay-mascot-width-px = 155"))
        XCTAssertEqual(sync.readSelectedPetID(), "builtin:hoots")
        XCTAssertFalse(try sync.writeSelectedPetID("builtin:hoots"))
    }

    @MainActor
    func testCodexPetSelectionMonitorDetectsAtomicConfigReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try """
        [desktop]
        selected-avatar-id = "custom:nimbus"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let changeDetected = expectation(description: "Pet config change detected")
        let monitor = CodexPetSelectionMonitor(
            configURL: configURL,
            debounceInterval: 0.05
        ) {
            changeDetected.fulfill()
        }
        monitor.start()

        try """
        [desktop]
        selected-avatar-id = "custom:levi"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [changeDetected], timeout: 2)
        monitor.stop()
    }

    @MainActor
    func testWindowAlwaysOnTopPreferencePersists() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.windowAlwaysOnTop)

        settings.windowAlwaysOnTop = true
        XCTAssertTrue(defaults.bool(forKey: "codexling.windowAlwaysOnTop"))

        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(restored.windowAlwaysOnTop)
    }

    @MainActor
    func testDashboardOrientationDefaultsToHorizontalAndPersists() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.dashboardOrientation, .horizontal)

        var notified: DashboardOrientation?
        settings.onDashboardOrientationChanged = { notified = $0 }
        settings.dashboardOrientation = .vertical

        XCTAssertEqual(notified, .vertical)
        XCTAssertEqual(defaults.string(forKey: "codexling.dashboardOrientation"), "vertical")

        let restored = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.dashboardOrientation, .vertical)
    }

    func testVerticalDashboardKeepsNarrowWidthAndFollowsMeasuredHeight() {
        let horizontal = DetachedWindowMetrics.fixedDashboardContentSize(
            isLoggedIn: true,
            orientation: .horizontal
        )
        XCTAssertEqual(horizontal.width, DetachedWindowMetrics.dashboardWidth)
        XCTAssertEqual(horizontal.height, DetachedWindowMetrics.loggedInDashboardHeight)

        let horizontalMeasured = DetachedWindowMetrics.fixedDashboardContentSize(
            isLoggedIn: true,
            orientation: .horizontal,
            measuredHeight: 548
        )
        XCTAssertEqual(horizontalMeasured.height, DetachedWindowMetrics.loggedInDashboardHeight)

        let unmeasured = DetachedWindowMetrics.fixedDashboardContentSize(
            isLoggedIn: true,
            orientation: .vertical
        )
        XCTAssertEqual(unmeasured.width, DetachedWindowMetrics.verticalDashboardWidth)
        XCTAssertEqual(unmeasured.height, DetachedWindowMetrics.verticalProvisionalHeight)
        XCTAssertEqual(
            DetachedWindowMetrics.verticalProvisionalHeight,
            DetachedWindowMetrics.loggedInDashboardHeight
        )

        XCTAssertFalse(
            DetachedWindowMetrics.isValidVerticalMeasurement(
                CGSize(width: DetachedWindowMetrics.dashboardWidth, height: 480)
            )
        )
        XCTAssertTrue(
            DetachedWindowMetrics.isValidVerticalMeasurement(
                CGSize(width: DetachedWindowMetrics.verticalDashboardWidth, height: 638.4)
            )
        )

        let measured = DetachedWindowMetrics.fixedDashboardContentSize(
            isLoggedIn: true,
            orientation: .vertical,
            measuredHeight: 638.4
        )
        XCTAssertEqual(measured.width, DetachedWindowMetrics.verticalDashboardWidth)
        XCTAssertEqual(measured.height, 639)

        // 内容过矮时不塌陷，未登录时复用登录页高度。
        let clamped = DetachedWindowMetrics.fixedDashboardContentSize(
            isLoggedIn: true,
            orientation: .vertical,
            measuredHeight: 40
        )
        XCTAssertEqual(clamped.height, DetachedWindowMetrics.verticalMinHeight)

        let loggedOut = DetachedWindowMetrics.fixedDashboardContentSize(
            isLoggedIn: false,
            orientation: .vertical,
            measuredHeight: 900
        )
        XCTAssertEqual(loggedOut.height, DetachedWindowMetrics.loginDashboardHeight)
    }

    @MainActor
    func testPetInteractionRemainsAvailableWhileCodexIsWorking() {
        let pet = CodexPet(
            id: "custom:test",
            assetID: "test",
            displayName: "Test",
            description: "",
            source: .custom,
            spriteVersionNumber: 2,
            spritesheetURL: URL(fileURLWithPath: "/private/tmp/nonexistent-pet.png"),
            rowCount: 9
        )
        let frameStore = PetFrameStore()

        frameStore.update(pet: pet, activityState: .executing)

        XCTAssertTrue(frameStore.canPlayIdleInteraction)
        let firstAction = frameStore.playRandomIdleAction()
        let secondAction = frameStore.playRandomIdleAction()
        XCTAssertNotNil(firstAction)
        XCTAssertNotNil(secondAction)
        XCTAssertNotEqual(firstAction, secondAction)
        frameStore.stop()
    }

    func testInstalledCodexActivityIsReadableWhenDatabaseExists() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let database = home.appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return }

        let snapshot = CodexActivityService(databaseURLs: [database]).loadSnapshot()
        XCTAssertNotEqual(snapshot.state, .unavailable)
        XCTAssertFalse(snapshot.hoverSubtitle.isEmpty)
    }

    func testOAuthCallbackServerCanBeCancelledImmediately() async throws {
        let server = OAuthCallbackServer(expectedState: "test-state")
        let waiting = Task {
            try await server.waitForCode(timeoutSeconds: 5)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        server.cancel()

        do {
            _ = try await waiting.value
            XCTFail("Expected OAuth cancellation")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .oauthCancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    @MainActor
    func testLegacyTaskColorPreferenceMigratesToFollowQuota() throws {
        let suiteName = "TomoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("cyan", forKey: "codexling.petBackgroundColor")

        XCTAssertEqual(AppSettingsStore(defaults: defaults).petBackgroundColor, .neutral)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
}
