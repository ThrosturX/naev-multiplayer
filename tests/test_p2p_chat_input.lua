local luatk_stub = {
   isOpen = function() return true end,
}

local map_calls = 0
local unpauses = 0
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
package.loaded["multiplayer.p2p.session"] = {}
package.loaded.luatk = luatk_stub
package.loaded.vn = vn_stub

naev = naev_stub
_ = function(value) return value end

assert(loadfile("events/multiplayer.lua"))()

local run_chat,keep_chat_live
for index = 1, 20 do
   local name, value = debug.getupvalue(P2P_SESSION_INPUT, index)
   if not name then break end
   if name == "p2p_run_chat" then
      run_chat = value
   elseif name == "p2p_keep_chat_live" then
      keep_chat_live = value
   end
end
assert(run_chat, "P2P chat runner was not captured by the input callback")
assert(keep_chat_live, "P2P live chat updater was not captured by the input callback")

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

run_chat()
assert(map_calls == 0, "starmap opened while chat input was active")
assert(typed == "m", "starmap binding was not forwarded to text input")
assert(vn_stub.keypressed == original_keypressed, "VN key handler was not restored")

vn_stub.keypressed("m", false)
assert(map_calls == 1, "starmap handling was not restored after chat closed")

print("ok - P2P chat accepts the starmap binding without opening the map")
