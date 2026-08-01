-- User preferences and runtime settings for the P2P multiplayer session.
local settings = {}

settings.DEFAULT_DIRECTORY = "79.76.110.205:60939"
settings.DEFAULT_LISTEN_PORT = 0

settings.MAX_EVENTS_PER_FRAME = 40
settings.HANDSHAKE_TIMEOUT = 10
settings.TRANSPORT_IDLE_TIMEOUT = 7
settings.DIRECTORY_RESPONSE_TIMEOUT = 10
settings.NETWORK_STATUS_PENDING_TIMEOUT = 2
settings.NETWORK_STATUS_RECHECK_INTERVAL = 0.25
settings.WORLD_INTERVAL = 1/15
settings.WORLD_CHANNEL = 1
settings.CANONICAL_CHANNEL = 2
settings.HEARTBEAT_INTERVAL = 1
settings.CLAIM_INTERVAL = 5
settings.LIVENESS_INTERVAL = 1
settings.REDIAL_INTERVAL = 2
settings.MANIFEST_INTERVAL = 0.1
settings.MANIFEST_QUERY_COOLDOWN = 1
settings.HOST_ALONE_GRACE = 4
settings.AGGRESSION_GRACE = 20
settings.ACTIVITY_QUERY_INTERVAL = 30
settings.ACTIVITY_RETENTION = 15*60
settings.AMBIENT_INSPECTION_CAP = 4
settings.PARTICIPANT_VISIBILITY_CAP = 8
settings.RECONCILE_DISTANCE = 2000
settings.RECONCILE_POSITION_BIAS = 0.5

-- ENet's default MTU is 1392 bytes and Naev's Lua binding does not expose
-- unreliable fragmentation. Leave room for protocol and path overhead.
settings.WORLD_PACKET_BUDGET = 1200

settings.PLAYER_RECONCILE = {
   position_gain=1.5,correction_speed=400,velocity_rate=12,
   acceleration=2400,direction_rate=30,direction_speed=8,
   max_prediction=0,rest_source_speed=0,follow_velocity=true,
}
settings.NPC_RECONCILE = {
   position_gain=1.5,correction_speed=250,velocity_rate=8,
   acceleration=600,direction_rate=30,direction_speed=8,
   max_dt=0.25,max_prediction=0.125,prediction_fraction=0.5,
}
settings.CRAFT_RECONCILE = {
   position_gain=2,correction_speed=400,velocity_rate=10,
   acceleration=1200,direction_rate=30,direction_speed=8,
   max_dt=0.25,max_prediction=0.125,prediction_fraction=0.5,
}

local function random_id ()
   local parts={}
   for _index=1,4 do
      parts[#parts+1]=string.format("%08x",rnd.rnd(0,0x7fffffff))
   end
   return table.concat(parts)
end

settings.random_id=random_id

function settings.normalize_endpoint ( endpoint )
   if type(endpoint)~="string" then return nil end
   endpoint=endpoint:match("^%s*(.-)%s*$")
   if endpoint=="" then return "" end
   local host,port=endpoint:match("^([^%s:]+)%s*:%s*(%d+)$")
   if not host then host,port=endpoint:match("^(%S+)%s+(%d+)$") end
   port=tonumber(port)
   if not host or not port or port<1 or port>65535 then return nil end
   return host..":"..tostring(math.floor(port))
end

function settings.defaults ( value )
   value=value or {}
   value.enabled=value.enabled==true
   value.listen_port=math.max(0,
      math.min(65535,tonumber(value.listen_port)
         or settings.DEFAULT_LISTEN_PORT))
   local directory=value.directory==nil
      and settings.DEFAULT_DIRECTORY or value.directory
   value.directory=settings.normalize_endpoint(directory) or ""
   local bootstrap={}
   for _index,endpoint in ipairs(value.bootstrap or {}) do
      local normalized=settings.normalize_endpoint(endpoint)
      if normalized and normalized~="" then
         bootstrap[#bootstrap+1]=normalized
      end
   end
   value.bootstrap=bootstrap
   value.recent=value.recent or {}
   value.node_id=value.node_id or random_id()
   return value
end

return settings
