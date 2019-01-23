--[[
	Projectile library for creating moving projectiles instead of instant hitscans.
	Projectiles created as GMObjects, with managed physics and logic for what collisions to pay attention to
	Provides ability to set amount of enemies and/or walls to pierce through, and what to do to actors when you do pierce them
	Three preset methods, Grenade, Bullet, and Rocket, can be used for quickly creating common types of projectile. (ROCKET NOT YET IMPLEMENTED)
	Alternatively, you can use Projectile.Custom(args) (more complex, but greater control) to make your own type of projectile. If you do this, I would recommend creating a wrapper method similar to the three preset methods seen below.
]]


local json = require("json")
local inspect = require("inspect")

local Projectile = {}
local PROJECTILE_ARGS = {}

-- get the actor that fired the projectile
function Projectile.getParent(projectileInstance)
	if projectileInstance:isValid() then
		local parent = Object.findInstance(projectileInstance:get("btd_projectile_parent"))
		if parent and parent:isValid() then return parent end
	end
end

-- collision checking, get list of actor IDs
function getActorCollisions(instance)
	local collisions = {}
	local allActors = ObjectGroup.find("actors"):findAll()
	for i=1,#allActors do
		local actor = allActors[i]
		if actor:isValid()
		  and actor:get("team") ~= instance:get("btd_projectile_team")
		  and instance:collidesWith(actor, instance.x, instance.y) then
			collisions[""..actor.id] = true --coerce into string for json encoding
		end
	end
	return collisions
end

--[[ internal func to validate the types and inputs of arguments, using a validation table
	this stuff has nothing to do with the projectiles working, it's just for fail-faster, and generating clearer errors
	contains logic for:
	type validation
	required / optional parameters, with defaults for optional
	validating parameters with functions
	sanitising values received (occurs after type validation, but before custom validation functions)
	recursively validating tables passed in
]]
function validateArguments(arguments, parameters)
	local msg = "Validation errors:"
	for param,validation in pairs(parameters) do
		if (type(validation.optional) == "function" and validation.optional(arguments) or validation.optional == true) and arguments[param] == nil then -- optional and missing, set defaults and continue
			if validation.default ~= nil then 
				arguments[param] = type(validation.default) == "function" and validation.default(arguments) or validation.default
			end
		elseif (arguments[param] == nil and not validation.optional) -- non-optional and missing, error
		or not isa(arguments[param], validation.type) --wrong type, error
		then
			msg = msg.."\n"..param.." argument must be provided, of type "..validation.type..". Received: "..type(arguments[param])
		else -- provided, and correct type
			if validation.sanitise then
				arguments[param] = validation.sanitise(arguments[param])
			end
			if validation.validate then 
				subValidation, subMsg = validation.validate(arguments[param])
				if not subValidation then msg = msg.."\n"..subMsg end
			end
			
			if validation.type == "table" then
				local subValidation, subMsg = validateArguments(arguments[param], validation.fields)
				if not subValidation then msg = msg.."\n"..subMsg end
			end
		end
	end
	return (msg == "Validation errors:"), msg
end

-- enums
Projectile.DamagerType = {BULLET = 0, EXPLOSION = 1}
Projectile.BounceType = {MAP = 1, ENEMIES = 2, BOTH = 3}

-- specify arguments for creating damagers. Damagers can be created in the following circumstances, all optional:
-- when passing through an actor, with pierce enabled and a pierce damager set
-- TODO: when bouncing off an actor or wall, with bounce enabled and a bounce damager set
-- TODO: on entering or leaving a wall, with phasing enabled and a phaseStart/End damager set
-- when the projectile ends (either by distance travelled, timer, or contact with something it does not pierce/phase/bounce off)
local damagerParameters = {
	damagerType = {type = "number", optional = false, sanitise = function(arg) return math.floor(arg) end, validate = function(arg) return (arg == Projectile.DamagerType.BULLET or arg == Projectile.DamagerType.EXPLOSION), "damagerType argument must be Projectile.DamagerType.BULLET (0) or Projectile.DamagerType.EXPLOSION (1). Received: "..arg end},
	direction = {type = "number", optional = true, default = function(args) return args.damagerType == Projectile.DamagerType.BULLET and 0 or nil end}, -- default to 0 for collision bullets
	distance = {type = "number", optional = true, default = function(args) return args.damagerType == Projectile.DamagerType.BULLET and 1 or nil end}, --default to 1 for collision bullets
	explosionSprite = {type = "Sprite", optional = true},
	hitSprite = {type = "Sprite", optional = true},
	explosionWidth = {type = "number", optional = function(args) return args.damagerType ~= Projectile.DamagerType.EXPLOSION end},
	explosionHeight = {type = "number", optional = function(args) return args.damagerType ~= Projectile.DamagerType.EXPLOSION end},
	damage = {type = "number", optional = false},
	mlDamagerProperties = {type = "number", optional = true} 
}

-- specify what arguments can or should be provided when creating a custom projectile
-- if using one of the "preset" functions then the arguments are clearly defined in those functions
local projectileParameters = {
	name = {type = "string", optional = false},
	sprite = {type = "Sprite", optional = false},			--sprite for the projectile
	pierceCount = {type = "number", optional = true},	--how many enemies to pierce, -1 for infinite
	phaseCount = {type = "number", optional = true},		--how many walls to pierce, -1 for infinite
	bounceCount = {type = "number", optional = true},	--how many times to bounce off things it does not pierce, -1 for infinite
	distance = {type = "number", optional = function(args) return args.timer and args.timer > 0 end},		--how far away from the player the projectile can go before being destroyed
	timer = {type = "number", optional = function(args) return args.distance and args.distance > 0 end},			--how many frames before destroying, if not already collided
	continuousHitDelay = {type = "number", optional = true, default = -1},			--how many frames between hits when continually colliding with an actor
	bounceType = {type = "number", optional = true, sanitise = function(arg) return math.floor(arg) end, validate = function(arg) return (arg > 0 and arg < 4), "bounceType argument must be a Projectile.BounceType: MAP (1), ENEMY (2), or BOTH (3). Received: "..arg end},			--whether to bounce off of enemies, walls, or both (when it is not due to pierce/phase them)
	pierceDamagerProperties = {type = "table", optional = true, fields = damagerParameters},			--damager to be generated when piercing an enemy
	bounceDamagerProperties = {type = "table", optional = true, fields = damagerParameters},			--TODO:damager to be generated when bouncing off an enemy or wall
	phaseStartDamagerProperties = {type = "table", optional = true, fields = damagerParameters},		--TODO:damager to be generated when entering a wall
	phaseEndDamagerProperties = {type = "table", optional = true, fields = damagerParameters},		--TODO:damager to be generated when leaving a wall
	endDamagerProperties = {type = "table", optional = true, fields = damagerParameters}				--damager for the final hit / explosion fired when the projectile is destroyed
}

function projectileInit(projectileInstance)
	local accessor = projectileInstance:getAccessor() -- TODO: test if can store table data here
	-- set up variables that change on an instance-specific basis
	local args = PROJECTILE_ARGS[projectileInstance:getObject():getName()]
	if args.timer and args.timer > 0 then accessor["btd_projectile_timer"]= args.timer end
	if args.pierceCount then accessor["btd_projectile_pierceCount"] = args.pierceCount end
	if args.phaseCount then accessor["btd_projectile_phaseCount"] = args.phaseCount end
	if args.distance then
		accessor["btd_projectile_distance"] = args.distance
		accessor["btd_projectile_travelled"] = 0
		accessor["btd_projectile_lastX"] = projectileInstance.x
		accessor["btd_projectile_lastY"] = projectileInstance.y
	end
end

function projectileStep(projectileInstance)
	local accessor = projectileInstance:getAccessor()
	local args = PROJECTILE_ARGS[projectileInstance:getObject():getName()]
	--print("step")
	--calculate any horizontal acceleration, as not accounted for by GameMaker
	local acceleration = accessor["btd_projectile_ax"]
	if acceleration then
		local speed = accessor["hspeed"]
		accessor["hspeed"] = speed + acceleration
	end
	
	-- check for actor collisions
	local pierceCount = accessor["btd_projectile_pierceCount"]
	if pierceCount == nil or pierceCount >= 0 then --need to watch for collisions
		local currentCollisions = getActorCollisions(projectileInstance)
		if next(currentCollisions) then
			local processedCollisions = json.decode(accessor["btd_projectile_processedActorCollisions"] or "[]")
			-- check for new collisions, subtract from count or explode
			for actorId,exists in pairs(currentCollisions) do
				local continuousHit = false	--tells us whether we need to hit because of the continuous hit settings
				local newPierce = false		-- tells us whether to deduct from the pierceCount
				local actor = nil			-- will only be set if we need to do continuous hits, to store a new hitDelay on the actor
				
				if processedCollisions[actorId] then -- existing collision, process "continuous hit" logic to see if needs another hit
					newPierce = false
					if args.continuousHitDelay >= 0 then
						actor = ObjectGroup.find("actors"):findInstance(actorId)
						local hitTimer = actor:get("btd_projectile_continuousHitDelay")
						continuousHit = (hitTimer == nil or hitTimer <= 0)
						
						if not continuousHit then -- no hit yet, subtract from the hit delay timer
							actor:set("btd_projectile_continuousHitDelay", hitTimer - 1)
						end
					end
				else	-- new collision
					newPierce = true
				end
				
				if newPierce or continuousHit then
					if args.pierceDamagerProperties then -- create pierce damager
						local parent = Projectile.getParent(projectileInstance)
						local damagerProperties = args.pierceDamagerProperties
						if damagerProperties.damagerType == Projectile.DamagerType.EXPLOSION then
							parent:fireExplosion(projectileInstance.x, projectileInstance.y,
							damagerProperties.explosionWidth/19,
							damagerProperties.explosionHeight/4,
							damagerProperties.damage,
							damagerProperties.explosionSprite,
							damagerProperties.hitSprite,
							damagerProperties.mlDamagerProperties)
						else
							local bullet = parent:fireBullet(projectileInstance.x, projectileInstance.y,
							damagerProperties.direction,
							damagerProperties.distance,
							damagerProperties.damage,
							damagerProperties.hitSprite,
							damagerProperties.mlDamagerProperties
							)
							bullet:set("specific_target", actorId)
						end
					end
					if pierceCount == nil or pierceCount == 0 then -- if that was the last pierce, destroy projectile
						projectileInstance:destroy()
						return
					end
					if newPierce then accessor["btd_projectile_pierceCount"] = pierceCount -1 end-- subtract from remaining pierces
					if actor then actor:set("btd_projectile_continuousHitDelay", args.continuousHitDelay) end
				end
			end
		end
		--store current collisions for next check
		accessor["btd_projectile_processedActorCollisions"] = json.encode(currentCollisions)
	end
	
	-- check for map collisions
	local phaseCount = accessor["btd_projectile_phaseCount"]
	if phaseCount == nil or phaseCount >= 0 then --need to watch for collisions
		local alreadyPhasing = accessor["btd_projectile_alreadyPhasing"]
		if projectileInstance:collidesMap(projectileInstance.x, projectileInstance.y) then
			--collision, check if currently mid-phase (not a new collision)
			if not alreadyPhasing then -- new collision,  explode if nil or 0, otherwise subtract and set to ignore current collision
				if (phaseCount == nil or phaseCount == 0) then
					projectileInstance:destroy()
					return
				end
				accessor["btd_projectile_phaseCount"] = phaseCount -1
				accessor["btd_projectile_alreadyPhasing"] = 1
			end
		elseif alreadyPhasing then --just exited phase, reset ready for future checks
			accessor["btd_projectile_alreadyPhasing"] = nil
		end
	end
	
	--check if timer expired
	local timer = accessor["btd_projectile_timer"]
	if timer then
		if timer <= 0 then
			projectileInstance:destroy()
			return
		end
		accessor["btd_projectile_timer"] = timer - 1
	end
	
	--check if distance travelled
	local distance = accessor["btd_projectile_distance"]
	if distance then
		local currentDistance = accessor["btd_projectile_travelled"]
		local lastX = accessor["btd_projectile_lastX"]
		local lastY = accessor["btd_projectile_lastY"]
		local deltaX = math.abs(projectileInstance.x - lastX)
		local deltaY = math.abs(projectileInstance.y - lastY)
		local travelled = math.sqrt(deltaX*deltaX + deltaY*deltaY)
		if currentDistance + travelled >= distance then
			projectileInstance:destroy()
			return
		end
		accessor["btd_projectile_travelled"] = currentDistance + travelled
		
		accessor["btd_projectile_lastX"] = projectileInstance.x
		accessor["btd_projectile_lastY"] = projectileInstance.y
	end
end

function projectileDestroy(projectileInstance)
	--print("destroy")
	if not PROJECTILE_ARGS[projectileInstance:getObject():getName()].endDamagerProperties then return end
	local parent = Projectile.getParent(projectileInstance)
	local damagerProperties = PROJECTILE_ARGS[projectileInstance:getObject():getName()].endDamagerProperties
	if damagerProperties.damagerType == Projectile.DamagerType.EXPLOSION then
		parent:fireExplosion(projectileInstance.x, projectileInstance.y,
		damagerProperties.explosionWidth/19,
		damagerProperties.explosionHeight/4,
		damagerProperties.damage,
		damagerProperties.explosionSprite,
		damagerProperties.hitSprite,
		damagerProperties.mlDamagerProperties)
	else
		parent:fireBullet(projectileInstance.x, projectileInstance.y,
		damagerProperties.direction,
		damagerProperties.distance,
		damagerProperties.damage,
		damagerProperties.hitSprite,
		damagerProperties.mlDamagerProperties)
	end
end

function Projectile.Custom(args)
	assert(validateArguments(args,
	projectileParameters))
	local projectileObject = Object.new(args.name)
	projectileObject.sprite = args.sprite
	PROJECTILE_ARGS[args.name] = args
	projectileObject:addCallback("create", projectileInit)
	projectileObject:addCallback("step", projectileStep)
	projectileObject:addCallback("destroy", projectileDestroy)
	return projectileObject
end

function Projectile.Grenade(name, sprite, pierceCount, bounceCount, timer, explosionSprite, explosionWidth, explosionHeight, damage)
	return Projectile.Custom({
		name = name,
		sprite = sprite,
		pierceCount = pierceCount,
		bounceCount = bounceCount,
		timer = timer,
		endDamagerProperties = {
			damagerType = Projectile.DamagerType.EXPLOSION,
			explosionSprite = explosionSprite,
			explosionWidth = explosionWidth,
			explosionHeight = explosionHeight,
			damage = damage
		}
	})
end

function Projectile.Rocket(name, sprite, distance, explosionSprite, explosionWidth,  explosionHeight, damage)
	return Projectile.Custom({
		name = name,
		sprite = sprite,
		distance = distance,
		endDamagerProperties {
			damagerType = Projectile.DamagerType.EXPLOSION,
			explosionSprite = explosionSprite,
			explosionWidth = explosionWidth,
			explosionHeight = explosionHeight,
			damage = damage
		}
	})
end

function Projectile.Bullet(name, sprite, hitSprite, pierceCount, phaseCount, distance, damage)
	return Projectile.Custom({
		name = name,
		sprite = sprite,
		pierceCount = pierceCount,
		phaseCount = phaseCount,
		distance = distance,
		pierceDamagerProperties = {
			damagerType = Projectile.DamagerType.BULLET,
			hitSprite = hitSprite,
			damage = damage
		}
	})
end


-- specify what arguments can or should be provided for firing the projectile
local fireParameters = {
	projectileObject = {type = "GMObject", optional = false},
	x = {type = "number", optional = false},
	y = {type = "number", optional = false},
	parent = {type = "Instance", optional = false},
	direction = {type = "number", optional = false},
	velocity = {type = "number", optional = false},
	physics = {type = "table", optional = true, default = {ax=0, ay=0},
		fields = {
			ax = {type = "number", optional = true, default = 0},
			ay = {type = "number", optional = true, default = 0}
		}
	}
}

-- create and "fire" a projectile instance
function Projectile.fire(projectileObject, x, y, parent, direction, velocity, physics)
	assert(validateArguments({projectileObject = projectileObject, x = x, y = y, parent = parent, direction = direction, velocity = velocity, physics = physics},
	fireParameters))
	local projectileInstance = projectileObject:create(x,y)
	local accessor = projectileInstance:getAccessor()
	--set movement
	projectileInstance.angle = direction
	local vy = math.sin(math.rad(direction)) * velocity
	local vx = math.cos(math.rad(direction)) * velocity
	accessor["hspeed"] = vx
	accessor["vspeed"] = vy
	
	--TODO: optional to override damage here
	accessor["btd_projectile_parent"] = parent.id
	accessor["btd_projectile_team"] = parent:get("team")
	if physics then
		accessor["btd_projectile_ax"] = physics.ax
		accessor["gravity"] = physics.ay
	end
end

-- treat existing instances as projectiles!
Projectile.pseudoProjectiles = {}
-- current thoughts: bind to the entire game's step callback, iterate over a list of registered pseudoProjectiles, and do the thing
local pseudoProjectileParameters = {
	instance = {type = "Instance", optional = false},
	duration = {type = "number", optional = true},
	pierceDamagerProperties = {type = "table", optional = false, fields = pierceDamagerParameters},
	continuousHitDelay = {type = "number", optional = true, default = -1},
	destroyInstanceOnHit = {type = boolean, optional = true, default = false}
}

-- use an existing instance for collision checking, applying the provided damagers when the instance collides
-- does not affect the instance's movement, is intended simply to apply collision checking and damager spawning for things like existing actors
-- instance: the instance to treat as a projectile
-- duration: how long to treat the instance as a projectile - leave nil to keep treating it as a projectile until removed with "deregisterPseudoProjectile"
-- damagerProperties: the properties of the damager to produce when colliding with an actor
-- continuousHitDelay: the frames to wait between successive hits if continually colliding with the same actor. Defaults to -1, which disables continuous hits entirely.
-- returns: boolean representing successful registration or not (common cause could be instance is no longer valid)
function Projectile.registerPseudoProjectile(instance, duration, pierceDamagerProperties, continuousHitDelay, destroyInstanceOnEnd)
	assert(validateArguments({instance = instance, duration = duration, pierceDamagerProperties = damagerProperties, destroyInstanceOnEnd = destroyInstanceOnEnd}, pseudoProjectileParameters))
	if not instance:isValid() then return false end
	Projectile.pseudoProjectiles[instance] = {
		duration = duration,
		pierceDamagerProperties = pierceDamagerProperties,
		continuousHitDelay = continuousHitDelay,
		destroyInstanceOnEnd = destroyInstanceOnEnd,
	}
end

function pseudoProjectileStep(instance, args) -- handle collisions and damage for a pseudoProjectile - hopefully can simply refactor out the main projectile collision code
	
end

-- the method that will be called each step to handle the collisions for registered pseudoProjectiles
function Projectile.handlePseudoProjectiles()
	--for continuous hits, set a variable PREFIX..[instanceID].."collision" with the frameDelay, as a timer
	for instance, args in pairs(Projectile.pseudoProjectiles) do
		pseudoProjectileStep(instance, args)
	end
end

-- instance: the instance to deregister. Alternately, an instanceID of the instance to deregister, in which case a namespace will also be needed
-- returns a boolean for whether the instance was successfully found and deregistered
function Projectile.deregisterPseudoProjectile(instance)
	if isa(instance, "string") then -- passed an id instead of instance, find the instance
		assert(namespace)
		instance = Object.findInstance(instance, namespace)
		if not instance then return false end
	end
	
	if not Projectile.pseudoProjectiles[instance] then return false end
	
	Projectile.pseudoProjectiles[instance] = nil
	return true
end

registercallback("onStep", function()
	Projectile.handlePseudoProjectiles()
end)

return Projectile