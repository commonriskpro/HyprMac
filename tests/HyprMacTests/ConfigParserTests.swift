import XCTest
import CoreGraphics
@testable import HyprMac

final class ConfigParserTests: XCTestCase {

    func testDefaultConfig() {
        let config = HyprConfig.default
        XCTAssertEqual(config.gapsIn, 5.0)
        XCTAssertEqual(config.gapsOut, 10.0)
        XCTAssertEqual(config.borderSize, 2)
        XCTAssertEqual(config.activeBorderGradient, [0x33CCFFEE, 0x00FF99EE])
        XCTAssertEqual(config.inactiveBorderColor, 0x595959AA)
        XCTAssertEqual(config.rounding, 10.0)
        XCTAssertEqual(config.borderMode, .neon)
        XCTAssertEqual(config.haloPadding, 12.0)
        XCTAssertEqual(config.windowOpacity, 0.96)
        XCTAssertEqual(config.inactiveOpacity, 0.98)
        XCTAssertFalse(config.stripDecorations)
        XCTAssertEqual(config.layout, "dwindle")
        XCTAssertTrue(config.bindings.isEmpty)
        XCTAssertTrue(config.variables.isEmpty)
    }

    func testParseEmptyString() {
        let config = ConfigParser.parse(text: "")
        XCTAssertEqual(config.gapsIn, 5.0)
        XCTAssertEqual(config.gapsOut, 10.0)
        XCTAssertEqual(config.borderSize, 2)
        XCTAssertEqual(config.rounding, 10.0)
        XCTAssertEqual(config.borderMode, .neon)
        XCTAssertTrue(config.bindings.isEmpty)
    }

    func testParseGaps() {
        let input = """
        general {
            gaps_in = 8
            gaps_out = 15
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.gapsIn, 8.0)
        XCTAssertEqual(config.gapsOut, 15.0)
    }

    func testParseBorderSize() {
        let input = """
        general {
            border_size = 3
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.borderSize, 3)
    }

    func testParseBorderColors() {
        let input = """
        general {
            col.active_border = rgba(33ccffee) rgba(00ff99ee)
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.activeBorderGradient, [0x33CCFFEE, 0x00FF99EE])
    }

    func testParseInactiveBorderColor() {
        let input = """
        general {
            col.inactive_border = rgba(595959aa)
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.inactiveBorderColor, 0x595959AA)
    }

    func testParseRounding() {
        let input = """
        decoration {
            rounding = 0
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.rounding, 0.0)
    }

    func testParseBindings() {
        let input = """
        bind = SUPER, Q, killactive,
        bind = SUPER, Return, exec, kitty
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.bindings.count, 2)

        let first = config.bindings[0]
        XCTAssertEqual(first.mod, "SUPER")
        XCTAssertEqual(first.key, "Q")
        XCTAssertEqual(first.dispatcher, "killactive")
        XCTAssertEqual(first.args, "")

        let second = config.bindings[1]
        XCTAssertEqual(second.mod, "SUPER")
        XCTAssertEqual(second.key, "Return")
        XCTAssertEqual(second.dispatcher, "exec")
        XCTAssertEqual(second.args, "kitty")
    }

    func testBindingModifierTokens() {
        let binding = HyprBinding(
            mod: "SUPER SHIFT",
            key: "Q",
            dispatcher: "killactive"
        )
        XCTAssertEqual(binding.modifierTokens, ["SUPER", "SHIFT"])
        XCTAssertTrue(binding.hasSuper)
        XCTAssertTrue(binding.hasShift)
        XCTAssertFalse(binding.hasControl)
        XCTAssertFalse(binding.hasAlt)
    }

    func testParseVariables() {
        let input = """
        $terminal = kitty
        $mainMod = SUPER
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.variable("terminal"), "kitty")
        XCTAssertEqual(config.variable("$terminal"), "kitty")
        XCTAssertEqual(config.variable("mainMod"), "SUPER")
    }

    func testParseComments() {
        let input = """
        # This is a full comment line
        general {
            # Indented comment
            gaps_in = 12 # Trailing comment
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.gapsIn, 12.0)
    }

    func testParseMalformed() {
        let input = """
        this is not valid hyprland config
        = = =
        general {
            gaps_in = not_a_number
            border_size = 5
        }}}}}{{{
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.gapsIn, 5.0)
        XCTAssertEqual(config.borderSize, 5)
    }

    func testConfigVariableLookup() {
        let input = "$terminal = kitty"
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.variable("terminal"), "kitty")
        XCTAssertEqual(config.variable("$terminal"), "kitty")
        XCTAssertNil(config.variable("nonexistent"))
    }

    func testConfigSettingLookup() {
        let input = """
        general {
            gaps_in = 8
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.setting(for: "gaps_in", section: "general"), "8")
        XCTAssertEqual(config.setting(for: "general.gaps_in"), "8")
        XCTAssertNil(config.setting(for: "unknown_key", section: "general"))
    }

    func testParseLayout() {
        let input1 = """
        general {
            layout = dwindle
        }
        """
        let config1 = ConfigParser.parse(text: input1)
        XCTAssertEqual(config1.layout, "dwindle")

        let input2 = """
        general {
            layout = master
        }
        """
        let config2 = ConfigParser.parse(text: input2)
        XCTAssertEqual(config2.layout, "master")
    }

    func testBorderModeEnum() {
        XCTAssertEqual(BorderMode.glassHalo.rawValue, "glass_halo")
        XCTAssertEqual(BorderMode.neon.rawValue, "neon")
        XCTAssertEqual(BorderMode.outline.rawValue, "outline")
        XCTAssertEqual(BorderMode.allCases.count, 3)
    }

    func testBindingEquality() {
        let b1 = HyprBinding(flags: "", mod: "SUPER", key: "Q", dispatcher: "killactive", args: "")
        let b2 = HyprBinding(flags: "", mod: "SUPER", key: "Q", dispatcher: "killactive", args: "")
        let b3 = HyprBinding(flags: "", mod: "SUPER", key: "C", dispatcher: "killactive", args: "")
        XCTAssertEqual(b1, b2)
        XCTAssertNotEqual(b1, b3)
    }

    func testBindingDescription() {
        let b1 = HyprBinding(mod: "SUPER", key: "Q", dispatcher: "killactive")
        XCTAssertFalse(b1.description.isEmpty)
        XCTAssertEqual(b1.description, "bind = SUPER, Q, killactive")

        let b2 = HyprBinding(mod: "SUPER", key: "Return", dispatcher: "exec", args: "kitty")
        XCTAssertEqual(b2.description, "bind = SUPER, Return, exec, kitty")

        let b3 = HyprBinding(flags: "m", mod: "SUPER", key: "mouse:272", dispatcher: "movewindow", args: "")
        XCTAssertEqual(b3.description, "bindm = SUPER, mouse:272, movewindow")
    }

    func testConfigParserSelfTest() {
        XCTAssertTrue(ConfigParser.runSelfTest())
    }

    func testParseBlurConfiguration() {
        let input = """
        decoration {
            active_opacity = 0.88
            inactive_opacity = 0.70
            blur {
                enabled = true
                size = 5
                passes = 3
            }
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowOpacity, 0.88)
        XCTAssertEqual(config.inactiveOpacity, 0.70)
        XCTAssertTrue(config.blurEnabled)
        XCTAssertEqual(config.blurRadius, 15)
    }
    func testParseInactiveOpacity() {
        let input = """
        decoration {
            active_opacity = 0.99
            inactive_opacity = 0.98
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.windowOpacity, 0.99)
        XCTAssertEqual(config.inactiveOpacity, 0.98)
    }

    func testParseDeclarativeBarColors() {
        let input = """
        $color4 = rgba(E4A136ee)
        $color5 = rgba(8C9071ee)
        bar {
            col.window_title = $color4
            col.workspaces_inactive = $color5
            col.workspaces_active_bg = primary
            col.workspaces_active_fg = "#131514"
            col.battery = secondary
            col.clock = secondary
            col.volume = tertiary
            col.network = primary
            col.cpu = secondary
            col.memory = secondary
            col.notification = primary
            col.power = error
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.barColors.windowTitle, "rgba(E4A136ee)")
        XCTAssertEqual(config.barColors.workspacesInactive, "rgba(8C9071ee)")
        XCTAssertEqual(config.barColors.workspacesActiveBg, "primary")
        XCTAssertEqual(config.barColors.workspacesActiveFg, "#131514")
        XCTAssertEqual(config.barColors.battery, "secondary")
        XCTAssertEqual(config.barColors.clock, "secondary")
        XCTAssertEqual(config.barColors.volume, "tertiary")
        XCTAssertEqual(config.barColors.network, "primary")
        XCTAssertEqual(config.barColors.cpu, "secondary")
        XCTAssertEqual(config.barColors.memory, "secondary")
        XCTAssertEqual(config.barColors.notification, "primary")
        XCTAssertEqual(config.barColors.power, "error")
    }

    func testParseBarOpacity() {
        let input = """
        bar {
            opacity = 0.65
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.barOpacity, 0.65, accuracy: 0.001)
    }

    func testParseBarClockFormat12h() {
        let input = """
        bar {
            clock_format = 12h
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.clockFormat, "h:mm a  EEE")
    }

    func testParseBarClockFormat24h() {
        let input = """
        bar {
            clock_format = 24h
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.clockFormat, "HH:mm  EEE")
    }

    func testParseBarClockFormatCustomStrftime() {
        let input = """
        bar {
            clock_format = "{:%I:%M %p  %a}"
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.clockFormat, "hh:mm a  EEE")
    }

    func testParseBarTime12hBoolean() {
        let input = """
        bar {
            time_12h = true
        }
        """
        let config = ConfigParser.parse(text: input)
        XCTAssertEqual(config.clockFormat, "h:mm a  EEE")
    }

}
