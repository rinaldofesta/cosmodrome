-- send-keys.scpt
-- Sends keystrokes to the frontmost Ghostty window.
-- Usage: osascript send-keys.scpt "echo hello"

on run argv
    if (count of argv) < 1 then
        log "Usage: osascript send-keys.scpt \"command to type\""
        return
    end if

    set inputText to item 1 of argv

    tell application "System Events"
        if not (exists process "ghostty") then
            log "Ghostty is not running"
            return
        end if

        -- Bring Ghostty to front
        tell process "ghostty"
            set frontmost to true
        end tell

        delay 0.2

        -- Type the text character by character
        keystroke inputText

        -- Press Enter
        key code 36
    end tell
end run
