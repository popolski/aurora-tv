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

    func testHomeShowsCatalogAndFocusMoves() {
        launch()
        XCTAssertTrue(app.staticTexts["Populaires"].waitForExistence(timeout: 15), "rangée de catalogue absente")
        press(.down, times: 2)
        let first = focusedLabel()
        press(.right)
        let second = focusedLabel()
        XCTAssertNotEqual(first, second, "le focus doit se déplacer horizontalement")
        XCTAssertTrue(focused.exists, "un élément doit toujours avoir le focus")
    }

    func testDetailBackRestoresFocus() {
        launch()
        XCTAssertTrue(app.staticTexts["Populaires"].waitForExistence(timeout: 15))
        press(.down, times: 2)
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
        // Menu latéral : on passe d'abord dans le contenu.
        press(.right)
        press(.down, times: 2)
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
        // Menu latéral : gauche pour l'ouvrir, Réglages est la 5e entrée, puis le contenu.
        press(.left, times: 2)
        press(.down, times: 4)
        press(.select)
        press(.right)
        let diagnostics = app.buttons["settings.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        var guardCount = 0
        while !diagnostics.hasFocus && guardCount < 12 { press(.down); guardCount += 1 }
        press(.select)
        let clip = app.buttons["test.h264"]
        XCTAssertTrue(clip.waitForExistence(timeout: 10))
        guardCount = 0
        while !clip.hasFocus && guardCount < 6 { press(.down); guardCount += 1 }
        press(.select)
        let milestone = app.staticTexts["player.milestone"]
        XCTAssertTrue(milestone.waitForExistence(timeout: 20))
        let reached = NSPredicate(format: "label CONTAINS[c] 'Lecture'")
        expectation(for: reached, evaluatedWith: milestone)
        waitForExpectations(timeout: 45)
        press(.menu, times: 2)
    }
}
