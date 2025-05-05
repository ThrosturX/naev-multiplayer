--
-- luacheck: globals MULTIPLAYER_SERVER_UPDATE MULTIPLAYER_ROUND_TIMER MULTIPLAYER_CHILL_TIMER SEND_TEAM_ASSIGNMENT MULTIPLAYER_SCORE_KEEPER (Hook functions passed by name)
local common = require "multiplayer.common"
local enet = require "enet"
local fmt = require "format"
local pilotname = require "pilotname"
local mp_equip = require "equipopt.templates.multiplayer"
local ai_setup = require "ai.core.setup"

-- NOTE: This is a listen server
--  it can't play like a client, but it relays the simulation
local server = {}
--[[
        server.players = { player_id = pilot, ... }
        server.world_state = { player_id = player_info, ... }
  
        server.start()
        server.synchronize_player( peer, sender_info )
        server.update()
--]]

-- make sure a name is unique by adding random numbers until it is
local function shorten( name )
    local newname = name:sub(1, math.min(name:len(), 16))
    if server.players[name] then
        newname = shorten( newname .. tostring(rnd.rnd(1,999)) )
    end

    return newname
end

local function random_spawn_point( xmax, ymax )
    xmax = 400 or xmax
    ymax = 800 or ymax
    return vec2.new( rnd.rnd(-xmax, xmax), rnd.rnd(-ymax, ymax) )
end

local function pick_one(t)
    return t[rnd.rnd(1, #t)]
end

local function pick_key(t)
    local key_pool = {}
    for k, _v in pairs(t) do
        table.insert(key_pool, k)
    end
    return pick_one(key_pool)
end

local ship_choice_themes = {}

ship_choice_themes.default = {
    "Gawain",
    "Zebra",
    "Mule",
    "Shark",
    "Empire Shark",
    "Pirate Shark",
    "Koala",
    "Rhino",
    "Pirate Rhino",
    "Quicksilver",
    "Kestrel",
    "Pirate Kestrel",
    "Goddard",
    "Dvaered Goddard",
    "Empire Hawking",
    "Za'lek Mammon",
    "Za'lek Mephisto",
    "Sirius Providence",
    "Soromid Reaver",
    "Soromid Nyx",
    "Sirius Dogma",
    "Dvaered Retribution",
    "Pirate Starbridge",
    "Starbridge",
    "Vigilance",
    "Dvaered Vigilance",
    "Pacifier",
    "Empire Pacifier",
    "Empire Admonisher",
    "Pirate Admonisher",
    "Admonisher"
}

ship_choice_themes.small = {
    "Gawain",
    "Mule",
    "Shark",
    "Empire Shark",
    "Pirate Shark",
    "Sirius Fidelity",
    "Dvaered Ancestor",
    "Pirate Ancestor",
    "Ancestor",
    "Vendetta",
    "Empire Lancelot",
    "Lancelot"
}

ship_choice_themes.medium = {
    "Dvaered Ancestor",
    "Pirate Ancestor",
    "Pirate Phalanx",
    "Dvaered Phalanx",
    "Phalanx",
    "Pirate Starbridge",
    "Starbridge",
    "Vigilance",
    "Dvaered Vigilance",
    "Pacifier",
    "Empire Pacifier",
    "Empire Admonisher",
    "Pirate Admonisher",
    "Admonisher",
    "Soromid Reaver",
    "Pirate Vendetta",
    "Pirate Rhino",
    "Dvaered Vendetta",
    "Za'lek Sting",
    "Za'lek Demon"
}

ship_choice_themes.funny = {
    "Mule",
    "Rhino",
    "Koala",
    "Quicksilver",
    "Llama",
    "Gawain",
    "Hyena",
    "Pirate Hyena",
    "Drone (Hyena)",
    "Za'lek Heavy Drone",
    "Shark",
    "Pirate Shark",
    "Empire Shark",
    "Pirate Rhino",
    "Ancestor",
    "Schroedinger",
}

ship_choice_themes.large = {
    "Pirate Kestrel",
    "Kestrel",
    "Goddard",
    "Hawking",
    "Dvaered Retribution",
    "Dvaered Arsenal",
    "Empire Rainmaker",
    "Soromid Nyx",
}

ship_choice_themes.large_special = {
    "Dvaered Goddard",
    "Empire Hawking",
    "Sirius Dogma",
    "Za'lek Mephisto",
    "Soromid Ira",
}

local ship_theme = "default"
local SHIPS = ship_choice_themes[ship_theme]

local function _sanitize_name( suggest )
    local word = suggest:match( "%w+" )
    return word or "SuspiciousPlayer"
end

local function ok_shiptype ( shiptype )
    if pcall( function() ship.get(shiptype) end ) then
        return true
    else
        return false
    end
end

local MAX_NPCS = 8
-- spawn an NPC
local function createNpc( shiptype, force )
    local count = 0
    for _a, _b in pairs(server.npcs) do
        count = count + 1
        if count >= MAX_NPCS and not force then
            print("INFO: Canceling NPC creation, limit reached.")
            return
        end
    end
    shiptype = shiptype or SHIPS[rnd.rnd(1, #SHIPS)]
    if not ok_shiptype(shiptype) then
        shiptype = "Za'lek Hephaestus" -- SHIPS[rnd.rnd(1, #SHIPS)]
    end
    local newnpc = {}
    newnpc.nick = _sanitize_name(pilotname.human():gsub(" ", "t"):gsub("'", "ek"))
    server.npcs[newnpc.nick] = true
    local newfac = faction.dynAdd("Independent", "NPC" .. tostring(rnd.rnd(0,349)), "NPC", { ai="mercenary", clear_allies = true, clear_enemies = true } )
    server.players[newnpc.nick] = pilot.add(
        shiptype,
        newfac,
        random_spawn_point(),
        newnpc.nick,
        { naked = true }
    )
    mp_equip( server.players[newnpc.nick] )
    server.playerinfo[newnpc.nick] = {}
    pmem = server.players[newnpc.nick]:memory()
    pmem.norun = true

    hook.pilot(
        server.players[newnpc.nick],
        "death",
        "MULTIPLAYER_SCORE_KEEPER"
    )

    return newnpc.nick
end

local function assignPilotToPlayer( playerID, new_ship )
    local mplayerfaction = faction.dynAdd(
        nil, "Multiplayer", "Multiplayer",
        { ai = "remote_control", clear_allies = true, clear_enemies = true }
    )
    server.players[playerID] = pilot.add(
        new_ship,
        mplayerfaction,
        random_spawn_point(),
        playerID,
        { naked = true }
    )
    mp_equip( server.players[playerID] )
    ai_setup.setup( server.players[playerID] )
    server.playerinfo[playerID] = {}
    hook.pilot(
        server.players[playerID],
        "death",
        "MULTIPLAYER_SCORE_KEEPER"
    )
end

local function reshipPlayer( playerID, new_ship )
    if playerID == server.hostnick then
        return
    end
    if server.players[playerID] and server.players[playerID]:exists() then
        server.players[playerID]:rm()
    end
    if
        server.npcs[playerID]
    then
        if server.players[playerID]:exists() then
            server.players[playerid]:rm()
        end
        server.players[playerID] = nil
        server.npcs[playerID] = nil
        server.playerinfo[playerID] = nil
        createNpc( new_ship, true )
        return
    else
        server.players[playerID] = nil
        return assignPilotToPlayer( playerID, new_ship )
    end
end

local REGISTRATIONS = {}
-- registers a player, returns the players unique ID
local function registerPlayer( playernicksuggest, shiptype, outfits )
    playernicksuggest = _sanitize_name( playernicksuggest )
    if server.players[playernicksuggest] then
        -- prevent double registration
          return nil
    end
    -- create a unique registration ID
    local playerID = shorten( playernicksuggest )

    -- spawn the pilot server-side
    if playernicksuggest == server.hostnick then
        server.players[playerID] = player.pilot()
    else
        print("ADDING PLAYER " .. playerID )
        local new_ship = ship_choice_themes.small[rnd.rnd(1, #ship_choice_themes.small)] -- SHIPS[rnd.rnd(1, #SHIPS)]
        assignPilotToPlayer( playerID, new_ship )
    end
    createNpc( "Cargo Shuttle" )

    REGISTRATIONS[playerID] = { ship = shiptype, outfits = outfits }

    return playerID
end

-- sends a message IFF we have a defined handler to receive it
local function sendMessage( peer, key, data, reliability )
    if not common.receivers[key] then
        print("error: " .. tostring(key) .. " not found in MSG_KEYS.")
        return nil
    end
    reliability = reliability or "unsequenced"

    local message = fmt.f( "{key}\n{msgdata}\n", { key = key, msgdata = data } )
    if peer:state() ~= "connected" then
        print("error: REFUSING TO SERVICE PEER IN STATE: " .. peer:state() )
        return nil
    end
    return peer:send( message, 0, reliability )
end

local function broadcast( key, data, reliability )
    if not common.receivers[key] then
        print("error: " .. tostring(key) .. " not found in MSG_KEYS.")
        return nil
    end

    reliability = reliability or "unsequenced"

    local message = fmt.f( "{key}\n{msgdata}\n", { key = key, msgdata = data } )
    return server.host:broadcast( message, 0, reliability )
end

local MESSAGE_HANDLERS = {}

-- REGISTERED maps peer:index() to player_id
local REGISTERED = {}
local function is_registered( player_id )
    for pindex, plid in pairs(REGISTERED) do
        if plid == player_id then
            return true
        end
    end
    return false
end
-- get the peer from a player id
local function get_peer( player_id )
    for pindex, plid in pairs(REGISTERED) do
        if
            plid == player_id 
        then
            local some_peer = server.host:get_peer(pindex)
            if
                some_peer
                and some_peer:state() == "connected"
            then
                return some_peer
            end
        end
    end
    return nil
end
-- player wants to join the server
MESSAGE_HANDLERS[common.REQUEST_KEY] = function ( peer, data )
    -- peer wants to register as <data>[1] in <data>[2]
    if data and #data >= 2 then
        local player_id = registerPlayer(data[1], data[2], common.unmarshal_outfits(data) )
        if player_id then
            -- ACK: REGISTERED <player_id>
            print("REGISTERED <" .. player_id .. "> in a " .. tostring(data[2]))
            sendMessage( peer, common.REGISTRATION_KEY, player_id, "reliable" )
            REGISTERED[peer:index()] = player_id
            return
        end
    end
    if peer:state() == "connected" then
        peer:send("ERROR: This nickname is reserved, please reconnect with another name or wait until the nickname is no longer in use.")
    end
end

local resync_players = {}
local context_sync = {}
local context_limit = 16
-- player wants to sync
MESSAGE_HANDLERS[common.REQUEST_UPDATE] = function ( peer, data )
    -- peer just wants an updated world state
    local player_id
    if #data >= 1 then
        player_id = data[1]:match( "%w+" )
        -- before we do anything, let's make sure we didn't already update this player recently
        if context_sync[player_id] == nil then
            context_sync[player_id] = 0
        elseif context_sync[player_id] > context_limit then
            print(fmt.f("INFO: player with id {mpid} already received too many updates in this context at {val}", { mpid = player_id, val=context_sync[player_id] } ))
            context_sync[player_id] = context_sync[player_id] + 1 -- increment counter for debug message
            return
        else
            -- we now assume the player will be updated in this context
            context_sync[player_id] = context_sync[player_id] + 1
        end

      --print("player'id: " .. player_id)
        if player_id and server.players[player_id] then
            -- update pilots
            local known_pilots = {}
            known_pilots[player_id] = true
            for ii, line in ipairs( data ) do
                if ii > 1 then
                    for opid, opship in string.gmatch(line, "(%w+)=([%w|%s|']+)") do
                        if
                            server.players[opid]    -- we know this pilot
                            and server.players[opid]:exists()   -- it exists
                            and opship == server.players[opid]:ship():nameRaw() -- the ship is correct
                        then
                            known_pilots[opid] = true
                        end
                    end
                end
            end

            for opid, opplt in pairs( server.players ) do
                -- need to synchronize creation of a new pilot
                if not known_pilots[opid] then
                    if opplt:exists() then
                       local message_data = fmt.f(
                           "{opid}\n{ship_type}\n{outfits}\n",
                           {
                               opid = opid,
                               ship_type = opplt:ship():nameRaw(),
                               outfits = common.marshal_outfits( opplt:outfitsList() ),
                           }
                       )
                       if server.npcs[opid] then
                           sendMessage( peer, common.ADD_NPC, message_data )
                       elseif opid ~= server.hostnick then
                           sendMessage( peer, common.ADD_PILOT, message_data, "reliable" )
                       end
                    else
                       -- player is dead
                        resync_players[opid] = 99
                    end
                end
            end

            -- synchronize this players info
            local in_sync = server.synchronize_player( peer, data[1] )
            local reliability = "unreliable"
            if not in_sync then
                reliability = "reliable"
            end

            -- send this player the requested world state
            sendMessage( peer, common.RECEIVE_UPDATE, server.world_state, reliability )
            return
        end
    end
    local emsg
    if not player_id then
        emsg =  "ERROR: Unsupported operation 2: Please use a valid nickname." 
    elseif not server.players[player_id] then
        emsg =  "ERROR: Unsupported operation 3: Please register before attempting to synchronize." 
        peer:disconnect()
        return
    end
    if peer:state() == "connected" then
        peer:send( emsg  )
    end
    print( emsg )
    for k,v in pairs( data ) do
        print(tostring(k) .. ": " .. tostring(v))
    end
end

MESSAGE_HANDLERS[common.SEND_MESSAGE] = function ( peer, data )
    -- peer wants to broadcast <data>[1] as a message
    if data and #data >= 1 then
        -- cheats section
        local secret = data[1]:match("[%w|_]+")
        if secret and ship_choice_themes[secret] then
            SHIPS = ship_choice_themes[secret]
        end
        local plid = REGISTERED[peer:index()]
        if server.players[plid] then
            local message =  data[1] .. '\n' .. server.players[plid]:name()
            return broadcast( common.SEND_MESSAGE, message )
        end
    end
end

local function toggleOutfit( plid, message, on )
    if #message >= 2 then
        local playerID
        for ii, activated_line in ipairs( message ) do
            if ii == 1 then
                playerID = activated_line
                if plid ~= playerID then
                    print("WARNING: Peer trying to activate wrong person's outfit: " .. tostring(plid))
                    return
                end
                resync_players[plid] = -30
            else    -- don't fully trust the client
                outf = activated_line
                clplt = server.players[playerID]
                if on then
                    print(fmt.f("{pilot} wants to activate {outfit}", { pilot=tostring(clplt), outfit=tostring(outf) } ))
                end
                if clplt and clplt:exists() then
                    local memo = clplt:memory()._o
                    if memo then
                    --  for ii, mm in pairs(memo) do
                    --      print(fmt.f("memo {ii}={mm}", { ii = ii, mm = mm } ) )
                    --  end
                        local outno = memo[outf]
                        if outno then
                            clplt:outfitToggle(outno, on)
                        end
                        if on then
                            print("activate " .. tostring(outno))
                        --  for kk, vv in pairs(clplt:outfits()) do
                        --      print(fmt.f("{kk}: {vv}", { kk=kk, vv=vv } ) )
                        --  end
                        end
                    end
                end
            end
        end
    end
end

local function outfit_handler ( peer, data )
    if data and #data >= 2 then
        local plid = REGISTERED[peer:index()]
        local activedata = ''
        for ii, dline in ipairs( data ) do
            activedata = activedata .. dline .. '\n'
        end
        if plid == data[1] then
            return server.host:broadcast( common.ACTIVATE_OUTFIT .. '\n' .. activedata, 0, "unreliable" )
        end
    end
end

MESSAGE_HANDLERS[common.ACTIVATE_OUTFIT] = function ( peer, data )
    local plid = REGISTERED[peer:index()]
    if not plid then
        print("Peer registration not found for peer #" .. tostring(peer:index()))
        for pk, pv in pairs(REGISTERED) do
            print(fmt.f("{pk}: {pv}", {pk=pk, pv=pv}))
        end
    end
    toggleOutfit( plid, data , true )
    return outfit_handler( peer, data )
end
MESSAGE_HANDLERS[common.DEACTIVATE_OUTFIT] = function ( peer, data )
    local plid = REGISTERED[peer:index()]
    if not plid then
        print("Peer registration not found for peer #" .. tostring(peer:index()))
        for pk, pv in pairs(REGISTERED) do
            print(fmt.f("{pk}: {pv}", {pk=pk, pv=pv}))
        end
    end
    toggleOutfit( plid, data , false )
    return outfit_handler( peer, data)
end

local handled_frame = {}

local function handleMessage ( event )
    local msg_type
    local msg_data = {}
    for line in event.data:gmatch("[^\n]+") do
        if not msg_type then
            msg_type = line
        else
            table.insert(msg_data, line)
        end
    end

    if handled_frame[event.peer:index()] == msg_type then
        print( "Already handled a " .. msg_type .. " from peer " .. tostring(event.peer:index()) )
    end
    handled_frame[event.peer] = msg_type

    return MESSAGE_HANDLERS[msg_type]( event.peer, msg_data )
end

-- start a new listenserver
server.start = function( port )
    if player.isLanded() then
        return "ERROR_SERVER_LANDED"
    end
    if not port then port = 6789 end
    server.host = enet.host_create( fmt.f( "*:{port}", { port = port } ) )
    local message = "SERVER IS RUNNING ON: " .. server.host:get_socket_address()
    print( message )
    player.omsgAdd( "#b"..message.."#0" )
    pilot.comm( "SERVER INFO", "#y" .. message .. "#0" )
    if server.host then
        server.players     = {}
        server.npcs        = {}
        server.playerinfo  = {}
        -- go to multiplayer system
        player.teleport("Multiplayer Lobby")
        -- register yourself
        server.hostnick = player.name():gsub(' ', '')
        -- registerPlayer( server.hostnick, player:pilot():ship():nameRaw() , player:pilot():outfitsList() )
        -- update world state with yourself (weird)
        server.world_state = server.refresh()

        server.hook = hook.update("MULTIPLAYER_SERVER_UPDATE")
        server.pinghook = hook.timer(1, "MULTIPLAYER_SYNC_UPDATE")
        server.chill = hook.timer(30, "MULTIPLAYER_CHILL_TIMER")
        server.round = hook.timer(10, "MULTIPLAYER_ROUND_TIMER")
        server.inputhook = hook.input("MULTIPLAYER_UNPAUSE")
        -- borrow client hook to update cache variables
        --server.inputhook = hook.input("MULTIPLAYER_CLIENT_INPUT")
        player.pilot():setNoDeath( true )    -- keep the server running
        player.pilot():setInvincible( true ) -- keep the server running
        player.pilot():setInvisible( true )  -- keep the npcs from chasing the server

        player.cinematics(
            false,
            {
                abort = _("Autonav disabled in multiplayer."),
                no2x = true,
                gui = false
            }
        )
    end
end

local FPS = 60
-- synchronize one player update after receiving
server.synchronize_player = function( peer, player_info_str )
  --print( player_info_str )
    local frames_passed = peer:round_trip_time() / (1000 / FPS)
    local ppinfo = common.unmarshal( player_info_str )
    local ppid = ppinfo.id
    --print("sync player " .. ppid .. " to health " .. tostring(ppinfo.armour) )
    if ppid and server.players[ppid] and server.players[ppid]:exists() then
        -- sync direction always
        server.players[ppid]:setDir(ppinfo.dir)
        -- validation
        local dist2 = vec2.dist2(
            vec2.new(tonumber(ppinfo.posx), tonumber(ppinfo.posy)),
            server.players[ppid]:pos()
        )
        local stats = server.players[ppid]:stats()
        local fudge = 16
        local speed2 = math.min(
            stats.speed_max * stats.speed_max,
            (math.abs(ppinfo.velx) + fudge) * (math.abs(ppinfo.vely) + fudge)
        ) * 3
        local mdiff = (
            math.abs( vec2.new( math.abs(ppinfo.velx) + fudge, math.abs(ppinfo.vely) + fudge):mod() * fudge ) + fudge 
        ) * frames_passed
        if dist2 >= speed2 or dist2 > (mdiff * mdiff) then
            print("WARNING: Refusing to synchronize player " .. ppid)
            local rsp = resync_players[ppid]
            if not rsp then
                resync_players[ppid] = 1
                return false
            elseif rsp < 2 then
                resync_players[ppid] = rsp + 1
                return false
            end
            resync_players[ppid] = nil
            --[[
            if rnd.rnd(0, 160) == 0 then
                common.sync_player( ppid, ppinfo, server.players )
            end
            server.players[ppid]:setHealth(ppinfo.armour - 1, ppinfo.shield, ppinfo.stress + 1)
            ]]--
            -- respawn the player in the right ship
            local message_data = fmt.f(
               "{ppid}\n{ship_type}\n{outfits}\n",
               {
                   ppid = ppid,
                   ship_type = server.players[ppid]:ship():nameRaw(),
                   outfits = common.marshal_outfits( server.players[ppid]:outfitsList() ),
               }
            )
            sendMessage( peer, common.ADD_PILOT, message_data, "reliable" )
            local syncline = fmt.f(
                "{ppid} {energy} {heat} {armour} {shield} {stress}",
                {
                    ppid = ppid,
                    energy = 5,
                    heat = 250,
                    armour = 100,
                    shield = 80,
                    stress = 0,
                }
            )
            sendMessage( peer, common.SYNC_PLAYER, syncline, "reliable" )
            server.players[ppid]:fillAmmo()
            return false
        else
            -- server side sync
            server.players[ppid]:setPos(vec2.new(tonumber(ppinfo.posx), tonumber(ppinfo.posy)))
            server.players[ppid]:setVel(vec2.new(tonumber(ppinfo.velx), tonumber(ppinfo.vely)))
          --server.players[ppid]:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
        end
        server.playerinfo[ppid] = ppinfo
        
        -- server authority on health
        local armour, shield, stress = server.players[ppid]:health()
        ppinfo.armour = armour
        ppinfo.shield = shield
        ppinfo.stress = stress
        local syncline = fmt.f(
            "{ppid} {energy} {heat} {armour} {shield} {stress}",
            {
                ppid = ppid,
                energy = server.players[ppid]:energy(),
                heat = server.players[ppid]:temp(),
                armour = armour,
                shield = shield,
                stress = stress,
            }
        )
        if ppinfo.armour > armour * 1.02 or ppinfo.shield > shield * 1.02 or math.abs(ppinfo.stress - stress) > 8 then
            broadcast( common.SYNC_PLAYER, syncline, "unreliable" )
        elseif math.abs(rnd.threesigma()) >= 2.5 then
            sendMessage( peer, common.SYNC_PLAYER, syncline, "reliable" )
        end
        common.sync_player( ppid, ppinfo, server.players )
        server.players[ppid]:fillAmmo()
    end
    if resync_players[ppid] then
        resync_players[ppid] = nil
    end
    return true
end

server.refresh = function()
    handled_frame = {}
    local world_state = ""

    for nid, _bool in pairs(server.npcs) do
        local pplt = server.players[nid]
        if pplt and pplt:exists() then
            local accel = 1
            local primary = 0
            local secondary = 0
            local target = pplt:target()
            if target then
              server.playerinfo[nid].target = target:name()
              server.playerinfo[nid].accel = rnd.rnd()
              server.playerinfo[nid].primary = rnd.rnd(0, 1)
              server.playerinfo[nid].secondary = rnd.rnd(0, 1)
            end
        else    -- spawn a new one :)
            server.npcs[nid] = nil
            createNpc()
            -- create a record of it being definitely dead "this frame"
            -- this shouldn't be necessary but might help later
            local syncline = fmt.f(
                "{ppid} {energy} {heat} {armour} {shield} {stress}",
                {
                    ppid = nid,
                    energy = 0,
                    heat = 750,
                    armour = 0,
                    shield = 0,
                    stress = 100,
                }
            )
            broadcast( common.SYNC_PLAYER, syncline, "unreliable" )
            server.playerinfo[nid] = nil
        end
    end


    server.players[server.hostnick] = player.pilot()
    for ppid, pplt in pairs(server.players) do
        if ppid ~= server.hostnick then
            if pplt:exists() then
                local accel = 0
                local primary = 0
                local secondary = 0
                local target = server.hostnick
                if server.playerinfo[ppid] then
                   if server.playerinfo[ppid].accel then
                      accel = server.playerinfo[ppid].accel
                   end
                   if server.playerinfo[ppid].primary then
                      primary = server.playerinfo[ppid].primary
                   end
                   if server.playerinfo[ppid].secondary then
                      secondary = server.playerinfo[ppid].secondary
                   end
                   if server.playerinfo[ppid].target then
                       target = server.playerinfo[ppid].target
                    end
                end
                local armour, shield, stress = pplt:health()
                local velx, vely = pplt:vel():get()
                local posx, posy = pplt:pos():get()
                world_state = world_state .. fmt.f("{id} {posx} {posy} {dir} {velx} {vely} {armour} {shield} {stress} {accel} {primary} {secondary} {target}\n", {
                    id = ppid,
                    posx = posx,
                    posy = posy,
                    dir = pplt:dir(),
                    velx = velx,
                    vely = vely,
                    armour = armour,
                    shield = shield,
                    stress = stress,
                    accel = accel,
                    primary = primary,
                    secondary = secondary,
                    target = target,
                })
            else -- it died
                print("INFO: Player is dead: " .. tostring(ppid) )
                server.players[ppid]    = nil
                server.npcs[ppid]       = nil
                server.playerinfo[ppid] = nil
            end
        end
    end

    server.world_state = world_state

    --  print("_________________")
    --  print("WORLD STATE START")
    --  print("~~~~~~~~~~~~~~~~~")
    --  print(world_state)
    --  print("_________________")
    --  print("WORLD STATE  END ")
    return world_state
end

-- do I need to explain this?
local valid_contexts_per_second = 30
local max_context_frames = 0
local this_context_frames = 1
server.update = function ()
    player.autonavReset()
--    synchronize the server peer
--    server.synchronize_player ( common.marshal_me( player.name() ) )
    -- refresh our world state before updating clients
    server.refresh()

    -- validate the current context
    if this_context_frames >= max_context_frames then
        -- clear the context
        for cplid, _val in pairs(context_sync) do
            context_sync[cplid] = nil
        end
        -- calculate next context window
        max_context_frames = naev.fps() / valid_contexts_per_second
        this_context_frames = 1
    else
        -- increment the counter
        this_context_frames = this_context_frames + 1
    end

    -- handle requests from clients
    local event = server.host:service()
    while event do
        if event.type == "receive" then
            handleMessage( event )
        elseif event.type == "connect" then
            print(event.peer, " connected.")
            -- reserve an ID? nah...
        elseif event.type == "disconnect" then
            print(event.peer, " disconnected.")
            -- clean up
            local dc_player = REGISTERED[event.peer:index()]
            if dc_player then
                if server.players[dc_player] and server.players[dc_player]:exists() then
                    server.players[dc_player]:rm()
                end
                server.players[dc_player] = nil
                REGISTERED[event.peer:index()] = nil
            end
        else
            print(fmt.f("Received unknown event <{type}> from {peer}:", event))
            for kk, vv in pairs(event) do
                print("\t" .. tostring(kk) .. ": " .. tostring(vv))
            end
        end
        event = server.host:service()
    end
end

server.check_players = function ()
    for ppid, pplt in pairs(server.players) do
        if pplt:exists() then
            local p_ship = pplt:ship():nameRaw()
            local peer = get_peer(ppid)
            if peer and pplt:exists() then
                sendMessage( peer, common.CHECK_SYNC, p_ship, "unreliable" )
            end
        end
    end
    local timer_sec = 3
    server.pinghook = hook.timer(timer_sec, "MULTIPLAYER_SYNC_UPDATE")

end

MULTIPLAYER_SERVER_UPDATE = function() return server.update() end

MULTIPLAYER_SYNC_UPDATE = function () return server.check_players() end

local CHILL_SONGS = {
    "snd/sounds/songs/feeling-good-05.ogg",
    "snd/sounds/songs/feeling-good-08.ogg",
    "snd/sounds/songs/mushroom-background.ogg",
    "snd/sounds/songs/run-for-your-life-00.ogg",
    "snd/sounds/songs/space-exploration-08.ogg",
    "snd/music/flf_battle1.ogg",
    "snd/music/automat.ogg",
    "snd/music/battlesomething1.ogg",
    "snd/music/battlesomething2.ogg",
    "snd/music/collective1.ogg",
    "snd/music/collective2.ogg",
    "snd/music/combat1.ogg",
    "snd/music/combat2.ogg",
    "snd/music/combat3.ogg",
    "snd/music/empire1.ogg",
  --"snd/music/dvaered1.ogg",
  --"snd/music/dvaered2.ogg",
}

function MULTIPLAYER_CHILL_TIMER ()
    for _plid, mpplt in pairs(server.players) do
        if mpplt and mpplt:exists() then
            mpplt:fillAmmo()
            mpplt:setTemp( 250, true )
        end
    end
    local next_chill = rnd.rnd(30, 90)
    server.chill = hook.timer(next_chill, "MULTIPLAYER_CHILL_TIMER")
    if false then
        local chill_song = CHILL_SONGS[rnd.rnd(1, #CHILL_SONGS)]
        broadcast(
            common.PLAY_MUSIC,
            chill_song,
            "reliable"
        )
        print("serving guests with " .. chill_song)
    end
end

local ROUND_SOUND = "snd/sounds/jingles/victory.ogg"
local round_types = {}
local round_times = {
    freeforall = { 20, 30, 45, 50 },
    deathmatch = { 90, 60, 75, 80 },
    team_death = { 120, 60, 100 },
    coopvsnpcs = { 45, 60, 85 },
    uniformall = { 60, 90, 120 },
    cowboysone = { 60, 90, 120 },
    cowboystwo = { 60, 90, 120 },
    cowindians = { 60, 90, 120 },
    scorefight = { 120 },
    scorefite2 = { 120 },
    registered = { 88, 99 }
}
round_types.freeforall = function () 
    local mpsystem = "Multiplayer Lobby"
    --player.teleport(mpsystem)
    broadcast( common.TELEPORT, mpsystem, "reliable" )
    -- just give everyone a random ship
    for plid, _reg in pairs(REGISTRATIONS) do
        local new_ship = SHIPS[rnd.rnd(1, #SHIPS)]
        reshipPlayer( plid, new_ship ) 
    end
    ROUND_SOUND = "snd/sounds/jingles/victory.ogg"
    SHIPS = ship_choice_themes.default
    local next_choice = rnd.rnd(0, 2)
    if next_choice == 0 then
        return "deathmatch"
    elseif next_choice == 1 then
        return "team_death"
    elseif next_choice == 2 then
        return "coopvsnpcs"
    end
end
round_types.deathmatch = function ( silent ) 
    -- give everyone a random from the same class
    local choice = rnd.rnd(1, 5)
    if choice == 1 then
        player_ships = ship_choice_themes.medium
        SHIPS = ship_choice_themes.small
    elseif choice == 2 then
        player_ships = ship_choice_themes.large
        SHIPS = ship_choice_themes.medium
    elseif choice == 3 then
        player_ships = ship_choice_themes.funny
        SHIPS = player_ships
    elseif choice == 4 then
        player_ships = ship_choice_themes.large_special
        SHIPS = ship_choice_themes.large
    else
        player_ships = ship_choice_themes.default
        SHIPS = player_ships
    end

    local touched = {}
    for plid, pplt in pairs(server.players) do
        local new_ship = player_ships[rnd.rnd(1, #player_ships)]
        reshipPlayer( plid, new_ship ) 
        touched[plid] = true
    end

    for plid, pplt in pairs(REGISTRATIONS) do
        if not touched[plid] then
            local new_ship = player_ships[rnd.rnd(1, #player_ships)]
            reshipPlayer( plid, new_ship ) 
        end
    end

    if silent then
        return
    end

    local mpsystem = "Multiplayer Arena"
    broadcast( common.TELEPORT, mpsystem, "reliable" )

    ROUND_SOUND = "snd/sounds/jingles/victory.ogg"

    local choice = rnd.rnd(0, 3)
    if choice == 0 then
        return "freeforall"
    elseif choice == 1 then
        return "team_death"
    end
    return "deathmatch"
end
--[[
--  split all players into 2 groups and team-balance with NPC
--  teleport group A into blue system and group B into pink system
--  (client side only, so they know what team they are)
--  set team A friendly to A and hostile to B and vice versa
--]]
local LAST_TEAMS
round_types.team_death = function ()
    -- kill all the npcs
    for nid, _true in pairs(server.npcs) do
        local npcplt = server.players[nid]
        if npcplt and npcplt:exists() then
            local syncline = fmt.f(
                "{ppid} {energy} {heat} {armour} {shield} {stress}",
                {
                    ppid = nid,
                    energy = 0,
                    heat = 750,
                    armour = 0,
                    shield = 0,
                    stress = 100,
                }
            )
            broadcast( common.SYNC_PLAYER, syncline, "unreliable" )
            npcplt:rm()
            server.npcs[nid] = nil
            server.players[nid] = nil
            server.playerinfo[nid] = nil
        end
    end

    -- start balancing teams
    local teams = {}
    teams.blue = {}
    teams.pink = {}
    local next_team = function ()
        if #teams.blue > #teams.pink then
            return teams.pink
        end
        return teams.blue
    end
    for plid, pplt in pairs(server.players) do
        if plid ~= server.hostnick and not server.npcs[plid] then
            table.insert(next_team(), plid)
        end
    end

    if #teams.blue ~= #teams.pink then
        local balancer = createNpc()
        table.insert(teams.pink, balancer)
    end

    -- consider teams fair

    for color, the_team in pairs( teams ) do
        -- build the team info
        local teaminfo = color
        local xx = 3000
        local target = "Somal's Ship Cemetery"
        if color ~= "blue" then
            xx = -3000
            target = "Pyro's Pink Slip Storage"
        end
        for _j, tplid in ipairs(teams[color]) do
            -- this might be a slow and unnecessary check
            local found_peer = get_peer(tplid)
            if found_peer then
                teaminfo = teaminfo .. '\n' .. tplid
                sendMessage(
                    found_peer,
                    common.TELEPORT,
                    target,
                    "reliable"
                )
            end
            if
                server.players[tplid]
                and server.players[tplid]:exists()
            then
                server.players[tplid]:setPos(
                    vec2.new(
                        xx, rnd.rnd(-500, 500)
                    )
                )
            end
        end
        the_team.teaminfo = teaminfo
        -- send the team info
        hook.timer(3, "SEND_TEAM_ASSIGNMENT", the_team)
    end

    TEAMS = teams

    -- reuse deathmatch for ship selection
    round_types.deathmatch( true )

    ROUND_SOUND = "snd/sounds/jingles/success.ogg"

    if rnd.rnd(0, 1) == 0 then
        if num_players() >= 4 then
            return "team_death"
        end
        return "deathmatch"
    end
    return "freeforall"
end

function SEND_TEAM_ASSIGNMENT( the_team )
    for _j, tplid in ipairs(the_team) do
        local player_peer = get_peer(tplid)
        if player_peer then
            -- send the team information
            sendMessage(
                player_peer,
                common.ASSIGN_TEAM,
                the_team.teaminfo,
                "unsequenced"
            )
        elseif not server.npcs[tplid] then
            local badplt = server.players[tplid]
            if badplt and badplt:exists() then
                badplt:rm()
            end
            server.players[tplid] = nil
            print("Couldn't find the peer for " .. tplid )
        end
    end

end

round_types.coopvsnpcs = function ()
    local mpsystem = "Somal's Ship Cemetery"
    --player.teleport(mpsystem)
    broadcast( common.TELEPORT, mpsystem )
    local npc_ships = ship_choice_themes.large
    local player_ships
    local choice = rnd.rnd(1, 3)
    if choice == 1 then
        player_ships = ship_choice_themes.small
    elseif choice == 2 then
        player_ships = ship_choice_themes.medium
    elseif choice == 3 then
        player_ships = ship_choice_themes.funny
    end
    for plid, pplt in pairs(server.players) do
        local new_ship
        if not server.npcs[plid] then
            new_ship = player_ships[rnd.rnd(1, #player_ships)]
        else
            new_ship = npc_ships[rnd.rnd(1, #npc_ships)]
        end
        reshipPlayer( plid, new_ship ) 
    end
    SHIPS = ship_choice_themes.small
    ROUND_SOUND = "snd/sounds/meow.ogg"
    return "freeforall"
end

round_types.uniformall = function ()
    local mpsystem = pick_one(
        {
            "Somal's Ship Cemetery",
            "Pyro's Pink Slip Storage",
            "Multiplayer Arena",
            "Multiplayer Lobby",
        }
    )
    broadcast( common.TELEPORT, mpsystem )
    local theme = pick_key(ship_choice_themes)
    local ships = pick_one(ship_choice_themes[theme])
    SHIPS = { ships }
    for plid, pplt in pairs(server.players) do
        reshipPlayer( plid, ships )
    end
    ROUND_SOUND = "snd/sounds/ping.ogg"
    return "coopvsnpcs"
end

round_types.cowboysone = function ()
    local mpsystem = pick_one(
        {
            "Somal's Ship Cemetery",
            "Multiplayer Arena",
            "Multiplayer Lobby",
        }
    )
    broadcast( common.TELEPORT, mpsystem )
    local theme = pick_key(ship_choice_themes)
    local ship1 = pick_one(ship_choice_themes[theme])
    local ship2 = pick_one(ship_choice_themes[theme])
    SHIPS = { ship1, ship2 }
    for plid, pplt in pairs(server.players) do
        reshipPlayer( plid, pick_one(SHIPS) )
    end
    ROUND_SOUND = "snd/sounds/wormhole.ogg"
    return "cowboystwo"
end

round_types.cowboystwo = function ()
    local mpsystem = pick_one(
        {
            "Multiplayer Arena",
            "Multiplayer Lobby",
        }
    )
    broadcast( common.TELEPORT, mpsystem )
    local them1 = pick_key(ship_choice_themes)
    local them2 = pick_key(ship_choice_themes)
    local ship1 = pick_one(ship_choice_themes[them1])
    local ship2 = pick_one(ship_choice_themes[them2])
    SHIPS = { ship1, ship2 }
    for plid, pplt in pairs(server.players) do
        reshipPlayer( plid, pick_one(SHIPS) )
    end
    ROUND_SOUND = "snd/sounds/spacewhale1.ogg"
    return "cowindians"
end

round_types.cowindians = function ()
    local mpsystem = pick_one(
        {
            "Pyro's Pink Slip Storage",
            "Multiplayer Arena",
            "Multiplayer Lobby",
        }
    )
    broadcast( common.TELEPORT, mpsystem )
    local them1 = pick_key(ship_choice_themes)
    local them2 = pick_key(ship_choice_themes)
    local ship1 = pick_one(ship_choice_themes[them2])
    local ship2 = pick_one(ship_choice_themes[them2])
    local shoops = { ship1, ship2 }
    SHIPS = ship_choice_themes[them1]
    for plid, pplt in pairs(server.players) do
        reshipPlayer( plid, pick_one(shoops) )
    end
    ROUND_SOUND = "snd/sounds/spacewhale1.ogg"
    return "team_death"
end

round_types.registered = function ()
    for plid, reg in pairs(REGISTRATIONS) do
        reshipPlayer( plid, reg.ship )
        server.players[plid]:outfitRm( "all" )
        server.players[plid]:outfitRm( "cores" )
        for _i, outf in ipairs(reg.outfits) do
            server.players[plid]:outfitAdd( outf, 1, true )
        end
    end
    ROUND_SOUND = "snd/sounds/spacewhale2.ogg"
    return "cowindians"
end

local SCORES = {}
round_types.scorefight = function ()
    for plid, pplt in pairs(server.players) do
        local new_ship
        local score = SCORES[plid] or 1
        if score >= 20 then
            new_ship = pick_one(ship_choice_themes.large_special)
        elseif score >= 10 then
            new_ship = pick_one(ship_choice_themes.large)
        elseif score > 5 then
            new_ship = pick_one(ship_choice_themes.medium)
        else
            new_ship = pick_one(ship_choice_themes.small)
        end
        SCORES[plid] = math.max(1, score - ship.get(new_ship):size())
        reshipPlayer( plid, new_ship )
    end
    SHIPS = ship_choice_themes.medium
    ROUND_SOUND = "snd/sounds/jingles/money.ogg"
    return "freeforall"
end

round_types.scorefite2 = function ()
    for plid, pplt in pairs(server.players) do
        local new_ship
        local score = SCORES[plid] or 1
        if score >= 20 then
            new_ship = pick_one({
                "Dvaered Ancestor",
                "Dvaered Vendetta",
                "Pirate Ancestor",
                "Pirate Vendetta",
                "Ancestor",
                "Vendetta",
                "Phalanx",
                "Pirate Phalanx",
                "Dvaered Phalanx",
                "Sirius Preacher",
            })
            SCORES[plid] = math.max(1, score - ship.get(new_ship):size())
        elseif score >= 15 then
            new_ship = pick_one(ship_choice_themes.medium)
        elseif score > 7 then
            new_ship = pick_one({
                "Zebra",
                "Za'lek Mammon",
                "Sirius Providence",
                "Empire Rainmaker",
            })
        else
            new_ship = pick_one({
                "Mule",
                "Rhino",
                "Pirate Rhino"
            })
        end
        reshipPlayer( plid, new_ship )
    end
    SHIPS = ship_choice_themes.medium
    ROUND_SOUND = "snd/sounds/jingles/money.ogg"
    return "deathmatch"
end

local function num_players()
    local count = 0
    for ii, plid in pairs(server.players) do
        if not server.npcs[plid] and REGISTERED[plid] then
            count = count + 1
        end
    end
    return count
end

local CURRENT_MODE = "none"
function MULTIPLAYER_ROUND_TIMER ( round_type )
    if
        ( not round_type or not round_types[round_type] )
        or
        ( round_type == "team_death" and num_players() < 4 )
    then
        round_type = pick_one(
            {
                "freeforall",
                "deathmatch",
                "coopvsnpcs",
                "uniformall",
                "cowboysone",
                "registered"
            }
        )
    end
    CURRENT_MODE = round_type
    -- set up the new round
    local next_timer = pick_one(round_times[round_type]) or 60
    local next_round = round_types[round_type]()
    -- reposition, fill ammo and reset heat
    for plid, mpplt in pairs(server.players) do
        if mpplt and mpplt:exists() then
            if round_type ~= "team_death" then
                mpplt:setPos( random_spawn_point( 1000, 2000 ) )
            end
            mpplt:fillAmmo()
            mpplt:setTemp( 0 )
            if server.npcs[plid] then
                server.players[plid]:rm()
            else
                resync_players[plid] = 99
            end
        end
        if SCORES[plid] and SCORES[plid] >= 21 then
            next_round = pick_one({
                "scorefight",
                "scorefite2",
                "team_death",
                "coopvsnpcs",
                "uniformall",
                "registered"
            })
        end
    end
    -- set the hook for the next round
    server.round = hook.timer(next_timer, "MULTIPLAYER_ROUND_TIMER", next_round )
    broadcast(
        common.PLAY_SOUND,
        fmt.f(
            "{sound}\nStarting a new round of {round} #g({timer} seconds)",
            {
                sound = ROUND_SOUND,
                round = round_type,
                timer = next_timer
            }
        ),
        "unsequenced"
    )

    local round_song = CHILL_SONGS[rnd.rnd(1, #CHILL_SONGS)]
    broadcast(
        common.PLAY_MUSIC,
        round_song,
        "reliable"
    )
    print("serving guests with " .. round_song)
end

local function is_same_team(vname, aname)
    local vcolor, acolor
    for color, _team in pairs(TEAMS) do
        for _j, teamplayer in ipairs(TEAMS[color]) do
            if teamplayer == vname then
                vcolor = color
            elseif teamplayer == aname then
                acolor = color
            end
        end
    end

    return acolor == vcolor
end

function MULTIPLAYER_SCORE_KEEPER( victim, attacker, _dmg )
    if not attacker then
        return
    end
    local current_score = (SCORES[attacker:name()] or 0)
    local aname = attacker:name()
    if
        attacker and attacker:exists()
        and is_registered( aname )
    then
        local points = victim:ship():points() * 0.01
        if attacker:ship():size() < victim:ship():size() then
            points = points * 1.2
        end
        current_score = points + current_score
        local vname = victim:name()
        if (
            CURRENT_MODE == "coopvsnpcs" and is_registered(vname)
            ) or (
            CURRENT_MODE == "team_death" and is_same_team(vname, aname)
            )
        then
            -- team killers get punished, but never back into noob status
            current_score = math.max(1, current_score / 2 - 1)
        elseif SCORES[vname] then
            local vscore = math.min(0, SCORES[vname])
            if vscore >= 10 then
                SCORES[vname] = SCORES[vname] - (victim:ship():size() / 5)
                current_score = current_score + vscore / 10
            elseif vscore > 3 then
                current_score = current_score + 0.2
            end
        elseif is_registered(vname) then -- noob killing penalty
            current_score = current_score - 0.5
        end
        SCORES[aname] = current_score
    else
        return
    end

    if current_score < 1 then
        return
    end

    local score_sound = fmt.f(
        "snd/sounds/gambling/cardSlide{score}.ogg", { score = math.floor(current_score) }
    )

    if current_score > 8 then
        score_sound = fmt.f(
            "snd/sounds/gambling/chipsStack{score}.ogg", { score = 1 + math.floor(current_score - 8) % 6 }
        )
    end

    broadcast(
        common.PLAY_SOUND,
        fmt.f(
            "{sound}\n{mplayer}#b has a score of #r{score}",
            {
                sound = score_sound,
                mplayer = attacker,
                score = current_score
            }
        ),
        "unreliable"
    )
end

return server
