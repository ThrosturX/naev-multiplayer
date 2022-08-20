-- luacheck: globals: REMOTE_CONTROL_ACCEL REMOTE_CONTROL_SWITCH_WEAPSET REMOTE_CONTROL_SHOOT (Hook functions passed by name)
--
-- swifter control rate than usual because we are reactive
control_rate = 0.16

function REMOTE_CONTROL_ACCEL ( state )
    if state == 1 then
        mem.rc_accel = 1.0
    else
        mem.rc_accel = 0.0
--      ai.poptask()
    end
    ai.accel( mem.rc_accel )
--  print("STATE " .. tostring(state) .. " RCA " .. tostring(mem.rc_accel) ) 
end

function REMOTE_CONTROL_SWITCH_WEAPSET ( ws_number )
    ai.weapset( ws_number )
    ai.poptask()
end

function REMOTE_CONTROL_SHOOT ( secondary )
    if secondary then
        mem.rc_scoot = true
    else
        mem.rc_shoot = true
    end
--  print( "rc shoot " .. tostring(secondary) )
    ai.shoot( secondary )
    ai.accel( mem.rc_accel )
    ai.poptask()
end

-- Required "control" function
function control ()
   local task = ai.taskname()
-- print("got task " .. tostring(task) )
-- print("discarding " .. tostring(task) )
   if not mem.rc_accel or mem.rc_accel == 0 then
        ai.accel ( 0 )
    else
        ai.accel ( mem.rc_accel )
   end

   if mem.rc_shoot == true then
 --    ai.shoot()
       mem.rc_shoot = 0
--     print("SHOOT 1!")
   end

   if mem.rc_scoot == true then
--     ai.shoot( true )
       mem.rc_scoot = 0
--     print("SHOOT 2!")
   end

   if true then
       return
   end
   
   if task then
      local cc = control_funcs[ task ]
      if cc then
         if cc() then
            return
         end
      end
   end
end
--
-- Required "attacked" function
function attacked ( _attacker )
    return -- do nothing
end

-- Required "create" function
function create ()
    mem.rc_accel = 0.0
    mem.rc_shoot = 0
    mem.rc_scoot = 0
end
