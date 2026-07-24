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
local luatk         = require "luatk"
local vn = require "vn"
-- luacheck: globals load startMultiplayerServer P2P_SESSION_UPDATE P2P_SESSION_INPUT P2P_SESSION_ENTER P2P_SESSION_LEAVE (Hook functions passed by name)

local function pick_one ( ipair )
    return ipair[ rnd.rnd( 1, #ipair ) ]
end

function create ()
    mem.multiplayer = {
        servers = {},
        p2p = p2psession.defaults(),
    }
    hook.load("load")
end

local mpbtn

local p2p_hooks = {}
local p2p_hail_pressed

local function p2p_chat_available ()
    if player.isLanded() then return false end
    local pp = player.pilot()
    local nav_spob = pp:nav()
    local target = pp:target()
    if target then
        local ok, disabled = pcall(function() return target:disabled() end)
        if not ok or not disabled then return false end
    end
    return nav_spob == nil
end

local function p2p_keep_chat_live ( chat_state )
    local widget_update = chat_state._update
    local chat_update
    chat_update = function(self, dt)
        naev.unpause()
        widget_update(self, dt)
        -- LuaTK owns the update loop while the chat input is open, so enforce
        -- shared-session time controls here as well as in hook.update.
        p2psession.enforce_time_controls()
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
    p2psession.stop()
    p2p_hail_pressed = nil
    for _index, h in ipairs(p2p_hooks) do hook.rm(h) end
    p2p_hooks = {}
end

local function p2p_start ()
    p2p_stop()
    local ok, err = p2psession.start(mem.multiplayer.p2p)
    if not ok then print("P2P: " .. tostring(err)); return end
    p2p_hooks = {
        hook.update("P2P_SESSION_UPDATE"),
        hook.input("P2P_SESSION_INPUT"),
        hook.enter("P2P_SESSION_ENTER"),
        hook.land("P2P_SESSION_LEAVE"),
        hook.takeoff("P2P_SESSION_ENTER"),
        hook.jumpout("P2P_SESSION_LEAVE"),
    }
    if not player.isLanded() then p2psession.enter(system.cur():nameRaw()) end
end

function P2P_SESSION_UPDATE ( dt ) p2psession.update(dt) end
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
            if msg and #msg > 0 then p2psession.send_chat(msg) end
        end)
        p2p_size_chat(window)
    end)
    p2p_keep_chat_live(chat_state)
    p2p_run_chat()
end
function P2P_SESSION_ENTER () p2psession.enter(system.cur():nameRaw()) end
function P2P_SESSION_LEAVE () p2p_hail_pressed=nil; p2psession.leave() end

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
    local choices = {
        { _("Connect"), "connect_menu" },
        { _("Host Server"), "host" },
        { _("P2P Session Settings"), "p2p_settings" },
    }
    if mem.multiplayer.last_server then
        table.insert( choices, { fmt.f( _("Reconnect to {nick}"), mem.multiplayer.last_server ), "reconnect" } )
    end
    if mem.multiplayer.last_served_port then
        table.insert( choices, { fmt.f( _("Host a server on {port}"), { port = mem.multiplayer.last_served_port } ), "rehost" } )
    end
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

    local port
    if mem.multiplayer.last_served_port then
        vn.label("rehost")
        vn.func( function()
            port = mem.multiplayer.last_served_port
            vn.jump( "host_port" )
        end )
    end

    vn.label("p2p_settings")
    mpvn(_("P2P play leaves ordinary Naev gameplay enabled. Guests use the host's system population, so disable P2P before entering a system where your own mission pilots matter."))
    vn.menu({
        { mem.multiplayer.p2p.enabled and _("Disable P2P") or _("Enable P2P"), "p2p_toggle" },
        { fmt.f(_("Listen port: {port}"), {port=mem.multiplayer.p2p.listen_port}), "p2p_port" },
        { fmt.f(_("Directory: {address}"), {address=mem.multiplayer.p2p.directory}), "p2p_directory" },
        { _("Add bootstrap peer"), "p2p_add_peer" },
        { _("Remove bootstrap peer"), "p2p_remove_peer" },
        { _("Back"), "end" },
    })

    vn.label("p2p_toggle")
    vn.func(function()
        mem.multiplayer.p2p.enabled = not mem.multiplayer.p2p.enabled
        if mem.multiplayer.p2p.enabled then p2p_start() else p2p_stop() end
        evt.save()
    end)
    vn.jump("end")

    vn.label("p2p_port")
    vn.func(function()
        local value=tk.input(_("P2P Listen Port"),1,5,tostring(mem.multiplayer.p2p.listen_port))
        local port=tonumber(value)
        if port and port>=0 and port<=65535 then
            mem.multiplayer.p2p.listen_port=math.floor(port)
            if mem.multiplayer.p2p.enabled then p2p_start() end
            evt.save()
        end
    end)
    vn.jump("end")

    vn.label("p2p_directory")
    vn.func(function()
        local value=tk.input(_("Directory Address"),0,255,
            _("Address and port, separated by a space (default: 79.76.110.205 60939):"))
        if value~=nil then
            local endpoint=p2psession.normalize_endpoint(value)
            if endpoint then
                mem.multiplayer.p2p.directory=endpoint
                if mem.multiplayer.p2p.enabled then p2p_start() end
                evt.save()
            else
                print("P2P: directory must be entered as address port")
            end
        end
    end)
    vn.jump("end")

    vn.label("p2p_add_peer")
    vn.func(function()
        local value=tk.input(_("Bootstrap Peer"),3,255,
            _("Address and port, separated by a space (example: 127.0.0.1 62001):"))
        local endpoint=p2psession.normalize_endpoint(value)
        if endpoint and endpoint~="" then
            table.insert(mem.multiplayer.p2p.bootstrap,endpoint)
            if mem.multiplayer.p2p.enabled then p2p_start() end
            evt.save()
        elseif value~=nil then
            print("P2P: bootstrap peer must be entered as address port")
        end
    end)
    vn.jump("end")

    vn.label("p2p_remove_peer")
    vn.func(function()
        local value=tk.input(_("Remove Bootstrap Peer"),3,255,
            _("Address and port, separated by a space (example: 127.0.0.1 62001):"))
        local endpoint=p2psession.normalize_endpoint(value)
        if endpoint and endpoint~="" then
            for i=#mem.multiplayer.p2p.bootstrap,1,-1 do
                if mem.multiplayer.p2p.bootstrap[i]==endpoint then table.remove(mem.multiplayer.p2p.bootstrap,i) end
            end
            if mem.multiplayer.p2p.enabled then p2p_start() end
            evt.save()
        end
    end)
    vn.jump("end")

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

function load()
    if not mem.multiplayer then
        mem.multiplayer = {
            servers = {},
        }
    end
    mem.multiplayer.p2p = p2psession.defaults(mem.multiplayer.p2p)
    evt.save()
    mpbtn = player.infoButtonRegister( _("Multiplayer"), vnMultiplayer, 3 )
  --serverbtn = player.infoButtonRegister( _("Start MP Server"), startMultiplayerServer, 3 )
  --clientbtn = player.infoButtonRegister( _("Connect Multiplayer"), connectMultiplayer, 3 )
    if mem.multiplayer.p2p.enabled then p2p_start() end
end
