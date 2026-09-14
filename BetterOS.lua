-- Put this under /startup/ to make it properly override

--CONFIG--
local password = "password"

--CODE--
local oldPullEvent = os.pullEvent
local width, height = term.getSize()
local runningAppName = ""

function os.pullEvent(filter)
    local event, p1, p2, p3 = os.pullEventRaw(filter)
    if event == "terminate" then
        return event, p1, p2, p3
    else
        return event, p1, p2, p3
    end
end

local function login()
    repeat
        term.setBackgroundColor(colors.blue)
        term.clear()
        term.setCursorPos(1,1)
        term.setTextColor(colors.white)
        print("Welcome to BetterOS!")
        term.setTextColor(colors.orange)
        print("Enter Password to Continue.")

        local passwordInput = read("*")
        if passwordInput ~= password then
            term.setTextColor(colors.red)
            print("Incorrect password! Try again.")
            os.sleep(1)
        end
    until passwordInput == password
end

local function waitForTermination()
    while true do
        local event, button, x, y = os.pullEventRaw()
        if event == "terminate" then
            print("Terminating " .. runningAppName)
            os.sleep(0.5)
            break
        end
    end
end

local function runApp(programFunction, name)
  term.setCursorPos(1,1)
  term.setBackgroundColor(colors.black)
  term.clear()
  runningAppName = name
  parallel.waitForAny(programFunction, waitForTermination)
end

---------------------------------------
----------DESKTOP MAIN SCRIPT----------
---------------------------------------
local function drawDesktop()
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Bottom Bar
    term.setBackgroundColor(colors.green)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))

    -- TIME
    term.setCursorPos(1, height)
    term.setTextColor(colors.white)
    term.write(textutils.formatTime(os.time("local"), false))

    -- APPS BUTTONS
    term.setTextColor(colors.white)
    term.write(" Shell")
    term.write(" Worm")
end

local function desktop()
  while true do
    drawDesktop()
    local event, button, x, y = os.pullEvent()
    if event == "mouse_click" and y == height then
      if x >= 9 and x <= 13 then
        runApp(function() shell.run("shell") end, "Shell")
      elseif x >= 15 and x <= 18 then -- Note: Adjusted X alignment for "Worm" space
        runApp(function() shell.run("worm") end, "Worm")
      end
    end
  end
end


-- Main Execution Flow
login()
desktop()
