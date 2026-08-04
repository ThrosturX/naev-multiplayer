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
local p2psession    = require "multiplayer.p2p.session"
local space_objects = require "multiplayer.p2p.space_objects"
local distress      = require "multiplayer.distress"
local pod_network   = require "multiplayer.pod_racing_network"
local luatk         = require "luatk"
local vn = require "vn"
-- luacheck: globals load startMultiplayerServer resetMultiplayerCache
-- luacheck: globals P2P_SESSION_UPDATE P2P_SESSION_INPUT
-- luacheck: globals P2P_SESSION_ENTER P2P_SESSION_LEAVE
-- luacheck: globals P2P_SESSION_PILOT_CREATION
-- luacheck: globals P2P_SESSION_PILOT_DEFERRED P2P_SESSION_PILOT_DEATH
-- luacheck: globals P2P_SESSION_PILOT_JUMP P2P_SESSION_PILOT_LAND
-- luacheck: globals P2P_SESSION_PILOT_ATTACKED
-- luacheck: globals P2P_SESSION_PLAYER_DEATH
-- luacheck: globals P2P_SESSION_NPC_REPLICATION
-- luacheck: globals P2P_OBJECT_UPDATE P2P_OBJECT_TIMER
-- luacheck: globals P2P_OBJECT_CONSUME P2P_OBJECT_DESTROYED
-- luacheck: globals P2P_ONBOARDING

local function pick_one ( ipair )
    return ipair[ rnd.rnd( 1, #ipair ) ]
end

local P2P_NODE_ID_VAR = "multiplayer_p2p_node_id"

local function p2p_persistent_defaults ( settings )
    settings = settings or {}
    local node_id, store = p2psession.resolve_node_id(
        settings.node_id, var.peek(P2P_NODE_ID_VAR))
    settings.node_id = node_id
    if store then var.push(P2P_NODE_ID_VAR, node_id) end
    return p2psession.defaults(settings)
end

function create ()
    mem.multiplayer = {
        servers = {},
        p2p = p2p_persistent_defaults(),
        p2p_hook_ids = {},
    }
    hook.load("load")
end

local mpbtn

local p2p_pilot_hooks = {}
local p2p_hail_pressed

local function p2p_clear_pilot_hooks ()
    for _index, h in ipairs(p2p_pilot_hooks) do hook.rm(h) end
    p2p_pilot_hooks = {}
end

local function p2p_install_pilot_hooks ()
    p2p_clear_pilot_hooks()
    p2p_pilot_hooks = {
        hook.pilot(nil, "creation", "P2P_SESSION_PILOT_CREATION"),
        hook.pilot(nil, "attacked", "P2P_SESSION_PILOT_ATTACKED"),
        hook.pilot(player.pilot(), "disable", "P2P_SESSION_PLAYER_DEATH"),
        hook.pilot(player.pilot(), "exploded", "P2P_SESSION_PLAYER_DEATH"),
    }
end

local function p2p_publish_config ()
    local settings = mem.multiplayer and mem.multiplayer.p2p or {}
    naev.cache().multiplayer_p2p_config = {
        enabled = settings.enabled == true,
        directory = type(settings.directory) == "string"
            and settings.directory or "",
        node_id = type(settings.node_id) == "string"
            and settings.node_id or "",
        captain = player.name(),
    }
end

local function p2p_pump ( dt, modal )
    if modal then p2psession.keep_simulation_live() end
    p2psession.update(dt or 0)
end

local function p2p_chat_available ()
    if player.isLanded() then return false end
    local pp = player.pilot()
    local nav_spob = pp:nav()
    local target = pp:target()
    if target and target:ship():nameRaw() ~= "Signal Relay" then
        local ok, disabled = pcall(function() return target:disabled() end)
        if not ok or not disabled then return false end
    end
    return nav_spob == nil
end

local function p2p_keep_chat_live ( chat_state )
    local widget_update = chat_state._update
    local chat_update
    chat_update = function(self, dt)
        p2p_pump(dt, true)
        widget_update(self, dt)
        -- LuaTK replaces its one-shot focus initializer with its steady-state
        -- updater. Keep wrapping whichever updater it installs.
        if self._update ~= chat_update then
            widget_update = self._update
            self._update = chat_update
        end
    end
    chat_state._update = chat_update
end

local function p2p_size_chat ( window )
    local screen_width = naev.gfx.dim()
    local old_width = window.w
    local new_width = math.max(old_width, math.min(560, screen_width-40))
    local input_growth = 0
    for _index, widget in ipairs(window._widgets) do
        if widget.type == "input" then
            local new_height = 10+2*widget.fontlh
            input_growth = math.max(0, new_height-widget.h)
            widget.h = new_height
            widget.oneline = false
            break
        end
    end
    window:resize(new_width, window.h+input_growth)
    for _index, widget in ipairs(window._widgets) do
        local right_margin = old_width-widget.x-widget.w
        if widget.type == "button" then
            widget.x = new_width-right_margin-widget.w
            widget.y = widget.y+input_growth
        else
            widget.w = new_width-widget.x-right_margin
        end
    end
end

local function p2p_run_chat ()
    local vn_keypressed = vn.keypressed
    vn.keypressed = function(key, isrepeat)
        if luatk.isOpen()
                and string.lower(naev.keyGet("starmap")) == key then
            -- VN opens the map before forwarding this key to its LuaTK state.
            -- Suppress only that side effect so the character is still typed.
            local map_open = naev.mapOpen
            naev.mapOpen = function() end
            local ok, handled = pcall(vn_keypressed, key, isrepeat)
            naev.mapOpen = map_open
            if not ok then error(handled, 0) end
            return handled
        end
        return vn_keypressed(key, isrepeat)
    end
    vn.run()
    vn.keypressed = vn_keypressed
end

local function p2p_stop ()
    p2p_clear_pilot_hooks()
    space_objects.stop()
    p2psession.stop()
    p2p_hail_pressed = nil
    for _index, h in ipairs(mem.multiplayer.p2p_hook_ids or {}) do hook.rm(h) end
    mem.multiplayer.p2p_hook_ids = {}
    p2p_publish_config()
end

local function p2p_start ()
    p2p_stop()
    local ok, err = p2psession.start(mem.multiplayer.p2p)
    if not ok then print("P2P: " .. tostring(err)); return end
    mem.multiplayer.p2p_hook_ids = {
        hook.update("P2P_SESSION_UPDATE"),
        hook.input("P2P_SESSION_INPUT"),
        hook.enter("P2P_SESSION_ENTER"),
        hook.land("P2P_SESSION_LEAVE"),
        hook.takeoff("P2P_SESSION_ENTER"),
        hook.jumpout("P2P_SESSION_LEAVE"),
        hook.custom("multiplayer_npc_replication", "P2P_SESSION_NPC_REPLICATION"),
    }
    if not player.isLanded() then
        p2psession.enter(system.cur():nameRaw())
        p2p_install_pilot_hooks()
        space_objects.start(p2psession)
    end
    p2p_publish_config()
end

local function p2p_run_buoy_prompt ( request )
    vn.reset()
    local input_state = luatk.vn(function()
        local window = luatk.msgInput(_("MESSAGE BUOY"), _("Message:"), 96, function(msg)
            if not msg then return end
            local ok, err = p2psession.create_message_buoy(msg, request.slot)
            space_objects.wake()
            if not ok and err then player.msg("#r"..tostring(err).."#0") end
        end)
        p2p_size_chat(window)
    end)
    p2p_keep_chat_live(input_state)
    p2p_run_chat()
end

function P2P_SESSION_UPDATE ( dt )
    p2p_pump(dt)
    local cache = naev.cache()
    local request = cache.multiplayer_object_deploy
    if request then
        cache.multiplayer_object_deploy = nil
        if request.kind == "message_buoy" then
            p2p_run_buoy_prompt(request)
        elseif request.kind == "signal_relay" then
            local ok, err = p2psession.create_signal_relay(request.slot)
            space_objects.wake()
            if not ok and err then player.msg("#r"..tostring(err).."#0") end
        end
    end
end
function P2P_OBJECT_UPDATE ( generation )
    space_objects.update(generation)
end
function P2P_OBJECT_TIMER ( generation )
    space_objects.timer(generation)
end
function P2P_OBJECT_CONSUME ( generation )
    space_objects.consume(generation)
end
function P2P_OBJECT_DESTROYED ( p, _attacker, object_id )
    space_objects.object_destroyed(object_id, p)
end
function P2P_SESSION_PILOT_CREATION ( p )
    p2psession.pilot_created(p)
end
function P2P_SESSION_PILOT_DEFERRED ( generation )
    p2psession.pilot_created_deferred(generation)
end
function P2P_SESSION_PILOT_DEATH ( p, _attacker, entity )
    p2psession.pilot_departed(p, "death", entity)
end
function P2P_SESSION_PILOT_JUMP ( p, _jump, entity )
    p2psession.pilot_departed(p, "jump", entity)
end
function P2P_SESSION_PILOT_LAND ( p, _spob, entity )
    p2psession.pilot_departed(p, "land", entity)
end
function P2P_SESSION_PILOT_ATTACKED ( victim, attacker, _damage )
    p2psession.pilot_attacked(victim, attacker)
end
function P2P_SESSION_PLAYER_DEATH ( p, _attacker )
    p2psession.player_died(p)
end
function P2P_SESSION_NPC_REPLICATION ( enabled )
    p2psession.accept_npc_replicas = enabled ~= false
end
function P2P_SESSION_INPUT ( input_name, input_pressed )
    p2psession.input(input_name, input_pressed)
    if input_name ~= "hail" then return end
    if input_pressed then
        p2p_hail_pressed = p2p_chat_available()
        return
    end
    local open_chat = p2p_hail_pressed and p2p_chat_available()
    p2p_hail_pressed = nil
    if not open_chat then return end
    vn.reset()
    local chat_state = luatk.vn(function()
        local window = luatk.msgInput(_("COMMUNICATION"), _("Broadcast:"), 96, function(msg)
            if msg and #msg > 0 and p2psession.send_chat(msg) then
                space_objects.chat(msg)
            end
        end)
        p2p_size_chat(window)
    end)
    p2p_keep_chat_live(chat_state)
    p2p_run_chat()
end
function P2P_SESSION_ENTER ()
    space_objects.stop()
    p2psession.enter(system.cur():nameRaw())
    p2p_install_pilot_hooks()
    space_objects.start(p2psession)
end
function P2P_SESSION_LEAVE ()
    p2p_hail_pressed=nil
    p2p_clear_pilot_hooks()
    space_objects.stop()
    p2psession.leave()
end

function startMultiplayerServer( hostport )
    local fail = mplayerserver.start( hostport )
    if fail then
        print(fail)
        return
    end

    -- you are a server now, stay like that!
    player.infoButtonUnregister( mpbtn )

    mem.multiplayer.last_served_port = hostport
    evt.save()
end

function resetMultiplayerCache ()
    p2p_stop()
    distress.stop()
    pod_network.stop(false)
    mplayerclient.stop()
    mplayerserver.stop()
    player.infoButtonUnregister(mpbtn)
    mpbtn = nil
    evt.finish(false)
end

local function connectMultiplayer( hostname, hostport, localport )
    hostname = hostname or "localhost"
    hostport = hostport or "6789"
    localport = localport or "0" -- get an ephemeral port

    local target = fmt.f( "{host}:{port}", { host = hostname, port = hostport } )
    print ( target )

    -- for testing
    if not target  or target == ":" then
        hostname = "localhost"
        hostport = "6789"
    end

    if target then
        local fail = mplayerclient.start( hostname, hostport, localport )
        if fail then
            print("ERROR: " .. fail )
        else
            -- sorry user, reload game to reconnect
            player.infoButtonUnregister( mpbtn )
        end
    end
end

local function _connectMultiplayer( target )
    local space = target:find(' ')
    local hostname = target:sub(1, space - 1)
    local hostport = target:sub(space + 1, target:len())
    mem.multiplayer.last_server = { nick = "last server", host = fmt.f("{hostname} {hostport}", { hostname = hostname, hostport = hostport } ) }
    evt.save()
    connectMultiplayer( hostname, hostport )
end

local MPIMG = "pers_mpauth.png"
local GREETINGS = {
    _("Welcome, {name}! Up for some multiplayer?"),
    _("Greetings, {name}. Would you like to play a game?"),
    _("Hello {name}, did you know that multiplayer has a chat feature? Just make sure to type your messages real fast or you'll get disconnected."),
    _("Be careful, {name}. Multiplayer can be pretty addictive."),
    _("Did you know that Naev's description on Steam stated that the game would never have multiplayer? Never doubt the efforts of communities made up almost entirely of nerds!"),
    _("Naev is a free game. Instead of paying money for a video game, how about donating some of your time to improve the world in some way? Regardless, please enjoy the multiplayer experience!"),
    _("Welcome to the multiplayer experience. Please note that addiction is not guaranteed but highly likely."),
    _("I am the original multiplayer. I wish you a pleasant experience."),
    _("Freedom of speech means that you can say anything you want. It doesn't mean you'll get away with it, though."),
    _("Please note that hosting a server on a non-ephemeral port might require port forwarding. Don't shame me by demilitarizing your router!"),
    _("My first programming project was actually a wallhack for the half-life engine. I learned a lot, but the most valuable lesson was that cheating is really boring and removes all of the satisfaction from winning. Please remember to be kind, but don't feel compelled to keep playing if you feel uncomfortable."),
    _("If you have any good ideas for multiplayer, feel free to drop them under the 'Issues' tab on GitHub!"),
    _("Greetings captain {name}. Welcome to the Multiplayer experience. Expect carnage, desynchronization, error messages, erratic music and even sound effects. Don't expect how long it will suck you in, don't even worry about it..."),
    _("Once you connect to a server, you will automatically be reconnected if you are disconnected for any reason. This doesn't necessarily mean that you get to keep playing where you left off, though."),
}
local function vnMultiplayer()
    if mem.multiplayer.p2p.enabled then p2psession.request_activity() end
    local recent_activity = p2psession.recent_activity()
    local activity_lines = {}
    for _index, entry in ipairs(recent_activity) do
        local status
        if entry.active then
            status = _("active now")
        elseif entry.age < 60 then
            status = _("active less than a minute ago")
        else
            status = fmt.f(_("{minutes} minutes ago"),
                {minutes=math.max(1,math.floor(entry.age/60))})
        end
        activity_lines[#activity_lines+1] =
            fmt.f(_("{system} — {status}"), {system=entry.system,status=status})
    end
    local activity_message = #activity_lines>0
        and table.concat(activity_lines,"\n")
        or _("No recently active systems were reported. The directory may still be responding; close and reopen this menu to refresh.")
    local choices = {
        { _("Connect"), "connect_menu" },
        { _("Host Server"), "host" },
    }
    if mem.multiplayer.last_server and not mem.multiplayer.p2p.enabled then
        table.insert( choices, { fmt.f( _("Reconnect to {nick}"), mem.multiplayer.last_server ), "reconnect" } )
    end
    if mem.multiplayer.last_served_port then
        table.insert( choices, { fmt.f( _("Host a server on {port}"), { port = mem.multiplayer.last_served_port } ), "rehost" } )
    end
    if mem.multiplayer.p2p.enabled then
        table.insert( choices, { _("Show recently active systems"), "p2p_activity" } )
    end
    table.insert( choices, { _("Close"), "end" } )
    vn.clear()
    vn.scene()
    local mpvn = vn.newCharacter ( _("The Original Multiplayer"), { image = MPIMG } )
    vn.transition()
    mpvn(
        fmt.f(
            pick_one(GREETINGS),
            {
                name = player.name()
            }
        )
    )
    vn.menu(choices)

    local target = nil
    vn.label("connect_target")
    vn.done()

    choices = {
        { _("New Server"), "add_server" },
    }

    if mem.multiplayer.servers then
        table.insert( choices,
            { _("Remove Server"), "remove_server" }
        )
        for srvid, srvinf in pairs(mem.multiplayer.servers) do
            print("adding " .. srvid)
            table.insert( choices,
                { srvid, srvid }
            )
            vn.label( srvid )
            vn.func( function()
                target = srvinf.host
                vn.jump( "connect_target" )
            end )
        end
    end

    vn.label("connect_menu")
    vn.menu( choices )
    vn.done()

    if mem.multiplayer.last_server then
        vn.label("reconnect")
        vn.func( function()
            target = mem.multiplayer.last_server.host
            vn.jump( "connect_target" )
        end )
    end

    vn.label("p2p_activity")
    mpvn(activity_message)
    vn.jump("end")

    local port
    if mem.multiplayer.last_served_port then
        vn.label("rehost")
        vn.func( function()
            port = mem.multiplayer.last_served_port
            vn.jump( "host_port" )
        end )
    end

    vn.label("host")
    mpvn(
        _("What port do you want to serve on?")
    )
    vn.menu(
        {
            { _("Custom port"), "host_port"},
            { _("Pick for me"), "host_ephemeral"}
        }
    )

    vn.label("host_ephemeral")
    vn.func( function() port = "0" end )
    -- deliberate fallthrough
    vn.label("host_port")
    vn.func( function()
        if not port then
            port = tk.input("Server Port", 1, 6, "Port:")
        end
        if player.isLanded() then
            player.takeoff()
        end
        hook.timer(1, "startMultiplayerServer", port )
        vn.jump("enjoy")
    end )

    vn.label("add_server")
    local server_info = {}
    mpvn(
        _("So you want to add a server, huh? Alright, I'll need a nickname for this server. What would you like to call it?")
    )
    vn.func( function()
        server_info.name = tk.input( _("Server Nickname"), 1, 32, _("Name:") )
        if not server_info.name then
            vn.jump("end")
        end
    end )
    mpvn(
        _("Now for the important bit... I'll need the IP address of the server along with the port that it's being served on (separated by a space). Please supply it in a format such as `127.0.0.1 9999`.")
    )
    vn.func( function()
        server_info.host = tk.input( _("Server Address:Port"), 9, 128, _("Server:") )
        if server_info.host and server_info.host:find(' ') then
            mem.multiplayer.servers[server_info.name] = server_info
            target = server_info.host
        else
            -- TODO: jump to "that was an error"
            vn.jump("connect_menu")
        end
    end )

    mpvn(
        _("Alright, now you can test it.")
    )
    vn.jump( "connect_target" )

    vn.label("remove_server")
    mpvn(
        _("You really want to remove a server? Alright, I'm not going to judge. What is the nickname of the server you wish to forget?")
    )

    vn.func( function()
        local bad_server = tk.input( _("Server to remove"), 1, 32, _("Nickname") )
        if bad_server then
            mem.multiplayer.servers[bad_server] = nil
        end
        -- else user pressed escape
    end )

    mpvn(
        _("Whether that server ever existed or not, it's gone now! Poof!")
    )

    vn.label("enjoy")
    mpvn( _("Have fun!") )

    vn.label("end")
    vn.done()
    vn.run()

    evt.save()

    if target then
        print("target is '" .. tostring(target) .. "`")
        _connectMultiplayer( target )
    end
end

local function p2p_apply_configuration ()
    if mem.multiplayer.p2p.enabled then
        p2p_start()
    else
        p2p_publish_config()
    end
    evt.save()
end

local function p2p_manage_peers ( on_refresh )
    local w, h = 520, 390
    local wdw = luatk.newWindow(nil,nil,w,h)
    luatk.newText(wdw,0,10,w,20,_("Bootstrap Peers"),nil,"centre")
    luatk.newText(wdw,20,40,w-40,60,
        _("The relay server is not strictly necessary. You can instead bootstrap yourself to other peers. Just put their IPs in here."))
    local peers = mem.multiplayer.p2p.bootstrap
    local listed_peers = #peers>0 and peers
        or { _("No bootstrap peers configured.") }
    local peer_list = luatk.newList(wdw,20,105,w-40,110,listed_peers)
    if #peers==0 then
        luatk.newText(wdw,20,220,w-40,25,
            _("No bootstrap peers configured.."))
    end
    local peer_input = luatk.newInput(wdw,20,255,w-180,30,255)
    luatk.newText(wdw,20,295,w-40,30,
        _("Enter address:port to add a peer."))

    local function restart_after_change ()
        p2p_apply_configuration()
        if on_refresh then on_refresh() end
        wdw:destroy()
        p2p_manage_peers(on_refresh)
    end
    luatk.newButton(wdw,w-140,255,120,30,_("Add Peer"),function()
        local endpoint = p2psession.normalize_endpoint(peer_input.str)
        if endpoint and endpoint~="" then
            table.insert(peers,endpoint)
            restart_after_change()
        else
            luatk.msg(_("Invalid Bootstrap Peer"),
                _("Enter an address and port."))
        end
    end)
    local remove = luatk.newButton(wdw,20,h-20-30,150,30,
        _("Remove Selected"),function()
            if #peers==0 then return end
            local _peer, index = peer_list:get()
            table.remove(peers,index)
            restart_after_change()
        end)
    if #peers==0 then remove:disable() end
    local function close_peers ()
        if on_refresh then on_refresh() end
        wdw:destroy()
        return true
    end
    luatk.newButton(wdw,w-20-100,h-20-30,100,30,_("Close"),close_peers)
    wdw:setCancel(close_peers)
    wdw:setFocus(peer_input)
end

local function p2p_new_settings_input ( parent, x, y, w, h, max, params )
    local input = luatk.newInput(parent,x,y,w,h,max,params)
    local on_change = params and params.on_change
    local on_blur = params and params.on_blur
    local draw = input.draw
    input.draw = function(self, bx, by)
        if self.focused then
            draw(self,bx,by)
            return
        end
        local timer = self.timer
        self.timer = 1
        draw(self,bx,by)
        self.timer = timer
    end
    local keypressed = input.keypressed
    input.keypressed = function(self, key)
        local before = self.str
        local consumed = keypressed(self,key)
        if on_change and self.str~=before then on_change() end
        return consumed
    end
    local textinput = input.textinput
    input.textinput = function(self, str)
        local before = self.str
        local consumed = textinput(self,str)
        if on_change and self.str~=before then on_change() end
        return consumed
    end
    input.released = function(self, mx, my)
        local outside = mx<0 or mx>self.w or my<0 or my>self.h
        if outside and self.focused and on_blur then on_blur() end
    end
    return input
end

local function multiplayer_settings ()
    local open_arena = false
    local reset_cache = false
    local update_p2p_status
    local mark_settings_changed
    local shown_status
    local status_refresh_after
    local settings_dirty = false
    local w, h = 460, 570
    local wdw = luatk.newWindow(nil,nil,w,h)
    wdw:setUpdate(function(dt)
        p2p_pump(dt,true)
        if not status_refresh_after then return end
        status_refresh_after = status_refresh_after - dt
        if status_refresh_after>0 then return end
        status_refresh_after=nil
        update_p2p_status()
    end)
    luatk.newText(wdw,0,10,w,20,_("Multiplayer Settings"),nil,"centre")
    local intro = luatk.newText(wdw,20,40,w-40,nil,
        _("World sharing allows players to connect to each other and share the same star system. You can still do everything like in single-player; it is an augmented experience.\n\nA player may be unable to join a shared system when one of their missions or events claims that system."))

    local digit_whitelist = {}
    for digit=0,9 do digit_whitelist[tostring(digit)] = true end
    local save_settings
    local y = 40 + intro:height() + 15
    luatk.newText(wdw,20,y,115,30,_("Listen Port:"))
    local port_input = p2p_new_settings_input(wdw,140,y-5,80,30,5,
        {whitelist=digit_whitelist,
         on_change=function() mark_settings_changed() end,
         on_blur=function()
            if settings_dirty then save_settings() end
         end})
    port_input:set(tostring(mem.multiplayer.p2p.listen_port))
    local port_reset_button = luatk.newButton(wdw,w-20-150,y-5,150,30,
        _("Reset to Default"),function()
            port_input:set(tostring(p2psession.DEFAULT_LISTEN_PORT))
            save_settings()
        end)
    y = y + 45
    luatk.newText(wdw,20,y,115,30,_("Relay Server:"))
    local relay_input
    local relay_reset_button = luatk.newButton(wdw,w-20-150,y-5,150,30,
        _("Reset to Default"),function()
            relay_input:set(p2psession.DEFAULT_DIRECTORY)
            save_settings()
        end)
    relay_input = p2p_new_settings_input(wdw,20,y+30,360,30,255,
        {on_change=function() mark_settings_changed() end,
         on_blur=function()
            if settings_dirty then save_settings() end
         end})
    relay_input:set(mem.multiplayer.p2p.directory)
    y = y + 85
    luatk.newButton(wdw,20,y-5,200,30,_("Peer Management"),function()
        if not save_settings() then return end
        p2p_manage_peers(function()
            shown_status=nil
            update_p2p_status()
        end)
    end)
    luatk.newButton(wdw,230,y-5,200,30,_("Arena Multiplayer"),function()
        if not save_settings() then return end
        open_arena = true
        luatk.close()
    end)

    local sharing_y = y + 45
    local p2p_button
    local status_text = luatk.newText(wdw,280,sharing_y+5,100,30,"",nil,"centre")
    mark_settings_changed = function ()
        settings_dirty=true
        status_refresh_after=nil
        shown_status=nil
        local port = tonumber(port_input.str)
        local directory = p2psession.normalize_endpoint(relay_input.str)
        if not port or port<0 or port>65535 or not directory then
            shown_status="invalid"
            status_text:set("#r".._("Invalid").."#0")
        else
            shown_status="unsaved"
            status_text:set(_("Unsaved"))
        end
    end
    update_p2p_status = function ()
        if settings_dirty then
            mark_settings_changed()
            return
        end
        local status, text
        if not mem.multiplayer.p2p.enabled then
            status_refresh_after=nil
            status, text = "offline", "#o".._("Offline").."#0"
        else
            local network, refresh_after = p2psession.network_status()
            status_refresh_after=refresh_after
            if network=="online" then
                status, text = "online", "#g".._("Enabled").."#0"
            elseif network=="unknown" then
                status, text = "unknown", _("Enabled")
            else
                status, text = "unavailable", "#r".._("No Network").."#0"
            end
        end
        if status==shown_status then return end
        shown_status=status
        status_text:set(text)
    end
    p2p_button = luatk.newButton(wdw,20,sharing_y,200,30,
        _("World Sharing"),function()
        if settings_dirty and not save_settings() then return end
        mem.multiplayer.p2p.enabled = not mem.multiplayer.p2p.enabled
        if mem.multiplayer.p2p.enabled then p2p_start() else p2p_stop() end
        evt.save()
        shown_status=nil
        update_p2p_status()
    end)
    update_p2p_status()
    local note = luatk.newText(wdw,20,sharing_y+45,w-40,nil,
        _("You shouldn't have to change any of these settings. Just make sure that world sharing is enabled if you want to play with other people. You might want to forward a fixed UDP port if you have issues connecting to other players."),
        {0.7,0.7,0.7}) -- cFontGrey used by native Info labels.
    local footer_y = sharing_y + 45 + note:height() + 15
    h = footer_y + 50
    wdw:resize(w,h)
    luatk.newButton(wdw,w-20-150,footer_y,150,30,
        _("Reset Cache").." #r".._("!!").."#0",function()
        luatk.yesno(_("Reset Multiplayer Cache?"),
            _("This removes the multiplayer event and its registered hooks. Save and reload the game to start multiplayer again."),function()
                reset_cache = true
                luatk.close()
            end,nil,_("Reset"),_("Cancel"))
    end)

    save_settings = function ()
        local port = tonumber(port_input.str)
        if not port or port<0 or port>65535 then
            mark_settings_changed()
            luatk.msg(_("Invalid P2P Listen Port"),_("Enter a port from 0 to 65535."))
            return false
        end
        local directory = p2psession.normalize_endpoint(relay_input.str)
        if not directory then
            mark_settings_changed()
            luatk.msg(_("Invalid Relay Server"),
                _("Enter an address and port, for example 127.0.0.1:60939."))
            return false
        end
        port = math.floor(port)
        local settings = mem.multiplayer.p2p
        if settings.listen_port~=port or settings.directory~=directory then
            settings.listen_port=port
            settings.directory=directory
            p2p_apply_configuration()
        end
        settings_dirty=false
        shown_status=nil
        update_p2p_status()
        return true
    end
    local function close_settings ()
        if save_settings() then luatk.close() end
        return true
    end
    local set_focus = wdw.setFocus
    wdw.setFocus = function(self, widget)
        local focused = self.focused
        local leaving_input = focused~=widget
            and (focused==port_input or focused==relay_input)
        local reset_clicked = widget==port_reset_button
            or widget==relay_reset_button
        if leaving_input and settings_dirty and not reset_clicked
            and not save_settings() then return end
        return set_focus(self,widget)
    end
    wdw:setCancel(close_settings)
    luatk.newButton(wdw,(w-100)/2,footer_y,100,30,_("Close"),close_settings)
    luatk.run()

    if reset_cache then
        hook.safe("resetMultiplayerCache")
    elseif open_arena then
        vnMultiplayer()
    end
end

function P2P_ONBOARDING ()
    if mem.multiplayer.p2p.enabled or mem.multiplayer.p2p_onboarding_seen then return end
    local enable_p2p = false
    vn.clear()
    vn.scene()
    local mpvn = vn.newCharacter(_("The Original Multiplayer"),{image=MPIMG})
    vn.transition()
    mpvn(_("Welcome to multiplayer. World sharing is now available.\n\nIn world sharing, time controls are disabled when other players are in the same system. Each player is authoritative over their own ship's movement and health, but one player is chosen to host the system and control its ambient NPC population."))
    mpvn(_("You can enable or disable world sharing, sometimes referred to as P2P or peer-to-peer, in the settings by opening up the information menu."))
    mpvn(_("Naev multiplayer is peer-to-peer and trust-based. Other peers can discover your IP address during ordinary play."))
    vn.menu({
        { _("Enable P2P"), "enable" },
        { _("Not now"), "not_now" },
    })
    vn.label("enable")
    vn.func(function() enable_p2p = true end)
    mpvn(_("You have enabled world sharing. Have fun!"))
    vn.jump("end")
    vn.label("not_now")
    mpvn(_("Oh, okay. Well, you can enable world sharing at any time by opening up the multiplayer settings from the information menu."))
    vn.label("end")
    vn.done()
    vn.run()

    mem.multiplayer.p2p_onboarding_seen = true
    if enable_p2p then
        mem.multiplayer.p2p.enabled = true
        p2p_start()
    end
    evt.save()
end

function load()
    if not mem.multiplayer then
        mem.multiplayer = {
            servers = {},
        }
    end
    mem.multiplayer.p2p = p2p_persistent_defaults(mem.multiplayer.p2p)
    mem.multiplayer.p2p_hook_ids = mem.multiplayer.p2p_hook_ids or {}
    p2p_publish_config()
    evt.save()
    mpbtn = player.infoButtonRegister( _("Multiplayer"), multiplayer_settings, 3 )
  --serverbtn = player.infoButtonRegister( _("Start MP Server"), startMultiplayerServer, 3 )
  --clientbtn = player.infoButtonRegister( _("Connect Multiplayer"), connectMultiplayer, 3 )
    if mem.multiplayer.p2p.enabled then p2p_start() end
    if not mem.multiplayer.p2p.enabled and not mem.multiplayer.p2p_onboarding_seen then
        hook.safe("P2P_ONBOARDING")
    end
end
