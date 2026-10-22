-- Sandbox runner for CC: Tweaked.
-- Usage:
--   sandbox /files/suspicious.lua
--   sandbox /files/suspicious.lua arg1 arg2
--
-- This lets a script run in a restricted environment where:
--   * risky functions and globals are monkeypatched away
--   * file access is limited to a virtual filesystem
--   * imported files can be copied in before execution
--   * no peripherals are available

local sandboxRoot = "/sandbox"

local function normalizePath(path)
    if not path then
        return nil
    end

    path = path:gsub("\\", "/")
    path = path:gsub("/+", "/")

    if path == "" then
        return "/"
    end

    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    return path
end

local function isWithinRoot(path)
    local root = sandboxRoot
    path = normalizePath(path)
    if path == root then
        return true
    end

    return path:sub(1, #root + 1) == root .. "/"
end

local function readFile(path)
    local file = fs.open(path, "r")
    if not file then
        return nil
    end

    local data = file.readAll()
    file.close()
    return data
end

local function listVirtualFiles(state, base)
    local prefix = normalizePath(base) or "/"
    if prefix ~= "/" and not isWithinRoot(prefix) then
        return {}
    end

    local out = {}
    local seen = {}

    for fullPath in pairs(state.files) do
        if fullPath:sub(1, #prefix) == prefix then
            local remainder = fullPath:sub(#prefix + 1)
            if remainder ~= "" then
                local name = remainder:match("^/([^/]+)")
                if name and not seen[name] then
                    seen[name] = true
                    table.insert(out, name)
                end
            end
        end
    end

    return out
end

local function makeVirtualFS()
    local state = {
        files = {},
        directories = {
            [sandboxRoot] = true,
        },
    }

    local function getVirtualPath(path)
        path = normalizePath(path)
        if not path then
            return nil
        end

        if isWithinRoot(path) then
            return path
        end

        return nil
    end

    local function makeHandle(path, mode)
        local file = { path = path, mode = mode, closed = false }

        file.read = function(self, n)
            if self.closed then
                return nil
            end

            if not state.files[self.path] then
                return nil
            end

            if self.pos == nil then
                self.pos = 1
            end

            local chunkSize = n or 1
            local chunk = state.files[self.path]:sub(self.pos, self.pos + chunkSize - 1)
            if chunk == "" then
                return nil
            end

            self.pos = self.pos + #chunk
            return chunk
        end

        file.readAll = function(self)
            if self.closed then
                return nil
            end

            local data = state.files[self.path]
            self.closed = true
            return data or ""
        end

        file.readLine = function(self)
            if self.closed then
                return nil
            end

            local data = state.files[self.path]
            if not data then
                return nil
            end

            if self.pos == nil then
                self.pos = 1
            end

            local from = self.pos
            local to = data:find("\n", from, true)
            if not to then
                to = #data + 1
            end

            local line = data:sub(from, to - 1)
            self.pos = to + 1

            if line == "" and data == "" then
                return nil
            end

            return line
        end

        file.write = function(self, text)
            if self.closed then
                error("Attempt to write to closed file", 2)
            end

            if self.mode == "r" then
                error("Attempt to write to read-only file", 2)
            end

            if not state.files[self.path] then
                state.files[self.path] = ""
            end

            if self.mode == "a" then
                state.files[self.path] = state.files[self.path] .. tostring(text)
            else
                state.files[self.path] = tostring(text)
            end
        end

        file.close = function(self)
            self.closed = true
        end

        return file
    end

    local fsProxy = {}

    fsProxy.exists = function(path)
        path = getVirtualPath(path)
        return path and state.files[path] ~= nil or false
    end

    fsProxy.isDir = function(path)
        path = normalizePath(path)
        if not path then return false end
        return path == sandboxRoot or path == "/" or state.directories[path] == true
    end

    fsProxy.list = function(path)
        path = normalizePath(path) or "/"
        if path == "/" then
            path = sandboxRoot
        end

        if not isWithinRoot(path) then
            return {}
        end

        local prefix = path == sandboxRoot and sandboxRoot or path
        return listVirtualFiles(state, prefix)
    end

    fsProxy.open = function(path, mode)
        path = normalizePath(path)
        if not path then
            return nil
        end

        local safePath = getVirtualPath(path)
        if not safePath then
            return nil
        end

        mode = mode or "r"
        if mode == "w" then
            state.files[safePath] = ""
            return makeHandle(safePath, mode)
        end

        if mode == "a" then
            if not state.files[safePath] then
                state.files[safePath] = ""
            end
            local handle = makeHandle(safePath, mode)
            handle.pos = #state.files[safePath] + 1
            return handle
        end

        if mode == "rb" or mode == "r" then
            if not state.files[safePath] then
                return nil
            end
            local handle = makeHandle(safePath, mode)
            handle.pos = 1
            return handle
        end

        return nil
    end

    fsProxy.getName = function(path)
        path = normalizePath(path)
        if not path then
            return ""
        end

        return path:match("([^/]+)$") or ""
    end

    fsProxy.delete = function(path)
        path = getVirtualPath(path)
        if not path then return false end
        if state.files[path] ~= nil then
            state.files[path] = nil
            return true
        end
        return false
    end

    fsProxy.makeDir = function(path)
        path = normalizePath(path)
        if not path then return false end
        if not isWithinRoot(path) then
            return false
        end

        state.directories[path] = true
        return true
    end

    return fsProxy, state
end

local function importIntoVirtualFS(vfsState, realPath, virtualPath)
    local source = normalizePath(realPath)
    if not source then
        error("No source path provided", 2)
    end

    local data = readFile(source)
    if not data then
        error("Could not read file: " .. source, 2)
    end

    local target = normalizePath(virtualPath) or (sandboxRoot .. "/" .. fs.getName(source))
    if not isWithinRoot(target) then
        target = sandboxRoot .. "/" .. fs.getName(source)
    end

    vfsState.files[target] = data
    return target
end

local function safeEnvFactory(vfs)
    local env = {}
    local safeMeta = {
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

    setmetatable(env, safeMeta)

    env._G = env
    env.assert = assert
    env.error = error
    env.ipairs = ipairs
    env.pairs = pairs
    env.pcall = pcall
    env.xpcall = xpcall
    env.select = select
    env.unpack = unpack
    env.next = next
    env.type = type
    env.tonumber = tonumber
    env.tostring = tostring
    env.math = math
    env.string = string
    env.table = table
    env.bit = bit
    env.coroutine = coroutine
    env.os = {
        clock = os.clock,
        date = os.date,
        difftime = os.difftime,
        time = os.time,
        sleep = function() end,
        queueEvent = function() end,
        pullEvent = function() return "timer", 0 end,
        pullEventRaw = function() return "timer", 0 end,
        shutdown = function() end,
        reboot = function() end,
    }

    env.fs = vfs
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

    env.shell = {
        run = function() return false end,
        getRunningProgram = function() return sandboxRoot .. "/main.lua" end,
        dir = function() return sandboxRoot end,
        setDir = function() return false end,
    }

    env.term = term
    env.window = nil
    env.load = nil
    env.loadfile = nil
    env.dofile = nil
    env.require = nil
    env.getfenv = nil
    env.setfenv = nil
    env.setmetatable = setmetatable
    env.rawget = rawget
    env.rawset = rawset
    env.rawequal = rawequal
    env.unpack = unpack
    env._VERSION = _VERSION

    return env
end

local function runSandbox(entryFile)
    local vfs, vfsState = makeVirtualFS()

    if entryFile then
        local file = normalizePath(entryFile)
        if file then
            importIntoVirtualFS(vfsState, file, sandboxRoot .. "/imported.lua")
        end
    end

    local env = safeEnvFactory(vfs)
    local source = vfsState.files[sandboxRoot .. "/imported.lua"]
    if not source then
        error("Sandbox did not import any code.")
    end

    local chunk, err = loadstring(source, "@" .. sandboxRoot .. "/imported.lua")
    if not chunk then
        error(err, 0)
    end

    setfenv(chunk, env)
    local ok, result = pcall(chunk)
    if not ok then
        error(result, 0)
    end

    return result
end

local args = { ... }
if #args == 0 then
    print("Sandbox usage: sandbox <path-to-file>")
    print("Example: sandbox /files/suspicious.lua")
    return
end

local ok, err = pcall(runSandbox, args[1])
if not ok then
    printError(err)
end

