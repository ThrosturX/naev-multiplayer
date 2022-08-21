# Naev Multiplayer Plugin

This plugin provides the necessary files to manage multiplayer in Naev.

![A cartoon-like image of a character with colored 3D glasses](gfx/vn/characters/pers_mpauth.png?raw=true "The Original Multiplayer")

The plugin is fairly experimental and as such no backwards compatibility is guaranteed. It is recommended to play on the latest version of Naev (if compatible) and latest version of the plugin for all parties involved.

There are many features that haven't been implemented yet, and some that might just get brushed over. I like to stick to the principles that get us all the most amount of fun with the least amount of headaches, so let's make it fun and easy and we'll take it from there.

### Some things to note:

- Expect some desync, but the server is authoritative 
    - If you shoot on your client but there's nothing to shoot at, you don't lose energy because the server doesn't let you shoot
    - Missiles won't be in sync at all, but they are "predictably" out of sync, so it is a masterable skill
    - Beams are so out of sync that I removed them from `equiptopts`, it's not even funny
    - If you enter a blocking state such as a menu or the chat, you will risk being disconnected by timeout
- When you die, the server should respawn you in a new ship, but sometimes you might need to reload a save and reconnect
    - If you "respawn" in the same ship, you probably just ate a missile on your client that the server said was a miss, just keep playing
- You can't configure weapons on the client, it doesn't do anything at all other than mess up what you see
- You can use afterburners and shield boosters (perhaps other modules too) and the effects will be synchronized between clients
- Autonav works 
    - It should synchronize less often to save bandwidth on idling clients
    - Speedup does not work (and even if it did, the server would probably start teleporting you around or ask you to respawn)

### The chat

There is a basic chat feature. You press your hail button and a text window pops up. Type a short message fast before you are disconnected.

Once you have sent your message, you will be resynchronized to where the server says you should be and can continue playing.
Everyone will see your message if you are connected, you can confirm you are connected if your message appears in your message log.

This is mainly meant for short messages such as "go" or "attack goddard", but can be used for other things as well. Please be civil.

Question marks don't work, use something else instead. Perhaps your peers can decide on something like "ma" (a homage to Firefly, "ma" (嗎) is the Chinese equivalent of a question mark).

## Configuration

In order to use the plugin, the lua\_enet [configuration parameter](https://github.com/naev/naev/wiki/FAQ#where-is-conflua-stored) must be set to true.
Insert the following line at the very end of your `conf.lua`: `lua_enet = true`

### Server configuration

By default, the server tries to use port 6789, which is not ephemeral. You can change the code to use another port, or 0 if you wish to host a server but cannot do any port forwarding.

You will probably have to forward the server port in your router setting (reminder: the default is 6789).

In the case of port 0, you will need to find out what ephemeral port was selected automatically with a tool of your choice, but you should be able to host a server without port forwarding.

## Starting a server

1. Start a new pilot or log into an existing pilot for this purpose (a server can't play and the nickname will be reserved so it is a good idea to pick a name like "Server" or "Host").
2. Take off
3. Open the Info menu
    - If you don't see an option labelled "Start MP Server", land, then reload the new save, and go back to (2).
4. Click on the "Start MP Server" button on the "Main" tab
5. Close the Info menu
6. Leave the server alone, as the simulation must run for the networking code to execute

## Connecting to a server

1. Load a pilot with a suitable nickname (for obvious reasons, it's suggested to avoid using real world names on public servers, but special characters and numbers should be avoided as well).
2. Open the Info menu
3. Click on the "Connect Multiplayer" button
4. Type in the IP address of the server
5. Type in the port of the server
6. Take off
    - Saving will now be disabled until you load again
    - If the connection is successful, the server will respawn you in a new ship
    - If there is an error, your ship will broadcast the error message
        - If the error is: nickname is reserved then you should come back later or join with another pilot (you're not playing on a live server anymore)
    - If you die on the server, the client tries to keep you alive so that you can respawn without reloading your save game
    - If you die on the client, you might still be alive on the server (for example if you dodged a missile by server law, but you thought it hit you on your client), just keep playing
    - If you die on the server and the client, just load a save and connect to the server again

## Tips and Tricks

### Adding a favorite server

If you have a favorite server (such as one hosted regularly by one of your friends), you might want to avoid having to type in the IP address and port every time you want to play. An easy way to get around that is to just copy the multiplayer event in `events/multiplayer.lua` to a new file `events/myfriend_server.lua` and change the event accordingly:
- Remove the line that registers the server info button
- Change the label on the connect button to something like "Connect to Favoured"
- Replace the code that calls `tk.input` with your hard-coded values

If successful, it might look something like this:

    --[[
    <?xml version='1.0' encoding='utf8'?>
    <event name="Multiplayer Handler - My favorite server">
     <location>load</location>
     <chance>100</chance>
     <unique />
    </event>
    --]]
    --[[
       Multiplayer Event for my favorite server

       This event makes sure I can connect to my favorite server
    --]]
    local fmt           = require "format"
    local mplayerclient = require "multiplayer.client"
    -- luacheck: globals load (Hook functions passed by name)

    function create ()
        hook.load("load")
    end

    local clientbtn

    local function connectMultiplayer()
        local hostname = "192.168.1.254" -- note: not a real server
        local hostport = "6789"
        local localport = "0"

        local target = fmt.f( "{host}:{port}", { host = hostname, port = hostport } )

        fail = mplayerclient.start( hostname, hostport, localport )
        if fail then
            print("ERROR: " .. fail )
        else
            player.infoButtonUnregister( clientbtn )
        end
    end

    function load()
        clientbtn = player.infoButtonRegister( _("Connect to Favorite Server"), connectMultiplayer, 3)
    end

If this was successful, you can now connect to your favorite server with the click of a button, in this case "Connect to Favorite Server" from the Info menu.

### Removing the "Start MP Server" Button (or the other button)

If you don't intend on hosting a server, you might as well remove the button from your info menu. You can edit the `events/multiplayer.lua` file by simply removing the line that contains the label on the button you want to remove, in this case "Start MP Server".

Likewise, you can do the same thing to the "Connect to Multiplayer" button if you only want to be able to host a server.

