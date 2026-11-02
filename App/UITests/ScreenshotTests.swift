import XCTest

/// Captures d'écran de la documentation, en mode démonstration (`-demo` : films et séries
/// inventés, images générées). Lancé par le workflow « Captures d'écran », pas par la CI
/// habituelle. Les images sont jointes au résultat et écrites dans `SCREENSHOTS_DIR`.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { XCUIRemote.shared }

    override nonisolated func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, pause: TimeInterval = 0.5) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: pause)
        }
    }

    private var tabBarHasFocus: Bool {
        app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }

    private func focusContent() {
        var n = 0
        while tabBarHasFocus && n < 4 { press(.down); n += 1 }
    }

    private func goToTab(_ name: String) {
        var n = 0
        while !tabBarHasFocus && n < 8 { press(.up); n += 1 }
        press(.left, times: 7, pause: 0.3)
        let target = app.tabBars.buttons[name]
        n = 0
        while !target.hasFocus && n < 8 { press(.right); n += 1 }
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func focusedLabel() -> String {
        let element = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return element.exists ? element.label : ""
    }

    private func shot(_ name: String, wait: TimeInterval = 3) {
        Thread.sleep(forTimeInterval: wait)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    func testCaptureScreenshots() {
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Continuer à regarder"].waitForExistence(timeout: 30), "accueil de démonstration absent")
        Thread.sleep(forTimeInterval: 6)  // images (dépôt GitHub) et bandeau

        // Accueil : bandeau du titre sélectionné, rangées.
        focusContent()
        shot("01-accueil", wait: 6)
        press(.down, times: 2)
        shot("02-accueil-rangees", wait: 4)

        // Fiche film (premier titre de « Continuer à regarder »).
        press(.up, times: 2)
        press(.left, times: 3, pause: 0.3)
        press(.select)
        if app.buttons["detail.play"].waitForExistence(timeout: 15) {
            shot("03-fiche-film", wait: 5)
            // Sources, avec filtres.
            press(.select)
            if app.descendants(matching: .any)["source.0"].waitForExistence(timeout: 15) {
                shot("04-sources", wait: 3)
            }
            press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
        }
        press(.menu)
        Thread.sleep(forTimeInterval: 2)

        // Fiche série (deuxième titre de « Continuer à regarder »).
        press(.right)
        press(.select)
        if app.buttons["detail.play"].waitForExistence(timeout: 15) {
            shot("05-fiche-serie", wait: 5)
            press(.menu)
            Thread.sleep(forTimeInterval: 2)
        }

        // Films : grille et panneau de détails.
        goToTab("Films")
        focusContent()
        press(.down, times: 2)
        shot("06-films", wait: 4)

        // Séries.
        goToTab("Séries")
        focusContent()
        press(.down, times: 2)
        shot("07-series", wait: 4)

        // Ma liste.
        goToTab("Ma liste")
        focusContent()
        shot("08-ma-liste", wait: 4)

        // Réglages, puis lecteur (clip de test embarqué) et panneau des pistes.
        goToTab("Réglages")
        focusContent()
        shot("09-reglages", wait: 2)
        var guardCount = 0
        while !focusedLabel().contains("Tester le lecteur") && guardCount < 6 { press(.up); guardCount += 1 }
        press(.select)
        if app.descendants(matching: .any)["test.h264"].waitForExistence(timeout: 10) {
            guardCount = 0
            while !focusedLabel().contains("H.264") && guardCount < 6 { press(.down); guardCount += 1 }
            press(.select)
            let milestone = app.staticTexts["player.milestone"]
            if milestone.waitForExistence(timeout: 20) {
                let playing = NSPredicate(format: "label CONTAINS[c] 'Lecture'")
                _ = XCTWaiter.wait(for: [expectation(for: playing, evaluatedWith: milestone)], timeout: 40)
                press(.up)
                shot("10-lecteur", wait: 1)
                press(.down)
                shot("11-pistes", wait: 2)
            }
        }
    }
}
