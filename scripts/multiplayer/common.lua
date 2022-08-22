local fmt = require "format"
local ai_setup = require "ai.core.setup"

--  each line is <player_id> <pos> <dir> <vel> <armour> <shield> <stress>
local function unmarshal( player_info )
    local nice_player = {
        id = player_info.id,

        posx = player_info.stats[1],
        posy = player_info.stats[2],
        dir = player_info.stats[3],
        velx = player_info.stats[4],
        vely = player_info.stats[5],

        armour = player_info.stats[6],
        shield = player_info.stats[7],
        stress = player_info.stats[8],
        accel = tonumber(player_info.stats[9]),
        primary = tonumber(player_info.stats[10]),
        secondary = tonumber(player_info.stats[11]),
--        weapset = player_info.stats[12],
        target = player_info.target
    }

--  print("UNMARSHALED A PLAYER INTO THIS:")
--  for k, v in pairs(nice_player) do
--      print("\t" .. tostring(k) .. ": " .. tostring(v))
--  end
-- print("____________________")

    return nice_player
end

local common = {}
common.REQUEST_KEY       = "IDENTIFY"
common.UNREGISTERED      = "UNREGISTERED"
common.REQUEST_UPDATE    = "SYNC_PILOTS"
common.RECEIVE_UPDATE    = "UPDATE"
common.SYNC_PLAYER       = "SYNC"
common.ADD_PILOT         = "SPAWN"
common.ADD_NPC           = "SPAWN_NPC"
common.REGISTRATION_KEY  = "REGISTERED"
common.ACTIVATE_OUTFIT   = "ACTIVATE"
common.DEACTIVATE_OUTFIT = "DEACTIVATE"
common.SEND_MESSAGE      = "MESSAGE"
common.PLAY_SOUND        = "SOUND"
common.TELEPORT          = "TELEPORT"
common.ASSIGN_TEAM       = "TEAM"
common.receivers = {}

--[[
--  Receive confirmation of server registration
--  REGISTERED <newname>
--]]
common.receivers[common.REGISTRATION_KEY] = function ( client, message )
    if message and #message == 1 then
        client.playerinfo.nick = message[1]
        client.registered = true
        client.alive = false
        print("YOU HAVE BEEN REGISTERED AS <" .. client.playerinfo.nick .. ">.")
    else
        print("FAILED TO REGISTER:")
        for k, v in pairs(message) do
            print("\t" .. tostring(k) .. ": " .. tostring(v))
        end
    end
end

--[[
--  Receive notice of lack of server registration
--  UNREGISTERED
--]]
common.receivers[common.UNREGISTERED] = function ( client, message )
    print("YOU ARE NOT REGISTERED! -- Attempting re-registration...")
    if message and #message == 1 then
        client.playerinfo.nick = message[1]
    end
    -- try to register
    if client.server:state() == "connected" then
        client.server:send(
            fmt.f(
                "{key}\n{nick}\n{ship}\n{outfits}\n",
                {
                    key = common.REQUEST_KEY,
                    nick = client.playerinfo.nick,
                    ship = client.playerinfo.ship,
                    outfits = client.playerinfo.outfits,
                }
            )
        )
    end
end

--[[
--  Spawn a new pilot
--  lines are: player_id, ship_type, outfits
--]]
common.receivers[common.ADD_PILOT] = function ( client, message )
    if #message >= 3 then
        return client.spawn( message[1], message[2], message[1], common.unmarshal_outfits(message) )
    else
        print("ERROR: Spawning pilot with too few parameters")
    end
end

--[[
--  Spawn a new NPC pilot
--  lines are: player_id, ship_type, outfits
--]]
common.receivers[common.ADD_NPC] = function ( client, message )
    if #message >= 3 then
        return client.spawn( message[1], message[2], message[1], common.unmarshal_outfits(message), "mercenary")
    else
        print("ERROR: Spawning NPC with too few parameters")
    end
end

local function parsePlayer( player_line )
    local this_player = {}
    this_player.stats = {}
    this_player.target = ""
    -- get the player id
    for match in player_line:gmatch("%w+") do
        if not this_player.id then
            this_player.id = match
        else
            this_player.target = match
        end
    end
    for playerstat in player_line:gmatch("-?%d+%.?%d*e?-?%d*") do
        table.insert( this_player.stats, tonumber(playerstat) )
    end
    return this_player
end

--[[
--  Receive an update about the world state
--  each line is <player_id> <pos> <dir> <vel> <armour> <shield> <stress>
--]]
common.receivers[common.RECEIVE_UPDATE] = function ( client, message )
    local world_state = {}
    world_state.players = {}
    for _ii, player_line in ipairs( message ) do
        local this_player = parsePlayer( player_line )
        world_state.players[this_player.id] = unmarshal( this_player )
    end

    return client.synchronize( world_state )
end

--[[
--  the server wants to synchronize some player stats
--  the line is <player_id> <energy> <heat> <armor> <shield> <stress>
--  also refills ammo
--]]
common.receivers[common.SYNC_PLAYER] = function ( client, message )
    if #message == 1 then
        local sync_player = parsePlayer( message[1] )
        if sync_player.id then
            local sync_pilot
                if sync_player.id == client.playerinfo.nick then
                    sync_pilot = player.pilot()
                elseif sync_pilot and sync_pilot:exists() then
                    sync_pilot = client.pilots[sync_player]
                else
                    print("WARNING: Trying to sync an unknown player <" .. sync_player.id .. ">")
                    return
                end
            sync_pilot:setEnergy(sync_player.stats[1])
            sync_pilot:setTemp(sync_player.stats[2], false)
            sync_pilot:setHealth(sync_player.stats[3], sync_player.stats[4], sync_player.stats[5])
            sync_pilot:fillAmmo()
            ai_setup.setup( sync_pilot )
        end
    end
end

local function toggleOutfit( client, message, on )
    if #message >= 2 then
        local playerID
        for ii, activated_line in ipairs( message ) do
            if ii == 1 then
                playerID = activated_line
            else    -- trust the server
                outf = activated_line
                clplt = client.pilots[playerID]
                if clplt and clplt:exists() then
                    --print(outf .. " turned " .. tostring(on))
                    clplt:outfitToggle(clplt:memory()._o[outf], on)
                end
            end
        end
    end
end

--[[
--  receive an update about a pilot activating a weapon set
--  lines should be: player_id\nactivated1\nactivated2 ...
--  each activated line should be like: blink_engine
--]]
common.receivers[common.ACTIVATE_OUTFIT] = function ( client, message )
    return toggleOutfit( client, message, true )
end
--
--[[
--  receive an update about a pilot deactivating an outfit
--  lines should be: player_id\nactivated1\nactivated2 ...
--  each activated line should be like: blink_engine
--]]
common.receivers[common.DEACTIVATE_OUTFIT] = function ( client, message )
    return toggleOutfit( client, message, false )
end

--[[
--  someone is sending a message
--
--]]
common.receivers[common.SEND_MESSAGE] = function ( client, message )
    if #message >= 1 then
        local player_id = message[2]
        local oplt = client.pilots[player_id]
        if oplt and oplt:exists() then
            oplt:broadcast( message[1], true )
        else
            pilot.comm( player_id or "Unknown", message[1] )
        end
    end
end


local mp_sounds = {}
--[[
--  The server wants us to play a sound and/or display
--  an accompanying message
--]]
common.receivers[common.PLAY_SOUND] = function ( client, message )
    -- for now, we only allow one sound
    -- msg[1] is the sound, msg[2] is the message
    if #message < 1 then
        -- what you doing server? don't crash me plz
        return
    end
    local sfx = mp_sounds[message[1]]
    if not sfx then
        -- TODO: maybe some error handling
        sfx = audio.new( message[1] )
        mp_sounds[message[1]] = sfx
    end
    print(message[1])
    sfx:play()
    if #message >= 2 then
        player.omsgAdd(
            "#p"..message[2].."#0"
        )
    end
end

--[[
--  Server wants to give us a new environment
--
--]]
common.receivers[common.TELEPORT] = function ( client, message )
    local target = "Multiplayer Lobby"
    if #message >= 1 then
        target = message[1]
    end
    player.teleport( target )
end

--[[
--  The server wants us to be on a team, we get our team name and
--  our team members (team name is currently unused)
--  lines should be: teamname\nmember1\nmember2 ...
--]]
common.receivers[common.ASSIGN_TEAM] = function ( client, message )
    -- assume everyone is an enemy
    for _plid, pplt in pairs(client.pilots) do
        if pplt:exists() then
            pplt:setHostile()
        end
    end

    for ii, item in ipairs(message) do
        if ii >= 2 then
            local friend = item
            if
                client.pilots[friend]
                and client.pilots[friend]:exists()
            then
                client.pilots[friend]:setFriendly()
                client.pilots[friend]:setInvincPlayer()
            end
        end
    end
end

common.unmarshal = function ( input )
    return unmarshal( parsePlayer( input ) )
end

common.marshal_me = function( ident )
    -- hard clamp values to 0,1
    -- TODO refactor or something, officially at 3...
    local c = naev.cache()
    local accel = c.accel or 0
    local primary = c.primary or 0
    local secondary = c.secondary or 0
    if accel and accel ~= 0 then
        accel = 1
    end
    if primary and primary ~= 0 then
        primary = 1
    end
    if secondary and secondary ~= 0 then
        secondary = 1
    end
    local armour, shield, stress = player.pilot():health()
    local velx, vely = player.pilot():vel():get()
    local posx, posy = player.pilot():pos():get()
    local target = player.pilot():target()
    if target then
        target = target:name()
    else
        target = ident 
    end
    local message = fmt.f("{id} {posx} {posy} {dir} {velx} {vely} {armour} {shield} {stress} {accel} {primary} {secondary} {target}",
        {
            id        = ident,
            posx      = posx,
            posy      = posy,
            dir       = player.pilot():dir(),
            velx      = velx,
            vely      = vely,
            armour    = armour,
            shield    = shield,
            stress    = stress,
            accel     = accel,
            primary   = primary,
            secondary = secondary,
            target    = target,
        }
    )
    return message
end

-- NOTE: first 2 items are playerid, ship
common.unmarshal_outfits = function( data )
    local outfits = {}
    for ii, dline in ipairs( data ) do
        if ii > 2 then
            table.insert(outfits, outfit.get(dline))
        end
    end

    return outfits
end

common.marshal_outfits = function( outfits )
    local ostr = ''
    for _i, oo in ipairs(outfits) do
        ostr = ostr .. oo:nameRaw() .. '\n'
    end
    return ostr
end

common.sync_player = function ( ppid, ppinfo, container, resync )
    local this_pilot = container[ppid]
    this_pilot:fillAmmo()
    local target = ppinfo.target or "NO TARGET!!"
    if target and container[ target ] then
        container[ppid]:setTarget( container[target] )
    else
        container[ppid]:setTarget( player.pilot() )
    end
    local pdiff = vec2.add( this_pilot:pos() , -ppinfo.posx, -ppinfo.posy ):mod()
    if pdiff > 8 then
        container[ppid]:setPos(vec2.new(ppinfo.posx, ppinfo.posy))
        container[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
    end
    if resync then
        container[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
    elseif math.abs(ppinfo.velx * ppinfo.vely) < 1 then
        container[ppid]:setVel(vec2.new(ppinfo.velx, ppinfo.vely))
    end
    container[ppid]:setDir(ppinfo.dir)
    container[ppid]:setHealth(ppinfo.armour, ppinfo.shield, ppinfo.stress)
    pilot.taskClear( container[ppid] )
    if ppinfo.weapset then
        -- this is really laggy I think
        pilot.pushtask( container[ppid], "REMOTE_CONTROL_SWITCH_WEAPSET", ppinfo.weapset )
    end
    if ppinfo.primary == 1 then
        pilot.pushtask( container[ppid], "REMOTE_CONTROL_SHOOT", false )
        if target and container[ target ] and container[target] == player.pilot() then
            container[ppid]:setHostile()
        end
    end
    if ppinfo.secondary == 1 then
        pilot.pushtask( container[ppid], "REMOTE_CONTROL_SHOOT", true )
        if target and container[ target ] and container[target] == player.pilot() then
            container[ppid]:setHostile()
        end
    end
    if ppinfo.accel then
        local anum = tonumber(ppinfo.accel)
        if anum == 1 then
            pilot.pushtask( container[ppid], "REMOTE_CONTROL_ACCEL", 1 )
        else -- if resync then
            pilot.pushtask( container[ppid], "REMOTE_CONTROL_ACCEL", 0 )
        end
    end
end

return common
