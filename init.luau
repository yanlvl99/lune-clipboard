--!strict
--[[
    lune-clipboard: High-performance cross-platform clipboard module
    Uses FFI for Windows (native speed), process.exec for Linux/macOS
]]

local ffi = require("@lune/ffi")
local process = require("@lune/process")
local task = require("@lune/task")

export type ClipboardModule = {
	set: (text: string) -> boolean,
	get: () -> string,
	clear: () -> boolean,
	paste: () -> (),
	copy: (text: string) -> boolean,
	hasText: () -> boolean,
	watch: (callback: (text: string) -> (), intervalMs: number?) -> () -> (),
}

local Clipboard = {} :: ClipboardModule

if process.os == "windows" then
	-- Windows FFI implementation
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
		kernel32:call("Sleep", "void", { "u32" }, ms)
	end

	local function openClipboardWithRetry(maxAttempts: number?): boolean
		local attempts = maxAttempts or 20
		for _ = 1, attempts do
			if user32:call("OpenClipboard", "i32", { "pointer" }, ffi.null) ~= 0 then
				return true
			end
			wait(5)
		end
		return false
	end

	function Clipboard.set(text: string): boolean
		if #text == 0 then
			return Clipboard.clear()
		end

		local sourceBuf = ffi.buffer(#text + 1)
		sourceBuf:writeString(0, text)

		local charsNeeded = kernel32:call(
			"MultiByteToWideChar",
			"i32",
			{ "u32", "u32", "pointer", "i32", "pointer", "i32" },
			CP_UTF8,
			0,
			sourceBuf.ptr,
			-1,
			ffi.null,
			0
		)
		if charsNeeded == 0 then
			return false
		end

		local bytesNeeded = charsNeeded * 2
		local hMem =
			kernel32:call("GlobalAlloc", "pointer", { "u32", "u64" }, GMEM_MOVEABLE + GMEM_ZEROINIT, bytesNeeded)
		if ffi.isNull(hMem) then
			return false
		end

		local pMem = kernel32:call("GlobalLock", "pointer", { "pointer" }, hMem)
		kernel32:call(
			"MultiByteToWideChar",
			"i32",
			{ "u32", "u32", "pointer", "i32", "pointer", "i32" },
			CP_UTF8,
			0,
			sourceBuf.ptr,
			-1,
			pMem,
			charsNeeded
		)
		kernel32:call("GlobalUnlock", "i32", { "pointer" }, hMem)

		if not openClipboardWithRetry() then
			kernel32:call("GlobalFree", "pointer", { "pointer" }, hMem)
			return false
		end

		user32:call("EmptyClipboard", "i32", {})
		local result = user32:call("SetClipboardData", "pointer", { "u32", "pointer" }, CF_UNICODETEXT, hMem)
		user32:call("CloseClipboard", "i32", {})
		return not ffi.isNull(result)
	end

	function Clipboard.get(): string
		if not openClipboardWithRetry() then
			return ""
		end

		local hMem = user32:call("GetClipboardData", "pointer", { "u32" }, CF_UNICODETEXT)
		if ffi.isNull(hMem) then
			user32:call("CloseClipboard", "i32", {})
			return ""
		end

		local pMem = kernel32:call("GlobalLock", "pointer", { "pointer" }, hMem)
		if ffi.isNull(pMem) then
			user32:call("CloseClipboard", "i32", {})
			return ""
		end

		local bytesNeeded = kernel32:call(
			"WideCharToMultiByte",
			"i32",
			{ "u32", "u32", "pointer", "i32", "pointer", "i32", "pointer", "pointer" },
			CP_UTF8,
			0,
			pMem,
			-1,
			ffi.null,
			0,
			ffi.null,
			ffi.null
		)

		if bytesNeeded == 0 then
			kernel32:call("GlobalUnlock", "i32", { "pointer" }, hMem)
			user32:call("CloseClipboard", "i32", {})
			return ""
		end

		local resultBuf = ffi.buffer(bytesNeeded)
		kernel32:call(
			"WideCharToMultiByte",
			"i32",
			{ "u32", "u32", "pointer", "i32", "pointer", "i32", "pointer", "pointer" },
			CP_UTF8,
			0,
			pMem,
			-1,
			resultBuf.ptr,
			bytesNeeded,
			ffi.null,
			ffi.null
		)

		kernel32:call("GlobalUnlock", "i32", { "pointer" }, hMem)
		user32:call("CloseClipboard", "i32", {})
		return resultBuf:readString(0)
	end

	function Clipboard.clear(): boolean
		if not openClipboardWithRetry() then
			return false
		end
		user32:call("EmptyClipboard", "i32", {})
		user32:call("CloseClipboard", "i32", {})
		return true
	end

	function Clipboard.paste()
		user32:call("keybd_event", "void", { "i32", "i32", "i32", "u64" }, VK_CONTROL, 0, 0, 0)
		user32:call("keybd_event", "void", { "i32", "i32", "i32", "u64" }, VK_V, 0, 0, 0)
		wait(10)
		user32:call("keybd_event", "void", { "i32", "i32", "i32", "u64" }, VK_V, 0, KEYEVENTF_KEYUP, 0)
		user32:call("keybd_event", "void", { "i32", "i32", "i32", "u64" }, VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)
	end
elseif process.os == "linux" then
	function Clipboard.set(text: string): boolean
		local escaped = text:gsub("'", "'\\''")
		local result = process.exec("sh", { "-c", `printf '%s' '{escaped}' | xclip -selection clipboard` })
		return result.ok
	end

	function Clipboard.get(): string
		local result = process.exec("xclip", { "-selection", "clipboard", "-out" })
		return result.ok and result.stdout or ""
	end

	function Clipboard.clear(): boolean
		return Clipboard.set("")
	end

	function Clipboard.paste()
		process.exec("xdotool", { "key", "ctrl+v" })
	end
elseif process.os == "macos" then
	function Clipboard.set(text: string): boolean
		local escaped = text:gsub("'", "'\\''")
		local result = process.exec("sh", { "-c", `printf '%s' '{escaped}' | pbcopy` })
		return result.ok
	end

	function Clipboard.get(): string
		local result = process.exec("pbpaste", {})
		return result.ok and result.stdout or ""
	end

	function Clipboard.clear(): boolean
		return Clipboard.set("")
	end

	function Clipboard.paste()
		process.exec("osascript", { "-e", 'tell application "System Events" to keystroke "v" using command down' })
	end
end

-- Common functions
function Clipboard.copy(text: string): boolean
	return Clipboard.set(text)
end

function Clipboard.hasText(): boolean
	return #Clipboard.get() > 0
end

function Clipboard.watch(callback: (text: string) -> (), intervalMs: number?): () -> ()
	local running = true
	local lastContent = Clipboard.get()
	local interval = (intervalMs or 500) / 1000

	task.spawn(function()
		while running do
			task.wait(interval)
			local current = Clipboard.get()
			if current ~= lastContent then
				lastContent = current
				callback(current)
			end
		end
	end)

	return function()
		running = false
	end
end

return Clipboard
