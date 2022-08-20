--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Multiplayer Handler">
 <location>load</location>
 <chance>100</chance>
 <unique />
</event>
--]]
--[[

   Multiplayer Event

   This event runs constantly in the background and manages MULTIPLAYER!!!
--]]
local fmt           = require "format"
local mplayerclient = require "multiplayer.client"
local mplayerserver = require "multiplayer.server"
-- luacheck: globals load (Hook functions passed by name)

function create ()
    hook.load("load")
end

local serverbtn
local clientbtn


local function startMultiplayerServer()
    -- NOTE: can put a custom port here as arg
    local fail = mplayerserver.start()
    if fail then
        print(fail)
        return
    end

    -- you are a server now, stay like that!
    player.infoButtonUnregister( serverbtn )
    player.infoButtonUnregister( clientbtn )
end

local function connectMultiplayer()
    local hostname = tk.input("Connect", 0, 32, "HOSTNAME") or "localhost"
    local hostport = tk.input("Connect", 0, 32, "PORT") or "6789"
    local localport = "0" -- get an ephemeral port

    local target = fmt.f( "{host}:{port}", { host = hostname, port = hostport } )

    -- for testing
    if not target  or target == ":" then
        hostname = "localhost"
        hostport = "6789"
    end

    if target then
        fail = mplayerclient.start( hostname, hostport, localport )
        if fail then
            print("ERROR: " .. fail )
        else
            -- sorry user, restart game to reconnect
            player.infoButtonUnregister( serverbtn )
            player.infoButtonUnregister( clientbtn )
        end
    end
end

function load()
	serverbtn = player.infoButtonRegister( _("Start MP Server"), startMultiplayerServer, 3)
	clientbtn = player.infoButtonRegister( _("Connect Multiplayer"), connectMultiplayer, 3)
end
