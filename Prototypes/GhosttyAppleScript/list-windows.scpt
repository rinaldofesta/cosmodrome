-- list-windows.scpt
-- Lists all Ghostty windows and their properties.
-- Usage: osascript list-windows.scpt

tell application "System Events"
    if not (exists process "ghostty") then
        log "Ghostty is not running"
        return
    end if

    tell process "ghostty"
        set windowCount to count of windows
        log "Found " & windowCount & " Ghostty window(s)"

        repeat with i from 1 to windowCount
            set w to window i
            set windowTitle to name of w
            set windowPos to position of w
            set windowSize to size of w
            log "Window " & i & ": " & windowTitle
            log "  Position: " & (item 1 of windowPos) & ", " & (item 2 of windowPos)
            log "  Size: " & (item 1 of windowSize) & " x " & (item 2 of windowSize)
        end repeat
    end tell
end tell
