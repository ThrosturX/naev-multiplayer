-- luacheck: globals MULTIPLAYER_CLIENT_UPDATE MULTIPLAYER_CLIENT_INPUT enterMultiplayer reconnect control_reestablish (Hook functions passed by name)

local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"
local mp_equip = require "equipopt.templates.multiplayer"
local ai_setup = require "ai.core.setup"
-- require "factions.equip.generic"

local client = {}
--[[
--      client.host
--      client.server
--      client.playerinfo { nick, ship?, outfits... }
--
--      client.pilots = { playerid = pilot, ... }
--
--      client.start()
--      client.synchronize( world_state )
--      client.update()
--]]

-- converts a world_state into information about "me" and a list of players I know about
--[[
--      my_player_id <my_stats>
--      other_player_id
--      ...
--]]


-- borrowed from ai.core.attack.setup
local usable_outfits = {
   ["Emergency Shield Booster"]  = "shield_booster",
   ["Berserk Chip"]              = "berserk_chip",
   ["Combat Hologram Projector"] = "hologram_projector",
   ["Neural Accelerator Interface"] = "neural_interface",
   ["Blink Drive"]               = "blink_drive",
   ["Hyperbolic Blink Engine"]   = "blink_engine",
   ["Unicorp Jammer"]            = "jammer",
   ["Milspec Jammer"]            = "jammer",
   -- Bioships
   ["Feral Rage III"]            = "feral_rage",
   ["The Bite"]                  = "bite",
   ["The Bite - Improved"]       = "bite",
   ["The Bite - Blood Lust"]     = {"bite", "bite_lust"},
   -- afterburners
   ["Unicorp Light Afterburner"] = "afterburner",
   ["Unicorp Medium Afterburner"] = "afterburner",
   ["Hellburner"] = "afterburner",
   ["Hades Torch"] = "afterburner",
}

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
client.start = function( bindaddr, bindport, localport )
    if not localport then localport = rnd.rnd(1234,6788) end
    if not player.isLanded() then
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
    player.allowLand ( false, _("Multiplayer prevents landing.") )
    client.pilots = {}
    pilot.clear()
    pilot.toggleSpawn(false)
    -- TODO HERE: This part was largely so that error messages say "MULTIPLAYER" and
    -- not just the player ship name, maybe give the player a cargo shuttle called "MULTIPLAYER" instead
    local player_ship = "Cargo Shuttle"
    local mpshiplabel = "MULTIPLAYER SHIP"

    -- send the player off
    player.takeoff()
    hook.timer(1, "enterMultiplayer")
    -- some consistency stuff
    naev.keyEnable( "speed", false )
    naev.keyEnable( "weapset1", false )
    naev.keyEnable( "weapset2", false )
    naev.keyEnable( "weapset3", false )
    naev.keyEnable( "weapset4", false )
    naev.keyEnable( "weapset5", false )
    naev.keyEnable( "weapset6", false )
    naev.keyEnable( "weapset7", false )
--  naev.keyEnable( "weapset8", false ) -- shield booster
--  naev.keyEnable( "weapset9", false ) -- afterburner, that's fine
    naev.keyEnable( "weapset0", false )
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
end

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
    music.stop( true ) -- let the server direct our musical choices :)
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
            local mplayership = player.addShip(shiptype, mpshiplabel, "Multiplayer", true)
            player.swapShip( mpshiplabel, false, false )
            for _i, outf in ipairs(outfits) do
                player.pilot():outfitAdd(outf, 1, true)
            end
            print("respawned pilot for you: " .. tostring(ppid))
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
local soft_sync = 0
local last_resync
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
                    client.pilots[ppid]:setPos(vec2.new(ppinfo.posx, ppinfo.posy))
                    client.pilots[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
                elseif pdiff > 8 then
                    last_resync = last_resync * pdiff
--                  client.pilots[ppid]:effectAdd("Wormhole Exit", 0.2)
                end
                if resync and ppinfo.accel and pdiff > 8 then
                    -- apply minor velocity prediction
                    local stats = this_pilot:stats()
                    local angle = vec2.newP(0, ppinfo.dir)
                    local acceleration = stats.thrust / stats.mass
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
                if ppinfo_armor == 0 then
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
            if pdiff > mdiff * 1.36 or ( resync and (pdiff >= mdiff and soft_sync == 0)) or hard_resync then
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
            pplt:disable(true)
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
        if usable_outfits[oo.name] then
            if oo.state == "on" then
                activelines = activelines .. usable_outfits[oo.name] .. "\n"
            elseif oo.state == "off" then
                deactilines = deactilines .. usable_outfits[oo.name] .. "\n"
            end
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
            player.pilot():setPos( vec2.new( rnd.rnd(-3000, 3000), rnd.rnd(-2000, 2000) ) )
            -- register with the server
            tryRegister( client.playerinfo.nick )
            client.alive = false
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            common.receivers[common.PLAY_SOUND]( client, { "snd/sounds/jingles/eerie.ogg" } )
            for _sndid, sfx in pairs(common.mp_sounds) do
                sfx:setLooping( false )
            end
            player.damageSPFX(1.0)
            -- try to reconnect
            hook.rm(client.hook)
            hook.timer(6, "reconnect")
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
    
    if soft_sync > 0 then
        -- tell the server what we know and ask for next resync
        safe_send( common.REQUEST_UPDATE .. '\n' .. _marshal( client.pilots ) )
        soft_sync = 0
    else
        soft_sync = soft_sync + 1
    end
end

function reconnect()
    client.server = client.host:connect( fmt.f("{addr}:{port}", { addr = client.conaddr, port = client.conport } ) )
 
    tryRegister( client.playerinfo.nick )

    client.update( 4000 )
    client.hook = hook.update("MULTIPLAYER_CLIENT_UPDATE")
end

function enterMultiplayer()
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
    player.commClose()
    if press then
        hail_pressed = true
    elseif hail_pressed then
        message = tk.input("COMMUNICATION", 0, 32, "Broadcast:")
        if message and message:len() > 0 then
            safe_send( common.SEND_MESSAGE .. '\n' .. message )
        end
    end
    if not player.pilot():target() then
        last_resync = 300
    end
end


MP_INPUT_HANDLERS.weapset7 = activate_outfits
MP_INPUT_HANDLERS.weapset8 = activate_outfits
MP_INPUT_HANDLERS.weapset9 = activate_outfits

MULTIPLAYER_CLIENT_UPDATE = function() return client.update() end
function MULTIPLAYER_CLIENT_INPUT ( inputname, inputpress, args)
    if MP_INPUT_HANDLERS[inputname] then
        MP_INPUT_HANDLERS[inputname]( inputpress, args )
    end
    if not TEMP_FREEZE then
        soft_sync = 999
    end
end

return client
