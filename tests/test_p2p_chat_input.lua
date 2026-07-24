local luatk_stub = {
   isOpen = function() return true end,
}

local map_calls = 0
local unpauses = 0
local time_control_checks = 0
local typed = ""
local naev_stub = {
   keyGet = function(binding)
      assert(binding == "starmap")
      return "M"
   end,
   mapOpen = function()
      map_calls = map_calls + 1
   end,
   unpause = function()
      unpauses = unpauses + 1
   end,
}

local original_keypressed
local vn_stub = {}
original_keypressed = function(key)
   if string.lower(naev_stub.keyGet("starmap")) == key then
      naev_stub.mapOpen()
   end
   typed = typed .. key
   return true
end
vn_stub.keypressed = original_keypressed
vn_stub.run = function()
   assert(vn_stub.keypressed("m", false))
end

package.loaded.format = {}
package.loaded["multiplayer.client"] = {}
package.loaded["multiplayer.server"] = {}
package.loaded["multiplayer.p2p.session"] = {
   enforce_time_controls=function()
      time_control_checks=time_control_checks+1
   end,
   input=function() end,
}
package.loaded.luatk = luatk_stub
package.loaded.vn = vn_stub

naev = naev_stub
_ = function(value) return value end
local pilot_target,nav_spob,landed
local player_pilot = {
   target=function() return pilot_target end,
   nav=function() return nav_spob,nil end,
}
player = {
   pilot=function() return player_pilot end,
   isLanded=function() return landed==true end,
}

assert(loadfile("events/multiplayer.lua"))()

local run_chat,keep_chat_live,chat_available
for index = 1, 20 do
   local name, value = debug.getupvalue(P2P_SESSION_INPUT, index)
   if not name then break end
   if name == "p2p_run_chat" then
      run_chat = value
   elseif name == "p2p_keep_chat_live" then
      keep_chat_live = value
   elseif name == "p2p_chat_available" then
      chat_available = value
   end
end
assert(run_chat, "P2P chat runner was not captured by the input callback")
assert(keep_chat_live, "P2P live chat updater was not captured by the input callback")
assert(chat_available, "P2P chat target guard was not captured by the input callback")
assert(chat_available(), "empty hail target did not allow P2P chat")
landed=true
assert(not chat_available(), "landed player incorrectly allowed P2P chat")
landed=false
nav_spob={}
assert(not chat_available(), "selected spob incorrectly allowed P2P chat")
nav_spob=nil; pilot_target={}
assert(not chat_available(), "selected pilot incorrectly allowed P2P chat")
pilot_target={disabled=function() return true end}
assert(chat_available(), "disabled pilot target did not allow P2P chat")
nav_spob={}
assert(not chat_available(), "selected spob did not retain priority over a disabled pilot target")
pilot_target=nil
nav_spob=nil

local steady_updates = 0
local function steady_update () steady_updates = steady_updates + 1 end
local chat_state = {}
chat_state._update = function(self)
   self._update = steady_update
   steady_update()
end
keep_chat_live(chat_state)
chat_state:_update(0)
chat_state:_update(1/60)
assert(unpauses == 2, "chat overlay did not keep simulation unpaused from its first frame")
assert(steady_updates == 2, "chat overlay lost LuaTK's replacement update handler")
assert(time_control_checks == 2,
   "chat overlay did not enforce P2P time controls on every update")

run_chat()
assert(map_calls == 0, "starmap opened while chat input was active")
assert(typed == "m", "starmap binding was not forwarded to text input")
assert(vn_stub.keypressed == original_keypressed, "VN key handler was not restored")

vn_stub.keypressed("m", false)
assert(map_calls == 1, "starmap handling was not restored after chat closed")

local native_updates = 0
local function native_update ()
   native_updates = native_updates + 1
end
local function native_run ()
   vn_stub.update(1/60)
end
vn_stub.update = native_update
vn_stub.run = native_run

local unpauses_before_hail = unpauses
local checks_before_hail = time_control_checks
P2P_SESSION_HAIL()
assert(vn_stub.run ~= native_run, "native hail VN runner was not wrapped")
vn_stub.run()
assert(native_updates == 1, "native hail VN update handler did not run")
assert(unpauses == unpauses_before_hail + 1,
   "native hail VN did not keep simulation unpaused")
assert(time_control_checks == checks_before_hail + 1,
   "native hail VN did not enforce P2P time controls")
assert(vn_stub.update == native_update, "native hail VN update handler was not restored")
assert(vn_stub.run == native_run, "native hail VN runner was not restored")

P2P_SESSION_HAIL()
assert(vn_stub.run ~= native_run, "aborted hail did not install the VN wrapper")
P2P_SESSION_INPUT("hail", true)
assert(vn_stub.run == native_run, "aborted hail did not restore the VN runner")

print("ok - P2P chat accepts the starmap binding without opening the map")
