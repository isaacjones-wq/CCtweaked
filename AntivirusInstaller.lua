-- Save the original function
local oldOpen = fs.open

local dummy = oldOpen("AV/dummyFile.txt","w")
dummy.write("This code can't handle an error lol")
dummy.close()

local uninstallKeyFile = oldOpen("AV/uninstallKey.txt", "w")
local uninstallKey = math.random(100000, 999999)
uninstallKeyFile.write(uninstallKey)
uninstallKeyFile.close()

local uninstallScript = oldOpen("AV/uninstall.lua", "w")
uninstallScript.write( [[
  local input = {...}
  if not input then
    print("Usage: uninstall <code>")
  end
  local code = tonumber(input[1])
  if code == ]] .. uninstallKey .. [[ then
    local startup = fs.open("startup.lua", 'w')
    startup.write("")
    startup.close()
    fs.delete("AV")
  else
    print("Wrong key.")
  end

]])

local start = oldOpen("startup.lua", "w")
start.write([[

function ynRequest(ask)
  term.setTextColor(colors.white)
  write(ask.." (")
  term.setTextColor(colors.lime) write("y")
  term.setTextColor(colors.white) write("/")
  term.setTextColor(colors.red) write("n")
  term.setTextColor(colors.white) write(") ")
  local input = read()
  if input == "y" then
    return true
  else
    return false
  end
end

local oldPullEvent = os.pullEvent
os.pullEvent = os.pullEventRaw

term.setTextColour(colors.orange)
print("Antivirus is Armed")
term.setTextColour(colors.white)

local oldOpen = fs.open

function isSafe(path)
  local isSafe = false
  if path:sub(1, 5) == "/rom/" or path:sub(1, 4) == "rom/" or shell.getRunningProgram():sub(1,4) == "rom/" then
        isSafe = true
  end
  return isSafe
end

-- Override fs.open
function fs.open(path, mode)
    local out = ""
    local request = ""
    if isSafe(path) then
      request = true
    elseif shell.getRunningProgram() == "AV/uninstall.lua" then
      request = true
    elseif path == "AV/uninstall.lua" then
      request = false
    elseif path == "startup.lua" then
      request = false
      term.setTextColor(colors.cyan)
      write("startup.lua")
      term.setTextColor(colors.red)
      print(" is not allowed to be modified!")
    else
      term.setTextColor(colors.cyan)
      write(shell.getRunningProgram())
      term.setTextColour(colors.orange)
      print(": Opening file: " .. path)
      term.setTextColour(colors.white)
      request = ynRequest("Allow?")
    end


    if request == true then
      out = oldOpen(path, mode)
    else
      local dummyFile = oldOpen("AV/dummyFile.txt","w")
      dummyFile.write(shell.getRunningProgram().." fell for a dummy file lol")
      dummyFile.close()
      out = oldOpen("AV/dummyFile.txt", mode)
    end

    return out
end

local oldReboot = os.reboot

function os.reboot()
  local path = shell.getRunningProgram()
  local safe = isSafe(path)
  if safe == false then
    term.setTextColor(colors.cyan)
    write(shell.getRunningProgram())
    term.setTextColor(colors.orange)
    print(" is trying to reboot computer.")
    term.setTextColor(colors.white)
    safe = ynRequest("Allow reboot?")
  end

  if safe then
    oldReboot()
  end
end

]])
start.close()
term.setTextColor(colors.cyan)
print("Installed!")
term.setTextColor(colors.orange)
shell.run("startup.lua")
