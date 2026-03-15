import XCTest
@testable import Core

final class ThemeTests: XCTestCase {
    let parser = ConfigParser()

    func testDefaultDarkTheme() {
        let theme = Theme.dark
        XCTAssertEqual(theme.name, "Dark")
        XCTAssertEqual(theme.colors.foreground, "#D9D9D9")
        XCTAssertEqual(theme.colors.background, "#1A1A1C")
        XCTAssertEqual(theme.colors.ansiArray.count, 16)
    }

    func testDefaultLightTheme() {
        let theme = Theme.light
        XCTAssertEqual(theme.name, "Light")
        XCTAssertEqual(theme.colors.foreground, "#1A1A1F")
        XCTAssertEqual(theme.colors.background, "#F5F5F5")
    }

    func testParseHexColor() {
        let color = parseHexColor("#FF8040")
        XCTAssertNotNil(color)
        XCTAssertEqual(color!.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(color!.g, 0.502, accuracy: 0.01)
        XCTAssertEqual(color!.b, 0.251, accuracy: 0.01)
    }

    func testParseHexColorNoHash() {
        let color = parseHexColor("00FF00")
        XCTAssertNotNil(color)
        XCTAssertEqual(color!.r, 0.0, accuracy: 0.01)
        XCTAssertEqual(color!.g, 1.0, accuracy: 0.01)
        XCTAssertEqual(color!.b, 0.0, accuracy: 0.01)
    }

    func testParseHexColorInvalid() {
        XCTAssertNil(parseHexColor("xyz"))
        XCTAssertNil(parseHexColor("#GG0000"))
        XCTAssertNil(parseHexColor("#FF"))
    }

    func testParseThemeYaml() throws {
        let yaml = """
        name: "Custom"
        colors:
          foreground: "#FFFFFF"
          background: "#000000"
          cursor: "#FFFFFF"
          selection: "#333333"
          black: "#000000"
          red: "#FF0000"
          green: "#00FF00"
          yellow: "#FFFF00"
          blue: "#0000FF"
          magenta: "#FF00FF"
          cyan: "#00FFFF"
          white: "#FFFFFF"
          bright_black: "#808080"
          bright_red: "#FF8080"
          bright_green: "#80FF80"
          bright_yellow: "#FFFF80"
          bright_blue: "#8080FF"
          bright_magenta: "#FF80FF"
          bright_cyan: "#80FFFF"
          bright_white: "#FFFFFF"
        """
        let theme = try parser.parseTheme(yaml: yaml)
        XCTAssertEqual(theme.name, "Custom")
        XCTAssertEqual(theme.colors.foreground, "#FFFFFF")
        XCTAssertEqual(theme.colors.background, "#000000")
        XCTAssertEqual(theme.colors.red, "#FF0000")
        XCTAssertEqual(theme.colors.brightCyan, "#80FFFF")
    }

    func testAnsiArray() {
        let theme = Theme.dark
        let ansi = theme.colors.ansiArray
        XCTAssertEqual(ansi.count, 16)
        XCTAssertEqual(ansi[0], theme.colors.black)
        XCTAssertEqual(ansi[1], theme.colors.red)
        XCTAssertEqual(ansi[8], theme.colors.brightBlack)
        XCTAssertEqual(ansi[15], theme.colors.brightWhite)
    }
}
