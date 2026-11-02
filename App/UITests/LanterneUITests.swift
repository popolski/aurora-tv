import XCTest

/// Tests d'interface tvOS sur simulateur, avec réseau simulé (`-uitest`).
///
/// Ils vérifient la navigation au focus et le cycle de vie du lecteur. Ils ne
/// prouvent rien sur le rendu vidéo réel : le simulateur n'est pas une Apple TV.
@MainActor
final class LanterneUITests: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { XCUIRemote.shared }

    override nonisolated func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    private var focused: XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func focusedLabel() -> String {
        let element = focused
        return element.exists ? element.label : "<aucun>"
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: 0.35)
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var tabBarHasFocus: Bool {
        app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }

    /// Descend dans le contenu de l'onglet (quitte la barre d'onglets du haut).
    private func focusContent() {
        var n = 0
        while tabBarHasFocus && n < 4 { press(.down); n += 1 }
    }

    /// Sélectionne un onglet de la barre du haut puis entre dans son contenu.
    private func goToTab(_ name: String) {
        var n = 0
        while !tabBarHasFocus && n < 8 { press(.up); n += 1 }
        press(.left, times: 7)
        let target = app.tabBars.buttons[name]
        n = 0
        while !target.hasFocus && n < 8 { press(.right); n += 1 }
        XCTAssertTrue(target.hasFocus, "onglet « \(name) » introuvable")
        Thread.sleep(forTimeInterval: 0.8)
        focusContent()
    }

    func testHomeShowsCatalogAndFocusMoves() {
        launch()
        XCTAssertTrue(app.staticTexts["Populaires"].waitForExistence(timeout: 15), "rangée de catalogue absente")
        focusContent()
        let first = focusedLabel()
        press(.right)
        let second = focusedLabel()
        XCTAssertNotEqual(first, second, "le focus doit se déplacer horizontalement")
        XCTAssertTrue(focused.exists, "un élément doit toujours avoir le focus")
    }

    func testDetailBackRestoresFocus() {
        launch()
        XCTAssertTrue(app.staticTexts["Populaires"].waitForExistence(timeout: 15))
        focusContent()
        press(.right)
        let before = focusedLabel()
        press(.select)
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10), "la fiche doit s'ouvrir")
        press(.menu)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(focusedLabel(), before, "le focus doit revenir sur l'affiche d'origine")
    }

    func testPlayerFailureCanBeClosedAndNavigationContinues() {
        launch()
        XCTAssertTrue(app.staticTexts["Populaires"].waitForExistence(timeout: 15))
        focusContent()
        press(.select)
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        press(.select)  // « Lire » a le focus par défaut
        let source = app.buttons["source.0"]
        XCTAssertTrue(source.waitForExistence(timeout: 15), "la liste des sources doit apparaître")
        press(.select)
        // La source de test pointe vers une adresse injoignable : écran d'erreur attendu.
        let close = app.buttons["Fermer"]
        XCTAssertTrue(close.waitForExistence(timeout: 60), "l'échec doit être affiché, sans blocage")
        while !close.hasFocus && app.buttons["Fermer"].exists {
            press(.right)
            if close.hasFocus { break }
            if focusedLabel() == "Fermer" { break }
        }
        press(.select)
        XCTAssertTrue(source.waitForExistence(timeout: 10), "retour à la liste des sources")
        XCTAssertTrue(focused.exists, "le focus doit être restauré après la fermeture du lecteur")
        press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 10), "retour à la fiche")
    }

    /// Indicatif seulement : le simulateur ne reflète pas le décodage matériel.
    func testLocalTestClipReachesPlayingInSimulator() {
        launch()
        XCTAssertTrue(app.staticTexts["Populaires"].waitForExistence(timeout: 15))
        goToTab("Réglages")
        // Dans une liste tvOS, les lignes peuvent être exposées comme cellules : recherche par identifiant seul.
        let diagnostics = app.descendants(matching: .any)["settings.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        // Le focus est porté par la cellule, pas par l'élément identifié : on suit le texte focalisé.
        var guardCount = 0
        while !focusedLabel().contains("Tester le lecteur") && guardCount < 6 { press(.up); guardCount += 1 }
        XCTAssertTrue(focusedLabel().contains("Tester le lecteur"), "focus inattendu : \(focusedLabel())")
        press(.select)
        let clip = app.descendants(matching: .any)["test.h264"]
        if !clip.waitForExistence(timeout: 10) {
            attachScreenshot("diagnostics-non-ouvert")
            XCTFail("l'écran de test du lecteur ne s'est pas ouvert (focus : \(focusedLabel()))")
            return
        }
        guardCount = 0
        while !focusedLabel().contains("H.264") && guardCount < 6 { press(.down); guardCount += 1 }
        press(.select)
        let milestone = app.staticTexts["player.milestone"]
        XCTAssertTrue(milestone.waitForExistence(timeout: 20))
        let reached = NSPredicate(format: "label CONTAINS[c] 'Lecture'")
        expectation(for: reached, evaluatedWith: milestone)
        waitForExpectations(timeout: 45)
        press(.menu, times: 2)
    }
}
