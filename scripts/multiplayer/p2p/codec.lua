-- MP2P/1 packet codec. This module is deliberately independent of Naev.
local codec = {}

codec.VERSION = "MP2P/1"
codec.MAX_PACKET = 16 * 1024

local function escape ( value )
   return tostring(value):gsub("([^%w%-%._~])", function ( c )
      return string.format("%%%02X", string.byte(c))
   end)
end

local function unescape ( value )
   local at=1
   while true do
      local mark=value:find("%",at,true)
      if not mark then break end
      if not value:sub(mark+1,mark+2):match("^%x%x$") then return nil,"invalid escape" end
      at=mark+3
   end
   return (value:gsub("%%(%x%x)", function ( hex )
      return string.char(tonumber(hex, 16))
   end))
end

codec.escape = escape
codec.unescape = unescape

local valid_types = {
   hello=true, query=true, hint=true, punch=true, claim=true, leave=true,
   member_heartbeat=true,host_query=true,player_control=true,npc_interest=true,
   activity_query=true, activity=true,
   contestant_register=true, contestant_query=true,
   contestant_entry=true, contestant_done=true,
   player_manifest=true, player_state=true, chat=true,
   npc_manifest=true, npc_done=true, npc_add=true, npc_remove=true, npc_state=true,
   npc_control=true, npc_focus_state=true,
   craft_manifest=true, craft_state=true, craft_remove=true, craft_order=true,
   object_create=true, object_query=true, object_entry=true, object_done=true,
   object_delete=true, object_deleted=true, object_result=true,
   resync=true,
}

local required = {
   hello={"node","cap"}, query={"node","system"},
   activity_query={"node"}, activity={"node","entries"},
   contestant_register={"node","division","ship","name","outfits","slots"},
   contestant_query={"node","division","request","limit"},
   contestant_entry={"node","contestant","division","request","ship","name",
      "outfits","slots"},
   contestant_done={"node","division","request","count"},
   hint={"node","system","host","endpoint","claim","ttl"},
   punch={"node","system","peer","endpoint"},
   claim={"node","system","claim","endpoint"}, leave={"node","system"},
   member_heartbeat={"node","system","visit","seq"},
   host_query={"node","system","visit","seq"},
   player_control={"node","system","visit","entity","seq","target",
      "primary","secondary","x","y","vx","vy","dir"},
   npc_interest={"node","system","visit","seq","target"},
   player_manifest={"node","system","entity","ship","name"},
   player_state={"node","system","entity","seq","x","y","vx","vy","dir",
      "armour","shield","stress"},
   chat={"node","system","seq","text"},
   npc_manifest={"node","system","claim","seq","entities"},
   npc_done={"node","system","claim","seq","snapshot","population","count"},
   npc_control={"node","system","claim","seq","entities"},
   npc_add={"node","system","claim","entity","seq","ship","name","faction"},
   npc_remove={"node","system","claim","entity","seq"},
   npc_state={"node","system","claim","seq","entities"},
   npc_focus_state={"node","system","claim","seq","entities"},
   craft_manifest={"node","system","owner","entity","seq","ship","name"},
   craft_state={"node","system","owner","seq","entities"},
   craft_remove={"node","system","owner","entity","seq"},
   craft_order={"node","system","owner","seq","order"},
   object_create={"node","request","object_id","object"},
   object_query={"node","system","request"},
   object_entry={"node","request","object"},
   object_done={"node","system","request","count"},
   object_delete={"node","request","object_id"},
   object_deleted={"node","object_id","revision"},
   object_result={"node","request","action","ok","code","object_id","revision"},
   resync={"node","system","seq","scope"},
}

local numeric = {
   seq={0, 9007199254740991}, snapshot={0,9007199254740991},
   baseline={0,9007199254740991},
   population={0,9007199254740991},
   route_seq={0,9007199254740991},
   hops={0,8}, control_seq={0,9007199254740991}, ttl={1, 60},
   division={1,3}, request={0,9007199254740991}, limit={1,11},
   count={0,4096}, revision={1,9007199254740991}, ok={0,1},
   x={-1e9,1e9}, y={-1e9,1e9}, vx={-1e7,1e7}, vy={-1e7,1e7},
   dir={-1e6,1e6}, accel={0,1}, primary={0,1}, secondary={0,1},
   weapset={1,10},
   armour={0,1e9}, shield={0,1e9}, stress={0,1e9}, energy={0,1e9},
}

local function validate ( message )
   if not valid_types[message.type] then return nil, "unknown type" end
   for _index, key in ipairs(required[message.type]) do
      if message[key] == nil or message[key] == "" then
         return nil, "missing " .. key
      end
   end
   if message.cap and message.cap ~= "player" and message.cap ~= "directory" then
      return nil, "invalid capability"
   end
   if message.features and (#message.features>240
         or message.features:find("[^%w_,%-]")) then
      return nil, "invalid features"
   end
   if message.links then
      if #message.links>4096 or (message.links~="-"
            and message.links:find("[^%x,]")) then
         return nil,"invalid links"
      end
      if message.links~="-" then
         local count=0
         for node in (message.links..","):gmatch("(.-),") do
            count=count+1
            if node=="" or #node>64 or not node:match("^[%x]+$")
                  or count>64 then
               return nil,"invalid links"
            end
         end
      end
   end
   if message.track and (#message.track>64
         or message.track:find("[^%w_%-]")) then
      return nil, "invalid track"
   end
   if message.type == "hello" and message.cap == "player" then
      if type(message.name) ~= "string" or message.name == "" then return nil, "missing name" end
   end
   if message.name and (#message.name > 240 or message.name:find("[%z\1-\31\127]")) then
      return nil, "invalid name"
   end
   if message.text and (#message.text>1024
         or message.text:find("[%z\1-\8\11\12\14-\31\127]")) then
      return nil,"invalid text"
   end
   if message.ship and (#message.ship > 240
         or message.ship:find("[%z\1-\31\127]")) then
      return nil, "invalid ship"
   end
   if message.outfits and (#message.outfits > 12000
         or message.outfits:find("[%z\1-\31\127]")) then
      return nil, "invalid outfits"
   end
   if message.slots and (#message.slots > 12000
         or message.slots:find("[%z\1-\31\127]")) then
      return nil, "invalid slots"
   end
   if message.weapsets and (#message.weapsets>4096
         or message.weapsets:find("[^%d:;%.]")) then
      return nil,"invalid weapon sets"
   end
   if message.ship_fallbacks and (#message.ship_fallbacks > 2048
         or message.ship_fallbacks:find("[%z\1-\31\127]")) then
      return nil, "invalid ship fallbacks"
   end
   if message.ai and (#message.ai > 240 or message.ai:find("[^%w_%-]")) then
      return nil, "invalid ai"
   end
   if message.task and (#message.task > 240 or message.task:find("[^%w_%-]")) then
      return nil, "invalid task"
   end
   if message.goal and (#message.goal > 512 or message.goal:find("[%z\1-\31\127]")) then
      return nil, "invalid goal"
   end
   if message.system and (#message.system > 240 or message.system:find("[%z\1-\31\127]")) then
      return nil, "invalid system"
   end
   if message.entries and (#message.entries > 12000
         or message.entries:find("[%z\1-\31\127]")) then
      return nil, "invalid entries"
   end
   if message.object and (#message.object > 12000
         or message.object:find("[%z\1-\31\127]")) then
      return nil, "invalid object"
   end
   if message.object_id and (#message.object_id > 128
         or not message.object_id:match("^[%w_%-]+$")) then
      return nil, "invalid object id"
   end
   if message.action and message.action~="create"
         and message.action~="delete" then return nil,"invalid object action" end
   if message.code and (#message.code>32
         or not message.code:match("^[%w_%-]+$")) then
      return nil,"invalid result code"
   end
   if message.claim and (#message.claim > 128 or message.claim:find("[%z\1-\31\127]")) then
      return nil, "invalid claim"
   end
   if message.visit and (not message.visit:match("^[%x]+$") or #message.visit>64) then
      return nil,"invalid visit"
   end
   if message.node and (#message.node>64
         or not message.node:match("^[%x]+$")) then return nil, "invalid node" end
   if message.via and (#message.via>64
         or not message.via:match("^[%x]+$")) then return nil,"invalid relay" end
   if message.contestant and (#message.contestant>64
         or not message.contestant:match("^[%x]+$")) then
      return nil, "invalid contestant"
   end
   if (message.type=="player_manifest" or message.type=="player_state"
         or message.type=="player_control")
         and message.entity~=message.node then
      return nil, "player entity does not match node"
   end
   if message.host and (#message.host>64
         or not message.host:match("^[%x]+$")) then return nil, "invalid host" end
   if message.peer and (#message.peer>64
         or not message.peer:match("^[%x]+$")) then return nil, "invalid peer" end
   if message.owner and (#message.owner>64
         or not message.owner:match("^[%x]+$")) then return nil, "invalid owner" end
   if message.recipient and (#message.recipient>64
         or not message.recipient:match("^[%x]+$")) then
      return nil,"invalid recipient"
   end
   if message.accepted_host and (#message.accepted_host>64
         or not message.accepted_host:match("^[%x]+$")) then
      return nil,"invalid accepted host"
   end
   if message.entity and (#message.entity>255 or message.entity:find("[%z\1-\31\127]")) then
      return nil, "invalid entity"
   end
   if (message.type=="craft_manifest" or message.type=="craft_remove")
         and message.entity:sub(1,#message.owner+1)~=message.owner..":" then
      return nil,"craft entity does not match owner"
   end
   if message.target and (#message.target>255
         or message.target:find("[%z\1-\31\127]")) then
      return nil,"invalid target"
   end
   if message.endpoint and (not message.endpoint:match("^[^%s:]+:%d+$") or #message.endpoint > 255) then
      return nil, "invalid endpoint"
   end
   if message.order and message.order~="e_attack" and message.order~="e_hold"
         and message.order~="e_return" and message.order~="e_clear" then
      return nil, "invalid order"
   end
   if message.scope and message.scope~="all" and message.scope~="npc"
         and message.scope~="craft" then
      return nil, "invalid scope"
   end
   if message.reason and message.reason~="absent" and message.reason~="death"
         and message.reason~="exploded" and message.reason~="jump"
         and message.reason~="land" and message.reason~="removed" then
      return nil,"invalid removal reason"
   end
   if message.via then
      if not message.visit or message.route_seq==nil or message.hops==nil then
         return nil,"incomplete route"
      end
   elseif message.route_seq~=nil or message.hops~=nil then
      return nil,"incomplete route"
   end
   for key, bounds in pairs(numeric) do
      if message[key] ~= nil then
         local n = tonumber(message[key])
         if not n or n ~= n or n < bounds[1] or n > bounds[2] then
            return nil, "invalid " .. key
         end
         message[key] = n
      end
   end
   return message
end

codec.validate = validate

function codec.encode ( message )
   local checked, err = validate(message)
   if not checked then return nil, err end
   local keys = {}
   for key in pairs(message) do
      if key ~= "type" then table.insert(keys, key) end
   end
   table.sort(keys)
   local lines = { codec.VERSION .. " " .. message.type }
   for _index, key in ipairs(keys) do
      table.insert(lines, escape(key) .. "=" .. escape(message[key]))
   end
   local packet = table.concat(lines, "\n") .. "\n"
   if #packet > codec.MAX_PACKET then return nil, "packet too large" end
   return packet
end

function codec.decode ( packet )
   if type(packet) ~= "string" then return nil, "packet is not a string" end
   if #packet > codec.MAX_PACKET then return nil, "packet too large" end
   local header, body = packet:match("^([^\n]+)\n?(.*)$")
   if not header then return nil, "missing header" end
   local version, kind = header:match("^(%S+) ([%w_]+)$")
   if version ~= codec.VERSION then return nil, "incompatible version" end
   local message = { type=kind }
   for line in body:gmatch("([^\n]+)") do
      local raw_key, raw_value = line:match("^([^=]+)=(.*)$")
      if not raw_key then return nil, "invalid field" end
      local key, keyerr = unescape(raw_key)
      local value, valueerr = unescape(raw_value)
      if not key then return nil, keyerr end
      if not value then return nil, valueerr end
      if message[key] ~= nil or key == "type" then return nil, "duplicate field" end
      message[key] = value
   end
   return validate(message)
end

return codec
