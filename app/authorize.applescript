use scripting additions

on run argv
    if (count of argv) is not 4 then error "Invalid authorization request."
    set entryPath to item 1 of argv
    set operation to item 2 of argv
    set userID to item 3 of argv
    set toolPath to item 4 of argv
    if toolPath does not end with "/Contents/Resources/lid-hold.command" then error "Invalid helper."
    if operation is "prepare" or operation is "revoke" then
        set resourceLength to (length of toolPath) - (length of "lid-hold.command")
        if entryPath is not ((text 1 thru resourceLength of toolPath) & "authorization.sh") then error "Invalid installer."
        set commandText to "/bin/bash " & quoted form of entryPath & space & quoted form of operation & space & quoted form of userID & space & quoted form of toolPath
    else
        if entryPath is not toolPath then error "Invalid helper."
        if operation is not "stop" then
            set minutes to operation as integer
            if minutes < 1 or minutes > 120 or (minutes as text) is not operation then error "Invalid duration."
        end if
        set commandText to "/bin/bash " & quoted form of toolPath & space & quoted form of operation
    end if
    do shell script commandText with administrator privileges
end run
