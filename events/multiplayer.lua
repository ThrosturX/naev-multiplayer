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
local vn = require "vn"
-- luacheck: globals load startMultiplayerServer (Hook functions passed by name)

local function pick_one ( ipair )
    return ipair[ rnd.rnd( 1, #ipair ) ]
end

function create ()
    mem.multiplayer = {
        servers = {}
    }
    hook.load("load")
end

local mpbtn

function startMultiplayerServer( hostport )
    local fail = mplayerserver.start( hostport )
    if fail then
        print(fail)
        return
    end

    -- you are a server now, stay like that!
    player.infoButtonUnregister( mpbtn )
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
        fail = mplayerclient.start( hostname, hostport, localport )
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
    _("Please note that hosting a server on a non-ephemeral port might require port forwarding. Don't shame me by dimilitarizing your router!"),
    _("My first programming project was actually a wallhack for the half-life engine. I learned a lot, but the most valuable lesson was that cheating is really boring and removes all of the satisfaction from winning. Please remember to be kind, but don't feel compelled to keep playing if you feel uncomfortable."),
    _("If you have any good ideas for multiplayer, feel free to drop them under the 'Issues' tab on GitHub!"),
    _("Greetings captain {name}. Welcome to the Multiplayer experience. Expect carnage, desynchronization, error messages, erratic music and even sound effects. Don't expect how long it will suck you in, don't even worry about it..."),
    _("Once you connect to a server, you will automatically be reconnected if you are disconnected for any reason. This doesn't necessarily mean that you get to keep playing where you left off, though."),
}
local function vnMultiplayer()
    local choices = {
        { _("Connect"), "connect_menu" },
        { _("Host Server"), "host" },
    }
    if mem.multiplayer.last_server then
        table.insert( choices, { fmt.f( _("Reconnect to {nick}"), mem.multiplayer.last_server ), "reconnect" } )
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

    local port
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
            servers = {}
        }
    end
    mpbtn = player.infoButtonRegister( _("Multiplayer"), vnMultiplayer, 3 )
  --serverbtn = player.infoButtonRegister( _("Start MP Server"), startMultiplayerServer, 3 )
  --clientbtn = player.infoButtonRegister( _("Connect Multiplayer"), connectMultiplayer, 3 )
end
