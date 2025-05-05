-- luacheck: globals P2P_ENTER_SYSTEM MULTIPLAYER_CLIENT_UPDATE MULTIPLAYER_CLIENT_INPUT enterMultiplayer reconnect control_reestablish (Hook functions passed by name)

local common = require "multiplayer.common"
local p2p_relay = require "multiplayer.relay"
local enet = require "enet"
local fmt = require "format"
local ai_setup = require "ai.core.setup"
local luatk = require "luatk"
local vn = require "vn"

local client = {}
--[[
      client.host
      client.server
      client.playerinfo { nick, ship?, outfits... }

      client.pilots = { playerid = pilot, ... }

      client.start()      -- DEATHMATCH MODE
      client.start_peer() -- UNIVERSE SHARE MODE
      client.synchronize( world_state )
      client.update()
--]]


local outfit_types = {
    ["Afterburner"] = "afterburner",
    ["Shield Modification"] = "shield_booster",
    ["Blink Drive"] = "blink_drive",
    ["Bioship Organ"] = "bite",
--[[
  ["Blink Engine"] = "blink_engine",
  [""] = "",
  [""] = "",
  ["MISSING"] = "none",
--]]
}

-- converts a world_state into information about "me" and a list of players I know about
--[[
--      my_player_id <my_stats>
--      other_player_id
--      ...
--]]
local function _marshal ( players_info )
    local cache = naev.cache()
    local message = common.marshal_me(client.playerinfo.nick, cache.accel, cache.primary, cache.secondary)
    for opid, opplt in pairs(players_info) do
        -- TODO cache opplts' ships
        if opplt:exists() then
            message = message .. '\n' .. fmt.f( "{id}={ship}", { id = opid, ship = opplt:ship():nameRaw() } )
        end
    end
    return message .. '\n'
end

local function receiveMessage( message )
    local msg_type
    local msg_data = {}
    for line in message:gmatch("[^\n]+") do
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

--    print("CLIENT RECEIVES: " .. msg_type )
    if common.receivers[msg_type] then
        return common.receivers[msg_type]( client, msg_data )
    else
        player.pilot():broadcast( msg_type )
        return
    end
end

-- we are about to connect to a server, so we will disable client-side NPC
-- spawning for the sake of consistency
local was_connected = nil
client.start = function( bindaddr, bindport, localport )
    if client.relay ~= nil then
        return "CLIENT_CONFIGURED_FOR_PEERPLAY"
    end

    if not localport then localport = rnd.rnd(1234,6788) end
    if not player.isLanded() and not was_connected then
        return "PLAYER_NOT_LANDED"
    end

    client.host = enet.host_create("*:" .. tostring(localport))
    if not client.host then
        return "NO_CLIENT_HOST"
    end
    client.conaddr = bindaddr
    client.conport = bindport
    client.server = client.host:connect( fmt.f("{addr}:{port}", { addr = bindaddr, port = bindport } ) )
    if not client.server then
        return "NO_CLIENT_SERVER"
    end
    -- WE ARE GOING IN
    player.landAllow ( false, _("Landing is disabled in multiplayer. If you're not in a multiplayer system, something's gone wrong!") )
    client.pilots = {}
    pilot.clear()
    pilot.toggleSpawn(false)
    -- TODO HERE: This part was largely so that error messages say "MULTIPLAYER" and
    -- not just the player ship name, maybe give the player a cargo shuttle called "MULTIPLAYER" instead
    local player_ship = player:pilot():ship():nameRaw() -- "Cargo Shuttle"
    local mpshiplabel = "MULTIPLAYER SHIP"

    -- send the player off
    player.takeoff()
    hook.timer(1, "enterMultiplayer")
    -- some consistency stuff
    -- 20-11-2024 NOTE: This needs to be revisited after changes to weapsets
    naev.keyEnable( "speed", false )
    player.cinematics(
        true,
        {
            abort = _("Entering multiplayer..."),
            no2x = true,
            gui = false
        }
    )
    -- configure the playerinfo for multiplayer
    client.playerinfo = {
        nick = player.name():gsub(' ', ''),
        ship = player_ship,
        outfits = common.marshal_outfits(player.pilot():outfitsList())
    }

    was_connected = true
end

-- like client.start, but instead of entering the multiplayer lobby,
-- it tries to connect to other peers
client.start_peer = function()
    -- store potential peers in the relay
    -- peer play clients have to be able to host
    -- the relay object handles peer-to-peer communication
    -- until a server is established,
    -- at which point one of the peers acts as the server
    client.relay = p2p_relay.start() -- start takes argument port choice
    if not client.relay then
        return "NO_CLIENT_RELAY"
    end

    client.host = enet.host_create("*:0") -- use ephemeral for client
    if not client.host then
        return "NO_CLIENT_HOST"
    end

    -- TODO: hook on "enter" to find a server and connect to it
    client.ehook = hook.enter( "P2P_ENTER_SYSTEM" )
end

-- the logic we go through when entering a system
client.entered_system = function()
    if client.relay == nil then
        print("ERROR: Calling p2p enter hook without a client relay!")
        return "ERROR_NO_CLIENT_RELAY"
    end
    -- 1. try to find the owner of this system and connect

    print("WARNING: peer search not available, creating server...")
    local syst = system.cur():nameRaw()
    local err = client.relay.join(syst)
    if err == nil then
        -- success
        return nil
    end

    print("DEBUG: <relay.join> " .. err)

    -- 2. else start hosting and advertise ourselves
    client.relay.open()

    -- TODO do we need to connect to ourselves?
    -- let's decide later if we like listenserver pattern or not
end

P2P_ENTER_SYSTEM = function() return client.entered_system() end


local omsgid
local TEMP_FREEZE
local function control_override( timeout )
    timeout = timeout or 0.12 
    TEMP_FREEZE = true
    player.cinematics(
        true,
        {
            abort = _("Synchronizing..."),
            no2x = true,
            gui = false
        }
    )
    omsgid = player.omsgAdd(
        "#y".._("ESTABLISHING CONTROL").."#0",
        2
    )
    hook.timer( timeout, "control_reestablish" )
end

function control_reestablish()
    music.stop( ) -- let the server direct our musical choices :)
    player.cinematics(
        false,
        {
            abort = _("Autonav disabled in multiplayer."),
            no2x = true,
            gui = true
        }
    )
    TEMP_FREEZE = nil
    if omsgid then
        player.omsgChange(
            omsgid,
            "#b".._("CONTROL ESTABLISHED").."#0",
            3
        )
    end
    
    
    -- remove any fleet ships
    local fleet = player.fleetList()
    for fk, fv in pairs(fleet) do
        player.shipDeploy(tostring(fv))
        fv:setHealth(0)
    end

end

local hard_resync
local MY_SPAWN_POINT = player.pilot():pos()
client.spawn = function( ppid, shiptype, shipname , outfits, ai )
    if
        client.pilots[ppid]
        and not client.pilots[ppid]:exists()
    then
        client.pilots[ppid] = nil
    end
    ai = "remote_control"
    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = ai, clear_allies = true, clear_enemies = true } 
    )
    if ppid ~= client.playerinfo.nick and (not client.pilots[ppid] or client.pilots[ppid]:ship():nameRaw() ~= shiptype) then
        if client.pilots[ppid] then
            client.pilots[ppid]:setHealth(0)
        end
        client.pilots[ppid] = pilot.add(
            shiptype,
            mplayerfaction,
            MY_SPAWN_POINT,
            shipname,
            { naked = true }
        )
        for _i, outf in ipairs(outfits) do
            client.pilots[ppid]:outfitAdd(outf, 1, true)
        end
        ai_setup.setup( client.pilots[ppid] )
        pmem = client.pilots[ppid]:memory()
        pmem.comm_no = _("NOTICE: Staying in chat will get you killed or disconnected. Caveat user!")
        print("created pilot for " .. tostring(ppid))
    elseif ppid == client.playerinfo.nick then
        if ( not client.alive or shiptype ~= player.pilot():ship():nameRaw() ) then
    --      client.pilots[ppid] = player.pilot()
            -- the server tells us to spawn in a new ship or acknowledges this ship
            local mpshiplabel = "MPSHIP" .. tostring(rnd.rnd(10000, 99999)) .. shipname
            local mplayership = player.shipAdd(shiptype, mpshiplabel, "Multiplayer", true)
            player.shipSwap( mpshiplabel, false, false )
            for _i, outf in ipairs(outfits) do
                player.pilot():outfitAdd(outf, 1, true)
            end
            print("respawned pilot for you: " .. tostring(ppid) .. " in a " .. shiptype)
            client.alive = true
            hard_resync = true
            for _oplid, oplt in pairs(client.pilots) do
                if oplt:exists() then
                    oplt:setHealth(0)
                end
            end
            -- stay alive to get a new ship if we die
            player.pilot():setNoDeath( true )
            -- deliberately desync position to get an update
            player.pilot():setPos(vec2.new(rnd.rnd(-9999, 9999), rnd.rnd(-9999, 9999)))
            player.pilot():setVel(vec2.new(0, 0))
            player.pilot():setHealth(100, 100, 100)
            player.pilot():intrinsicSet("Detection", -8)
            control_override()
        else
            hard_resync = false
            client.alive = false
        end
    else
        print("WARNING: Trying to add already existing pilot: " .. tostring(ppid))
        if ppid ~= client.playerinfo.nick and client.pilots[ppid] and client.pilots[ppid]:ship():nameRaw() ~= shiptype then
            print("should be in a <" .. client.pilots[ppid]:ship():nameRaw() .. "> but is in a <" .. shiptype .. ">")
        end
    end
end

local RESYNC_INTERVAL = 64 + rnd.rnd(36, 72)
local last_resync
local skipped_frames = 0
local FPS = 60
-- TODO HERE: refactor some common.sync_player (resync=true regularly)
client.synchronize = function( world_state )
    -- synchronize pilots
    local resync
    if not last_resync or last_resync >= RESYNC_INTERVAL then
        resync = true
--      print("resync " .. tostring(last_resync))
        last_resync = 0
    end
    last_resync = last_resync + 1
    local frames_passed = client.server:round_trip_time() / (1000 / FPS)
    local touched = {}
    for ppid, ppinfo in pairs(world_state.players) do
        touched[ppid] = true
        if ppid ~= client.playerinfo.nick then
            if client.pilots[ppid] and client.pilots[ppid]:exists() then
                local this_pilot = client.pilots[ppid]
                local target = ppinfo.target or "NO TARGET!!"
                if
                    target and client.pilots[ target ]
                    and client.pilots[target]:exists()
                then
                    client.pilots[ppid]:setTarget( client.pilots[target] )
                else
                    client.pilots[ppid]:setTarget( player.pilot() )
                end
                local pdiff = math.abs( vec2.add( this_pilot:pos() , -ppinfo.posx, -ppinfo.posy ):mod() )
                if hard_resync or (resync and pdiff > 6) then
                    if pdiff >= 100 then
                        client.pilots[ppid]:setPos(vec2.new(ppinfo.posx, ppinfo.posy))

                    elseif pdiff > 12 or pdiff < 1 then
                        local new_pos = 0.25 * vec2.new(ppinfo.posx, ppinfo.posy) + 0.75 * this_pilot:pos()
                        client.pilots[ppid]:setPos(new_pos)
                    else
                        local avg_pos = (vec2.new(ppinfo.posx, ppinfo.posy) + this_pilot:pos()) / 2
                        client.pilots[ppid]:setPos( avg_pos )
                    end
                    client.pilots[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
                elseif pdiff > 8 then
                    last_resync = last_resync * pdiff
--                  client.pilots[ppid]:effectAdd("Wormhole Exit", 0.2)
                end
                if resync and ppinfo.accel and pdiff > 8 then
                    -- apply minor velocity prediction
                    local stats = this_pilot:stats()
                    local angle = vec2.newP(0, ppinfo.dir)
                    local acceleration = stats.accel / stats.mass
                    local dv = vec2.mul(angle, acceleration)
                    local rtt = client.server:round_trip_time()
                    local pdv = vec2.new(
                        ppinfo.velx, ppinfo.vely
                    ) + dv * frames_passed -- last_resync / 60
                    client.pilots[ppid]:setVel(pdv)
                elseif math.abs(ppinfo.velx * ppinfo.vely) < 1 then
                    -- ensure low-speed fidelity
                    client.pilots[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
                end
                client.pilots[ppid]:setDir(ppinfo.dir)
                local armour_fix = math.max(10, ppinfo.armour)
                local shield_fix = math.max( 6 + rnd.sigma(), ppinfo.shield )
                if armour_fix <= 12 then
                    shield_fix = shield_fix + 6 + rnd.rnd(6, 10)
                end
                if ppinfo.armor == 0 then
                    armour_fix = 0
                end
                client.pilots[ppid]:setHealth(
                    armour_fix,
                    shield_fix,
                    ppinfo.stress
                )
                pilot.taskClear( client.pilots[ppid] )
                if ppinfo.weapset then
                    -- this is really laggy I think
                    pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_SWITCH_WEAPSET", ppinfo.weapset )
                end
                if ppinfo.primary == 1 then
                    pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_SHOOT", false )
                    if target and client.pilots[ target ] and client.pilots[target] == player.pilot() then
                        client.pilots[ppid]:setHostile()
                    end
                end
                if ppinfo.secondary == 1 then
                    pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_SHOOT", true )
                    if target and client.pilots[ target ] and client.pilots[target] == player.pilot() then
                        client.pilots[ppid]:setHostile()
                    end
                end
                if ppinfo.accel then
                    local anum = tonumber(ppinfo.accel)
                    if anum == 1 then
                        pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_ACCEL", 1 )
                    elseif resync then
                        pilot.pushtask( client.pilots[ppid], "REMOTE_CONTROL_ACCEL", 0 )
                    end
                end
            else
                print(fmt.f("WARNING: Updating unknown pilot <{id}>", ppinfo), ppid)
            end
        else    -- if we want to sync self from server, do it here
            local ppme = player.pilot()
            local pdiff = vec2.add( ppme:pos() , -ppinfo.posx, -ppinfo.posy ):mod()
            local fudge = 2
            local mdiff = (
                math.abs( vec2.new( ppinfo.velx + fudge, ppinfo.vely + fudge):mod() * fudge ) + fudge 
            ) * frames_passed
            if pdiff > mdiff * 1.36 or ( resync and (pdiff >= mdiff and skipped_frames == 0)) or hard_resync then
                ppme:setPos( vec2.new(ppinfo.posx, ppinfo.posy) )
                if hard_resync then
                  ppme:setVel( vec2.new(ppinfo.velx, ppinfo.vely) )
                end
                print("SYNC ME -- HARD SYNC: " .. tostring(hard_resync))
                hard_resync = nil
--                ppme:effectAdd("Blink", 1)
            end
            -- don't override direction
            -- ppme:setVel( vec2.new(ppinfo.velx, ppinfo.vely) )
            -- ppme:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
        end
    end

    -- clean untouched
    for plid, pplt in pairs(client.pilots) do
        if not touched[plid] and pplt:exists() then
            pplt:setDisable(true)
        end
    end

end

local function safe_send ( dat )
    if client.server:state() == "connected" then
        client.server:send( dat )
    else
        print("Cannot send in unconnected state: " .. client.server:state())
        client.alive = nil
    end
end

local function activate_outfits( )
    local activelines = ""
    local deactilines = ""
    local actives = player.pilot():actives()
    local message
    for ii, oo in ipairs(actives) do
--      print(fmt.f("{i} is {x}", {i = ii, x=oo} ))
        if oo and oo.state == "on" then
            print(fmt.f("activate {thing}", { thing=oo.outfit } ))
            for jj, pp in pairs(oo) do
                print(fmt.f("{i}: {x}", {i = jj, x=pp} ))
            end
        end
        local outf_class = outfit_types[tostring(oo.type)]
        if oo.state ~= "off" then
            if tostring(oo.outfit) == 'Hyperbolic Blink Engine' then
                outf_class = "blink_engine"
            end
        end
        if outf_class then
            if oo.state ~= "off" then
                if oo.state == "cooldown" then
                    if oo.cooldown > 0.9 then
                        activelines = activelines .. outf_class .. "\n"
                    end
                else -- state is on
                    print(outf_class .. " is in state " .. tostring(oo.state))
                    activelines = activelines .. outf_class .. "\n"
                end
            elseif oo.state == "off" then
                deactilines = deactilines .. outf_class .. "\n"
            end
        else
            print(fmt.f("{outf} of type {otype} doesn't have a known class yet", { outf = oo.outfit, otype=oo.type } ))
        end
    end
    if activelines:len() > 0 then
        message = fmt.f(
            "{key}\n{ident}\n{actives}",
            {
                key = common.ACTIVATE_OUTFIT,
                ident = client.playerinfo.nick,
                actives = activelines
            }
        )
        safe_send( message )
        print("sent " .. message)
    end
    if deactilines:len() > 0 then
        message = fmt.f(
            "{key}\n{ident}\n{actives}",
            {
                key = common.DEACTIVATE_OUTFIT,
                ident = client.playerinfo.nick,
                actives = deactilines
            }
        )
        safe_send( message )
    end
end

local function tryRegister( nick )
    safe_send(
        fmt.f(
            "{key}\n{nick}\n{ship}\n{outfits}\n",
            {
                key = common.REQUEST_KEY,
                nick = nick,
                ship = client.playerinfo.ship,
                outfits = client.playerinfo.outfits,
            }
        )
    )
end

local sync_frames = 0
local updates_per_second = 15
client.update = function( timeout )
    timeout = timeout or 0
    --[[
    player.cinematics(
        false,
        {
            abort = _("Autonav disabled in multiplayer."),
            no2x = true,
            gui = true
        }
    )
    --]]
    player.autonavReset()
    -- check what we think that we know about others
    for cpid, cpplt in pairs(client.pilots) do
        if not cpplt or not cpplt:exists() then
            client.pilots[cpid] = nil
        end
    end
    
    -- get any updates
    local func = function( tt ) return client.host:service( tt ) end
    local success, event = pcall( func, timeout )
    if not success then
        print('HOST ERROR:' .. event)
        return
    end
    while event do 
        if event.type == "receive" then
--            print("Got message: ", event.data, event.peer)
            -- update world state or whatever the server asks
            receiveMessage( event.data )
        elseif event.type == "connect" then
            print(event.peer, " connected.")
            if client.relay == nil then
                -- this is not a p2p session, spawn in a random place and let the server fix it
                player.pilot():setPos( vec2.new( rnd.rnd(-3000, 3000), rnd.rnd(-2000, 2000) ) )
            end
            -- register with the server
            tryRegister( client.playerinfo.nick )
            client.alive = false
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            common.receivers[common.PLAY_SOUND]( client, { "snd/sounds/jingles/eerie.ogg" } )
            player.damageSPFX(1.0)
            if client.relay ~= nil then
                -- TODO:
                -- 1. save the current state into the client.server host_object
                -- 2. try to reconnect to the last server
                -- 3. else try to find a new server
                -- 4. else start hosting and advertise ourselves

            else
                -- try to reconnect to the deathmatch arena
                hook.rm(client.hook)
                hook.timer(3, "reconnect")
            end
            client.alive = nil
            return -- deal with the rest later
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = client.host:service()
    end

    if skipped_frames >= sync_frames then
        sync_frames = naev.fps() / updates_per_second
        -- tell the server what we know and ask for next resync
        safe_send( common.REQUEST_UPDATE  .. '\n' .. _marshal( client.pilots ) )
        skipped_frames = 0
    else
        skipped_frames = skipped_frames + 1
    end
end

function reconnect()
    -- reset all pilots' hostility
    for ppid, pplt in pairs(client.pilots) do
        pplt:setHostile(false)
    end

    client.server = client.host:connect( fmt.f("{addr}:{port}", { addr = client.conaddr, port = client.conport } ) )
 
    tryRegister( client.playerinfo.nick )

    client.update( 4000 )
    client.hook = hook.update("MULTIPLAYER_CLIENT_UPDATE")
end

client.reconnect = function ()
    if client.server then
        client.server:disconnect_now()
    end
    reconnect()
end

function enterMultiplayer()
    -- remove any potential hail hooks set by other plugins (e.g. crewmates plugin)
    if mem.hail_hook then
        hook.rm( mem.hail_hook )
        mem.hail_hook = nil
    end
    player.allowSave ( false )  -- no saving free multiplayer ships
    player.teleport("Multiplayer Lobby")
    -- register with the server
    tryRegister( client.playerinfo.nick )

    client.update( 4000 )

    control_reestablish()

    client.hook = hook.update("MULTIPLAYER_CLIENT_UPDATE")
    client.inputhook = hook.input("MULTIPLAYER_CLIENT_INPUT")
end

local MP_INPUT_HANDLERS = {}

MP_INPUT_HANDLERS.accel = function ( press )
--  print("accel " .. tostring(press))
    if press then 
        naev.cache().accel = 1
    else
        naev.cache().accel = 0
    end
    -- update active outfits
    activate_outfits()
end

MP_INPUT_HANDLERS.primary = function ( press )
--  print("primary " .. tostring(press))
    if press then 
        naev.cache().primary = 1
    else
        naev.cache().primary = 0
    end
end

MP_INPUT_HANDLERS.secondary = function ( press )
--    print("secondary " .. tostring(press))
    if press then 
        naev.cache().secondary = 1
    else
        naev.cache().secondary = 0
    end
end

local hail_pressed
MP_INPUT_HANDLERS.hail = function ( press )
--  player.commClose()
    if press then
        hail_pressed = true
    elseif hail_pressed then
        vn.reset()
        luatk.vn( function()
            luatk.msgInput("COMMUNICATION", "Broadcast:", 32, function (msg)
                if msg and msg:len() > 0 then
                   safe_send( common.SEND_MESSAGE .. '\n' .. msg )
                end
            end )
        end )
        vn.run()
    end
    if not player.pilot():target() then
        last_resync = 300
    end
end


-- stop sounds if ESC is pressed, in case the player is leaving the multiplayer session
MP_INPUT_HANDLERS.menu = common.stop_sounds

MP_INPUT_HANDLERS.weapset1 = activate_outfits
MP_INPUT_HANDLERS.weapset2 = activate_outfits
MP_INPUT_HANDLERS.weapset3 = activate_outfits
MP_INPUT_HANDLERS.weapset4 = activate_outfits
MP_INPUT_HANDLERS.weapset5 = activate_outfits
MP_INPUT_HANDLERS.weapset6 = activate_outfits
MP_INPUT_HANDLERS.weapset7 = activate_outfits
MP_INPUT_HANDLERS.weapset8 = activate_outfits
MP_INPUT_HANDLERS.weapset9 = activate_outfits
MP_INPUT_HANDLERS.weapset0 = activate_outfits

MULTIPLAYER_CLIENT_UPDATE = function()
    if client.relay ~= nil then
        client.relay.update()
    end
    return client.update()
end
function MULTIPLAYER_CLIENT_INPUT ( inputname, inputpress, args )
    if MP_INPUT_HANDLERS[inputname] then
        MP_INPUT_HANDLERS[inputname]( inputpress, args )
--  else
--      print(fmt.f("no handler for input {input}", { input = inputname } ))
    end
    if not TEMP_FREEZE then
        skipped_frames = 999
    end
    naev.unpause()
end

return client
