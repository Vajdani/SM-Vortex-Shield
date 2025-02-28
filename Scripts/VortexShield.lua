dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$GAME_DATA/Scripts/game/AnimationUtil.lua" )

---@class PojectileEffect
---@field effect Effect
---@field offset Vec3
---@field rotationAxis Vec3
---@field rotation number

---@class VortexShield : ToolClass
---@field projectileEffects PojectileEffect[]
VortexShield = class()

local renderablesTp = {
    "$CONTENT_DATA/Tools/char_vortexshield_tp.rend"
}

local renderablesFp = {
    "$CONTENT_DATA/Tools/char_vortexshield_fp.rend"
}

sm.tool.preloadRenderables(renderablesTp)
sm.tool.preloadRenderables(renderablesFp)

local defaultProjectile = sm.uuid.new("5e8eeaae-b5c1-4992-bb21-dec5254ce722")
local hasProjectileShape = {}
for k, v in pairs(sm.json.open("$CONTENT_DATA/Objects/Database/ShapeSets/projectileShapes.shapeset").partList) do
    hasProjectileShape[v.uuid] = true
end

local shieldCollisionSize = sm.vec3.new(1.25, 1.25, 0.25)
local effectSize = shieldCollisionSize * 4
local quarterVec = sm.vec3.one() * 0.25

function VortexShield:server_onCreate()
    self.shield = sm.areaTrigger.createBox(sm.vec3.new(1,1,1), sm.vec3.zero())
    self.shield:setSize(shieldCollisionSize)
    self.shield:bindOnProjectile("sv_onProjectile")

    self.caughtProjectiles = {}
end

function VortexShield:server_onDestroy()
    sm.areaTrigger.destroy(self.shield)
end

function VortexShield:server_onFixedUpdate()
    if not sm.exists(self.shield) or not self.handPos then return end

    local char = self.tool:getOwner().character
    if not sm.exists(char) then return end

    local dir = char.direction
    self.shield:setWorldPosition(self.handPos) --+ dir * shieldCollisionSize.z * 0.5)
    self.shield:setWorldRotation(sm.vec3.getRotation(sm.vec3.new(0,0,1), dir))
    self.shield:setSize(shieldCollisionSize)
end

function VortexShield:sv_onProjectile(trigger, hitPos, airTime, velocity, name, source, damage, data, normal, uuid)
    if self.active then
        self.network:sendToClients("cl_onProjectile", {
            position = sm.vec3.new(math.random(-100, 100) * 0.01, math.random(-100, 100) * 0.01, 0), --hitPos - self.handPos,
            uuid = hasProjectileShape[tostring(uuid)] and uuid or defaultProjectile
        })

        --sm.effect.playEffect("Barrier - ShieldImpact", hitPos, sm.vec3.zero(), sm.vec3.getRotation(sm.vec3.new(0,1,0), -velocity:normalize()))

        table.insert(self.caughtProjectiles, { uuid = uuid, damage = damage * 1.2 })
    end

    return self.active
end

function VortexShield:sv_updateActive(active)
    if not active and  #self.caughtProjectiles > 0 then
        local owner = self.tool:getOwner()
        local dir = owner.character.direction
        sm.effect.playEffect("TapeBot - Shoot", self.handPos, sm.vec3.zero(), sm.vec3.getRotation(sm.vec3.new(0,0,1), dir))

        for k, v in pairs(self.caughtProjectiles) do
            sm.projectile.projectileAttack(v.uuid, v.damage, self.handPos, sm.noise.gunSpread(dir, 25) * 130, owner)
        end

        self.caughtProjectiles = {}
    end

    self.network:sendToClients("cl_updateActive", active)
end



function VortexShield:client_onCreate()
    self.equipped = false
    self.wantEquipped = false
    self.active = false

    self.blendTime = 0.2
    self:cl_loadAnimations()

    self.projectileEffects = {}

    local effect = sm.effect.createEffect("ShapeRenderable")
    effect:setParameter("uuid", blk_plastic)
    effect:setParameter("visualization", true)

    self.shieldEffect = effect
end

function VortexShield:cl_loadAnimations()
    self.tpAnimations = createTpAnimations(
		self.tool,
		{
			shield_into = { "shield_into", { nextAnimation = "shield_idle" } },
			shield_idle = { "shield_idle", { looping = true } },
			shield_exit = { "shield_exit", { nextAnimation = "idle" } },
			idle = { "idle", { looping = true } },
		}
	)

    self.isLocal = self.tool:isLocal()
	if self.isLocal then
		self.fpAnimations = createFpAnimations(
			self.tool,
			{
                shield_into = { "shield_into", { nextAnimation = "shield_idle" } },
                shield_idle = { "shield_idle", { looping = true } },
                shield_exit = { "shield_exit", { nextAnimation = "idle" } },
                idle = { "idle", { looping = true } },
            }
		)

        self.fpAnimations.blendSpeed = 0.2
	end
end

function VortexShield:client_onRefresh()
    self:cl_loadAnimations()
end

function VortexShield:client_onUpdate(dt)
	local isSprinting =  self.tool:isSprinting()
	local isCrouching =  self.tool:isCrouching()

	if self.isLocal then
		updateFpAnimations( self.fpAnimations, self.equipped, dt )

        self.tool:setBlockSprint(self.active)
	end

	if not self.equipped then
		if self.wantEquipped then
			self.wantEquipped = false
			self.equipped = true
		end
		return
	end

    self:cl_shieldEffects(dt)

	local crouchWeight = isCrouching and 1.0 or 0.0
	local normalWeight = 1.0 - crouchWeight

	local totalWeight = 0.0
	for name, animation in pairs( self.tpAnimations.animations ) do
		animation.time = animation.time + dt

		if name == self.tpAnimations.currentAnimation then
			animation.weight = math.min( animation.weight + ( self.tpAnimations.blendSpeed * dt ), 1.0 )

			if animation.time >= animation.info.duration - self.blendTime then
				if animation.nextAnimation ~= "" then
					setTpAnimation( self.tpAnimations, animation.nextAnimation, 0.001 )
				end

			end
		else
			animation.weight = math.max( animation.weight - ( self.tpAnimations.blendSpeed * dt ), 0.0 )
		end

		totalWeight = totalWeight + animation.weight
	end

	totalWeight = totalWeight == 0 and 1.0 or totalWeight
	for name, animation in pairs( self.tpAnimations.animations ) do
		local weight = animation.weight / totalWeight
		-- if name == "idle" then
		-- 	self.tool:updateMovementAnimation( animation.time, weight )
		-- elseif animation.crouch then
		-- 	self.tool:updateAnimation( animation.info.name, animation.time, weight * normalWeight )
		-- 	self.tool:updateAnimation( animation.crouch.name, animation.time, weight * crouchWeight )
		-- else
			self.tool:updateAnimation( animation.info.name, animation.time, weight )
		-- end
	end
end

function VortexShield:client_onEquip()
    self.wantEquipped = true

    self.active = false

	self.tool:setTpRenderables( renderablesTp )
    if self.isLocal then
		self.tool:setFpRenderables( renderablesFp )
    end
end

function VortexShield:client_onUnequip()
    self.wantEquipped = false
	self.equipped = false

    if self.active then
		setTpAnimation( self.tpAnimations, "shield_exit" )
        if self.isLocal then
			swapFpAnimation( self.fpAnimations, "shield_into", "shield_exit", 0.2 )
        end
    end

    self.active = false
    self:cl_closeShield()
end

function VortexShield:client_onEquippedUpdate(lmb, rmb, f)
    local active = f --lmb == 1 or lmb == 2
    if active ~= self.active then
        self.network:sendToServer("sv_updateActive", active)
        self.active = active
    end

    return true, f --true, true
end

function VortexShield:cl_updateActive(active)
    self.active = active

    if not active then
        self:cl_closeShield()
    end

    local anim = active and "shield_idle" or "idle"
    setTpAnimation( self.tpAnimations, anim, 10 )
    if self.isLocal then
        setFpAnimation(self.fpAnimations, anim, 0.25)
    end
end

function VortexShield:cl_onProjectile(args)
    local effect = sm.effect.createEffect("ShapeRenderable")
    effect:setParameter("uuid", args.uuid)
    effect:setScale(quarterVec)
    effect:start()

    local obj = {
        effect = effect,
        offset = args.position,
        rotationAxis = sm.vec3.new(math.random(-100, 100) * 0.01, math.random(-100, 100) * 0.01, math.random(-100, 100) * 0.01):normalize(),
        rotation = 0
    }

    table.insert(self.projectileEffects, obj)
end

function VortexShield:cl_shieldEffects(dt)
    local char = self.tool:getOwner().character
    local velocity = sm.vec3.zero()
    local dir = sm.vec3.new(0,1,0)
    if sm.exists(char) then
        velocity = char.velocity
        dir = char.direction
    end

    local isFp = self.tool:isInFirstPersonView()
    self.handPos = (isFp and self.tool:getFpBonePos("jnt_left_weapon") or self.tool:getTpBonePos("jnt_left_weapon")) + velocity * dt + dir * shieldCollisionSize.z * 0.5

    self.shieldEffect:setPosition(self.handPos)

    local shieldRot = sm.vec3.getRotation(sm.vec3.new(0,0,1), self.tool:getDirection())
    self.shieldEffect:setRotation(shieldRot)

    local scale = isFp and 0.15 or 0.5
    self.shieldEffect:setScale(effectSize * scale)

    local playing = self.shieldEffect:isPlaying()
    if self.active and not playing then
        self.shieldEffect:start()
    elseif not self.active and playing then
        self.shieldEffect:stop()
    end

    if self.active then
        for k, v in pairs(self.projectileEffects) do
            v.rotation = v.rotation + dt

            local effect = v.effect
            effect:setPosition(self.handPos + shieldRot * v.offset * (isFp and 0.3 or 1))
            effect:setRotation(shieldRot * sm.quat.angleAxis(v.rotation, v.rotationAxis))
            effect:setScale(quarterVec * scale)
        end
    end
end

function VortexShield:cl_closeShield()
    for k, v in pairs(self.projectileEffects) do
        v.effect:destroy()
    end

    self.projectileEffects = {}
end