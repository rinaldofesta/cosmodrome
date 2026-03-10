-- read-content.scpt
-- Attempts to read terminal content from Ghostty using Accessibility API.
-- Note: This is limited — terminal emulators typically don't expose text
-- through the accessibility tree in a useful way. This script demonstrates
-- what IS accessible.
-- Usage: osascript read-content.scpt
-- Requires: Accessibility permissions for Terminal/osascript

tell application "System Events"
    if not (exists process "ghostty") then
        log "Ghostty is not running"
        return
    end if

    tell process "ghostty"
        set frontWindow to window 1

        -- Try to get the AXValue (text content) from UI elements
        set allElements to every UI element of frontWindow
        log "UI elements in window: " & (count of allElements)

        repeat with elem in allElements
            try
                set elemRole to role of elem
                set elemDesc to description of elem
                log "  Role: " & elemRole & " — " & elemDesc
            on error
                log "  (element with no role/description)"
            end try

            -- Try to read value from text areas
            try
                set elemValue to value of elem
                if elemValue is not missing value and elemValue is not "" then
                    log "  Value: " & elemValue
                end if
            end try
        end repeat
    end tell
end tell
