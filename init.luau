--!strict
local ffi = require("@lune/ffi")
local process = require("@lune/process")
local task = require("@lune/task")

type ClipboardModule = {
    set: (text: string) -> boolean,
    get: () -> string,
    clear: () -> boolean,
    paste: () -> ()
}

local os_str = process.os
local Clipboard: ClipboardModule = {} :: ClipboardModule

if os_str == "windows" then
    local user32 = ffi.open("user32.dll")
    local kernel32 = ffi.open("kernel32.dll")
    
    local CF_UNICODETEXT = 13
    local GMEM_MOVEABLE = 0x0002
    local GMEM_ZEROINIT = 0x0040
    local CP_UTF8 = 65001
    local KEYEVENTF_KEYUP = 0x0002
    local VK_CONTROL = 0x11
    local VK_V = 0x56

    local function wait(ms: number)
        kernel32:call("Sleep", "void", {"u32"}, ms)
    end

    function Clipboard.set(text: string): boolean
        local sourceBuf = ffi.buffer(#text + 1)
        sourceBuf:writeString(0, text)

        local charsNeeded = kernel32:call("MultiByteToWideChar", "i32", {"u32", "u32", "pointer", "i32", "pointer", "i32"}, CP_UTF8, 0, sourceBuf.ptr, -1, ffi.null, 0)
        local bytesNeeded = charsNeeded * 2
        
        local hMem = kernel32:call("GlobalAlloc", "pointer", {"u32", "u64"}, GMEM_MOVEABLE + GMEM_ZEROINIT, bytesNeeded)
        if ffi.isNull(hMem) then return false end

        local pMem = kernel32:call("GlobalLock", "pointer", {"pointer"}, hMem)
        kernel32:call("MultiByteToWideChar", "i32", {"u32", "u32", "pointer", "i32", "pointer", "i32"}, CP_UTF8, 0, sourceBuf.ptr, -1, pMem, charsNeeded)
        kernel32:call("GlobalUnlock", "i32", {"pointer"}, hMem)

        local attempts = 0
        while user32:call("OpenClipboard", "i32", {"pointer"}, ffi.null) == 0 do
            if attempts > 20 then return false end
            wait(10)
            attempts += 1
        end

        user32:call("EmptyClipboard", "i32", {})
        user32:call("SetClipboardData", "pointer", {"u32", "pointer"}, CF_UNICODETEXT, hMem)
        user32:call("CloseClipboard", "i32", {})
        return true
    end

    function Clipboard.get(): string
        local attempts = 0
        while user32:call("OpenClipboard", "i32", {"pointer"}, ffi.null) == 0 do
            if attempts > 20 then return "" end
            wait(10)
            attempts += 1
        end

        local hMem = user32:call("GetClipboardData", "pointer", {"u32"}, CF_UNICODETEXT)
        if ffi.isNull(hMem) then
            user32:call("CloseClipboard", "i32", {})
            return ""
        end

        local pMem = kernel32:call("GlobalLock", "pointer", {"pointer"}, hMem)
        
        local bytesNeeded = kernel32:call("WideCharToMultiByte", "i32", {"u32", "u32", "pointer", "i32", "pointer", "i32", "pointer", "pointer"}, CP_UTF8, 0, pMem, -1, ffi.null, 0, ffi.null, ffi.null)
        local resultBuf = ffi.buffer(bytesNeeded)
        
        kernel32:call("WideCharToMultiByte", "i32", {"u32", "u32", "pointer", "i32", "pointer", "i32", "pointer", "pointer"}, CP_UTF8, 0, pMem, -1, resultBuf.ptr, bytesNeeded, ffi.null, ffi.null)
        
        kernel32:call("GlobalUnlock", "i32", {"pointer"}, hMem)
        user32:call("CloseClipboard", "i32", {})
        
        return resultBuf:readString(0)
    end

    function Clipboard.clear(): boolean
        if user32:call("OpenClipboard", "i32", {"pointer"}, ffi.null) == 0 then return false end
        user32:call("EmptyClipboard", "i32", {})
        user32:call("CloseClipboard", "i32", {})
        return true
    end

    function Clipboard.paste()
        user32:call("keybd_event", "void", {"i32", "i32", "i32", "u64"}, VK_CONTROL, 0, 0, 0)
        user32:call("keybd_event", "void", {"i32", "i32", "i32", "u64"}, VK_V, 0, 0, 0)
        wait(10)
        user32:call("keybd_event", "void", {"i32", "i32", "i32", "u64"}, VK_V, 0, KEYEVENTF_KEYUP, 0)
        user32:call("keybd_event", "void", {"i32", "i32", "i32", "u64"}, VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)
    end

elseif os_str == "linux" then
    function Clipboard.set(text: string): boolean
        local result = process.spawn("xclip", {"-selection", "clipboard", "-in"}, { stdio = "piped", input = text })
        return result.ok
    end

    function Clipboard.get(): string
        local result = process.spawn("xclip", {"-selection", "clipboard", "-out"})
        return result.stdout
    end

    function Clipboard.clear(): boolean
        return Clipboard.set("")
    end

    function Clipboard.paste()
        process.spawn("xdotool", {"key", "ctrl+v"})
    end

elseif os_str == "macos" then
    function Clipboard.set(text: string): boolean
        local result = process.spawn("pbcopy", {}, { stdio = "piped", input = text })
        return result.ok
    end

    function Clipboard.get(): string
        local result = process.spawn("pbpaste", {})
        return result.stdout
    end

    function Clipboard.clear(): boolean
        return Clipboard.set("")
    end

    function Clipboard.paste()
        process.spawn("osascript", {"-e", 'tell application "System Events" to keystroke "v" using command down'})
    end
end

return Clipboard
