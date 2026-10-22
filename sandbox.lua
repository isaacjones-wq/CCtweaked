-- CC: Tweaked sandbox helper
-- Usage:
--   sandbox /files/suspicious.lua
--   sandbox /files
--
-- This does not auto-execute the imported file. It simply mounts a virtual filesystem
-- rooted at /, then returns control to the shell.
--
-- If you want to run an imported file in the sandbox, use:
--   sandbox.run("/suspicious.lua")
--

local realFs = fs
local realShell = shell
local realTerm = term
local realOs = os
local realPeripheral = peripheral

local sandbox = {
    fs = nil,
    state = nil,
}

local function normalizePath(path)
    if type(path) ~= "string" then
        return "/"
    end

    path = path:gsub("\\", "/")
    path = path:gsub("/+", "/")

    if path == "" then
        return "/"
    end

    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == "." then
            -- ignore
        elseif part == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        else
            table.insert(parts, part)
        end
    end

    if #parts == 0 then
        return "/"
    end

    return "/" .. table.concat(parts, "/")
end

local function ensureDir(state, dir)
    dir = normalizePath(dir)
    if dir == "/" then
        state.directories["/"] = true
        return true
    end

    local parts = {}
    for part in dir:gmatch("[^/]+") do
        table.insert(parts, part)
    end

    local current = "/"
    for _, part in ipairs(parts) do
        current = current .. part
        state.directories[current] = true
        current = current .. "/"
    end

    return true
end

local function getFileData(path)
    local handle = realFs.open(path, "r")
    if not handle then
        return nil
    end

    local data = handle.readAll()
    handle.close()
    return data
end

local function listRealDir(path)
    local ok, result = pcall(realFs.list, path)
    if not ok then
        return {}
    end
    return result
end

local function buildVirtualFS()
    local state = {
        files = {},
        directories = {
            ["/"] = true,
        },
    }

    local function isAllowedVirtualPath(path)
        local safe = normalizePath(path)
        return safe == "/" or safe:sub(1, 1) == "/"
    end

    local function handleFor(path, mode)
        local file = {
            path = normalizePath(path),
            mode = mode or "r",
            closed = false,
            pos = 1,
        }

        function file.read(self, n)
            if self.closed then
                return nil
            end

            local content = state.files[self.path]
            if content == nil then
                return nil
            end

            if self.pos > #content then
                return nil
            end

            local count = n or 1
            local chunk = content:sub(self.pos, self.pos + count - 1)
            self.pos = self.pos + #chunk
            return chunk
        end

        function file.readAll(self)
            if self.closed then
                return nil
            end

            local content = state.files[self.path]
            self.closed = true
            return content or ""
        end

        function file.readLine(self)
            if self.closed then
                return nil
            end

            local content = state.files[self.path]
            if content == nil then
                return nil
            end

            if self.pos > #content then
                return nil
            end

            local start = self.pos
            local finish = content:find("\n", start, true)
            if not finish then
                finish = #content + 1
            end

            local line = content:sub(start, finish - 1)
            self.pos = finish + 1
            return line
        end

        function file.write(self, text)
            if self.closed then
                error("Attempt to write to closed file", 2)
            end

            if self.mode == "r" or self.mode == "rb" then
                error("Attempt to write to read-only file", 2)
            end

            local value = tostring(text)
            if not state.files[self.path] then
                state.files[self.path] = ""
            end

            if self.mode == "a" or self.mode == "ab" then
                state.files[self.path] = state.files[self.path] .. value
            else
                state.files[self.path] = value
            end
        end

        function file.close(self)
            self.closed = true
        end

        return file
    end

    local fsProxy = {}

    fsProxy.combine = function(base, localPath)
        local b = normalizePath(base or "/")
        local p = tostring(localPath or "")
        if p == "" then
            return b
        end

        if p:sub(1, 1) == "/" then
            return normalizePath(p)
        end

        if b == "/" then
            return normalizePath("/" .. p)
        end

        return normalizePath(b .. "/" .. p)
    end

    fsProxy.exists = function(path)
        local safe = normalizePath(path)
        if safe == "/" then
            return true
        end
        return state.files[safe] ~= nil or state.directories[safe] == true
    end

    fsProxy.isDir = function(path)
        local safe = normalizePath(path)
        return state.directories[safe] == true
    end

    fsProxy.list = function(path)
        local safe = normalizePath(path or "/")
        if safe == "/" then
            local out = {}
            local seen = {}
            for key in pairs(state.directories) do
                if key ~= "/" then
                    local name = key:match("^/([^/]+)$")
                    if name and not seen[name] then
                        seen[name] = true
                        table.insert(out, name)
                    end
                end
            end
            for key in pairs(state.files) do
                local name = key:match("^/([^/]+)$")
                if name and not seen[name] then
                    seen[name] = true
                    table.insert(out, name)
                end
            end
            table.sort(out)
            return out
        end

        if not state.directories[safe] then
            return {}
        end

        local prefix = safe .. "/"
        local out = {}
        local seen = {}

        for key in pairs(state.directories) do
            if key ~= safe and key:sub(1, #prefix) == prefix then
                local rest = key:sub(#prefix + 1)
                local name = rest:match("^([^/]+)")
                if name and not seen[name] then
                    seen[name] = true
                    table.insert(out, name)
                end
            end
        end

        for key in pairs(state.files) do
            if key:sub(1, #prefix) == prefix then
                local rest = key:sub(#prefix + 1)
                local name = rest:match("^([^/]+)")
                if name and not seen[name] then
                    seen[name] = true
                    table.insert(out, name)
                end
            end
        end

        table.sort(out)
        return out
    end

    fsProxy.open = function(path, mode)
        local safe = normalizePath(path)
        if not isAllowedVirtualPath(safe) then
            return nil
        end

        mode = mode or "r"
        if mode == "r" or mode == "rb" then
            if state.files[safe] == nil then
                return nil
            end
            return handleFor(safe, mode)
        end

        local dir = safe:match("^(.*)/[^/]+$") or "/"
        ensureDir(state, dir)
        if state.files[safe] == nil and (mode == "w" or mode == "wb") then
            state.files[safe] = ""
        end

        if mode == "a" or mode == "ab" then
            if state.files[safe] == nil then
                state.files[safe] = ""
            end
            local handle = handleFor(safe, mode)
            handle.pos = #state.files[safe] + 1
            return handle
        end

        if mode == "w" or mode == "wb" then
            state.files[safe] = ""
            return handleFor(safe, mode)
        end

        return nil
    end

    fsProxy.getName = function(path)
        local safe = normalizePath(path)
        local name = safe:match("([^/]+)$")
        return name or ""
    end

    fsProxy.getDir = function(path)
        local safe = normalizePath(path)
        local dir = safe:match("^(.*)/[^/]+$")
        if dir and dir ~= "" then
            return dir
        end
        return "/"
    end

    fsProxy.makeDir = function(path)
        local safe = normalizePath(path)
        if safe == "/" then
            return true
        end
        ensureDir(state, safe)
        state.directories[safe] = true
        return true
    end

    fsProxy.delete = function(path)
        local safe = normalizePath(path)
        if state.files[safe] ~= nil then
            state.files[safe] = nil
            return true
        end

        if state.directories[safe] and safe ~= "/" then
            state.directories[safe] = nil
            return true
        end

        return false
    end

    fsProxy.move = function(fromPath, toPath)
        local src = normalizePath(fromPath)
        local dst = normalizePath(toPath)
        if state.files[src] ~= nil then
            state.files[dst] = state.files[src]
            state.files[src] = nil
            return true
        end

        if state.directories[src] then
            state.directories[dst] = true
            state.directories[src] = nil
            return true
        end

        return false
    end

    fsProxy.copy = function(fromPath, toPath)
        local src = normalizePath(fromPath)
        local dst = normalizePath(toPath)
        if state.files[src] ~= nil then
            state.files[dst] = state.files[src]
            return true
        end
        return false
    end

    fsProxy.attributes = function(path)
        local safe = normalizePath(path)
        if state.directories[safe] then
            return {
                isDir = true,
                size = 0,
                name = fsProxy.getName(safe),
            }
        end

        if state.files[safe] ~= nil then
            return {
                isDir = false,
                size = #state.files[safe],
                name = fsProxy.getName(safe),
            }
        end

        return nil
    end

    fsProxy.find = function(path, pattern)
        local dir = normalizePath(path or "/")
        local out = {}
        local prefix = dir == "/" and "/" or (dir .. "/")
        local matcher = pattern or "*"

        for key in pairs(state.files) do
            local relative = key
            if relative:sub(1, #prefix) == prefix then
                relative = relative:sub(#prefix + 1)
                if matcher == "*" or relative:match(matcher) then
                    table.insert(out, key)
                end
            end
        end

        return out
    end

    fsProxy.complete = function(path, location)
        local prefix = normalizePath(path or "/")
        local dir = normalizePath(location or "/")
        local out = {}

        for key in pairs(state.files) do
            if key:sub(1, #dir) == dir then
                local name = key:sub(#dir + 1)
                if name:sub(1, #prefix) == prefix then
                    table.insert(out, name)
                end
            end
        end

        return out
    end

    return fsProxy, state
end

local function importIntoVirtualFS(state, realPath, virtualPath)
    local source = normalizePath(realPath)
    local target = normalizePath(virtualPath or source)

    if realFs.isDir(source) then
        local entries = listRealDir(source)
        ensureDir(state, target)
        state.directories[target] = true

        for _, entry in ipairs(entries) do
            local childSource = realFs.combine(source, entry)
            local childTarget = realFs.combine(target, entry)
            importIntoVirtualFS(state, childSource, childTarget)
        end
        return target
    end

    local handle = realFs.open(source, "r")
    if not handle then
        error("Could not read: " .. source, 0)
    end

    local content = handle.readAll()
    handle.close()

    local dir = target:match("^(.*)/[^/]+$") or "/"
    ensureDir(state, dir)
    state.files[target] = content
    return target
end

local function makeSandboxEnvironment(vfs)
    local env = {}

    local envMeta = {
        __index = function(_, key)
            if key == "_G" then
                return env
            end

            return _G[key]
        end,

        __newindex = function(_, key, value)
            rawset(env, key, value)
        end,
    }

    setmetatable(env, envMeta)

    env._G = env
    env.fs = vfs
    env.shell = {
        run = function() return false end,
        getRunningProgram = function() return "/" end,
        dir = function() return "/" end,
        setDir = function() return false end,
        complete = function() return {} end,
        openTab = function() end,
        switchTab = function() end,
        setTitle = function() end,
    }

    env.peripheral = {
        isPresent = function() return false end,
        getNames = function() return {} end,
        getType = function() return nil end,
        getMethods = function() return {} end,
        wrap = function() return nil end,
        unwrap = function() return nil end,
        call = function() return nil end,
        hasType = function() return false end,
        find = function() return {} end,
    }

    env.redstone = {
        getInput = function() return 0 end,
        getOutput = function() return 0 end,
        setOutput = function() return false end,
        getBundledInput = function() return 0 end,
        getBundledOutput = function() return 0 end,
        setBundledOutput = function() return false end,
        getSides = function() return {} end,
    }
    env.rs = env.redstone

    env.gps = {
        locate = function() return nil end,
        locate2 = function() return nil end,
        track = function() return nil end,
    }

    env.http = {
        request = function() return nil end,
        checkURL = function() return false end,
        get = function() return nil end,
        post = function() return nil end,
    }

    env.os = {
        clock = os.clock,
        date = os.date,
        time = os.time,
        difftime = os.difftime,
        sleep = function() end,
        queueEvent = function() end,
        pullEvent = function() return "timer", 0 end,
        pullEventRaw = function() return "timer", 0 end,
        shutdown = function() end,
        reboot = function() end,
    }

    env.term = {
        write = function() end,
        clear = function() end,
        blit = function() end,
        setTextColor = function() end,
        setBackgroundColor = function() end,
        setCursorPos = function() end,
        getCursorPos = function() return 1, 1 end,
        getSize = function() return 51, 19 end,
        scroll = function() end,
        isColour = function() return true end,
        redirect = function() end,
        restore = function() end,
        native = function() end,
        setPaletteColour = function() end,
        getPaletteColour = function() return 0 end,
    }

    env.load = nil
    env.loadfile = nil
    env.dofile = nil
    env.require = nil
    env.print = print
    env.assert = assert
    env.error = error
    env.type = type
    env.pairs = pairs
    env.ipairs = ipairs
    env.next = next
    env.select = select
    env.unpack = unpack
    env.tonumber = tonumber
    env.tostring = tostring
    env.math = math
    env.string = string
    env.table = table
    env.bit = bit
    env.coroutine = coroutine
    env._VERSION = _VERSION

    return env
end

local function runSandboxFile(filePath, extraArgs)
    local vfs, state = buildVirtualFS()
    local imported = importIntoVirtualFS(state, normalizePath(filePath), normalizePath(filePath))

    local sandboxEnv = makeSandboxEnvironment(vfs)
    local chunk, err = loadstring((state.files[imported] or ""), "@" .. imported)
    if not chunk then
        error(err, 0)
    end

    setfenv(chunk, sandboxEnv)
    local ok, result = pcall(chunk, unpack(extraArgs or {}))
    if not ok then
        error(result, 0)
    end

    return result
end

sandbox.import = function(path, destination)
    local vfs, state = buildVirtualFS()
    local target = destination or normalizePath(path)
    local imported = importIntoVirtualFS(state, normalizePath(path), target)
    sandbox.fs = vfs
    sandbox.state = state
    return imported
end

sandbox.run = function(path, ...)
    return runSandboxFile(path, { ... })
end

local args = { ... }
if #args == 0 then
    print("Usage: sandbox <path-to-file-or-directory>")
    print("Example: sandbox /files/suspicious.lua")
    return
end

for _, input in ipairs(args) do
    local source = normalizePath(input)
    sandbox.import(source, source)
end

return
