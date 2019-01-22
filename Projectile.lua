--[[
	Projectile library for creating moving projectiles instead of instant hitscans.
	Projectiles created as GMObjects, with managed physics and logic for what collisions to pay attention to
	Provides ability to set amount of enemies and/or walls to pierce through, and what to do to actors when you do pierce them
	Three preset methods, Grenade, Bullet, and Rocket, can be used for quickly creating common types of projectile. (ROCKET NOT YET IMPLEMENTED)
	Alternatively, you can use Projectile.Custom(args) (more complex, but greater control) to make your own type of projectile. If you do this, I would recommend creating a wrapper method similar to the three preset methods seen below.
]]


local inspect = require("inspect")
local json = require("json")

local Projectile = {}
local prefix = "projectile_"

-- get the actor that fired the projectile
function Projectile.getParent(projectileInstance)
	if projectileInstance:isValid() then
		local parent = Object.findInstance(projectileInstance:get(prefix.."parent"))
		if parent and parent:isValid() then return parent end
	end
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
		if (type(validation.optional) == function and validation.optional(arguments) or validation.optional == true) and arguments[param] == nil then -- optional and missing, set defaults and continue
			if validation.default ~= nil then 
				arguments[param] = type(validation.default) == function and validation.default(arguments) or validation.default
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

-- collision checking, get list of actor IDs
function getActorCollisions(instance)
	local collisions = {}
	for i,actor in ipairs(ObjectGroup.find("actors"):findAll()) do
		if actor:isValid()
		  and actor:get("team") ~= instance:get(prefix.."team")
		  and instance:collidesWith(actor, instance.x, instance.y) then
			collisions[""..actor.id] = true --coerce into string for json encoding
		end
	end
	return collisions
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
	explosionWidth = {type = "number", optional = function(args) return not args.damagerType == Projectile.DamagerType.EXPLOSION end},
	explosionHeight = {type = "number", optional = function(args) return not not args.damagerType == Projectile.DamagerType.EXPLOSION end},
	damage = {type = "number", optional = false},
	mlDamagerProperties = {type = "number", optional = true} 
}

-- specify what arguments can or should be provided when creating a custom projectile
-- if using one of the "preset" functions then the arguments are clearly defined in those functions
local projectileParameters = {
	name = {type = "string", optional = false},
	sprite = {type = "Sprite", optional = false},			--sprite for the projectile
	pierceCount = {type = "number", optional = true},			--how many enemies to pierce, -1 for infinite
	continuousHitDelay = {type = "number", optional = true, default = -1},
	phaseCount = {type = "number", optional = true},			--how many walls to pierce, -1 for infinite
	bounceType = {type = "number", optional = true, sanitise = function(arg) return math.floor(arg) end, validate = function(arg) return (arg > 0 and arg < 4), "bounceType argument must be a Projectile.BounceType: MAP (1), ENEMY (2), or BOTH (3). Received: "..arg end},			--whether to bounce off of enemies, walls, or both (when it is not due to pierce/phase them)
	bounceCount = {type = "number", optional = true},			--how many times to bounce off things it does not pierce, -1 for infinite
	timer = {type = "number", optional = function(args) return args.pierce > -1 end},		--how many frames before destroying, if not already collided
	pierceDamagerProperties = {type = "table", optional = true, default = nil, fields = damagerParameters},		--damager to be generated when piercing an enemy
	bounceDamagerProperties = {type = "table", optional = true, default = nil, fields = damagerParameters},		--TODO:damager to be generated when bouncing off an enemy or wall
	phaseStartDamagerProperties = {type = "table", optional = true, default = nil, fields = damagerParameters},		--TODO:damager to be generated when entering a wall
	phaseEndDamagerProperties = {type = "table", optional = true, default = nil, fields = damagerParameters},		--TODO:damager to be generated when leaving a wall
	endDamagerProperties = {type = "table", optional = true, default = nil, fields = damagerParameters}		--damager for the final hit / explosion
}

function Projectile.Custom(args)
	assert(validateArguments(args,
	projectileParameters))
	print(require("inspect")(args))
	local projectileObject = Object.new(args.name)
	projectileObject.sprite = args.sprite
	projectileObject:addCallback("create", function(self)
		local accessor = self:getAccessor() -- TODO: test if can store table data here
		print("create")
		if args.timer and args.timer > 0 then self:set(prefix.."timer", args.timer) end
		if args.pierceCount then self:set(prefix.."pierceCount", args.pierceCount) end
		if args.phaseCount then self:set(prefix.."phaseCount", args.phaseCount) end
		if args.distance then
			self:set(prefix.."distance", args.distance)
			self:set(prefix.."travelled", 0)
			self:set(prefix.."lastX", self.x)
			self:set(prefix.."lastY", self.y)
		end
	end)
	projectileObject:addCallback("step", function(self)
		print("step")
		--calculate any horizontal acceleration, as not accounted for by GameMaker
		local acceleration = self:get(prefix.."ax")
		if acceleration then
			local speed = self:get("hspeed")
			self:set("hspeed", speed + acceleration)
		end
		
		-- check for actor collisions
		local pierceCount = self:get(prefix.."pierceCount")
		if pierceCount == nil or pierceCount >= 0 then --need to watch for collisions
			local currentCollisions = getActorCollisions(self)
			
			if currentCollisions ~= {} then 
				local processedCollisions = json.decode(self:get(prefix.."processedActorCollisions") or "[]")
				-- check for new collisions, subtract from count or explode
				for actorId,exists in pairs(currentCollisions) do
					local shouldHit = false
					local newPierce = true	-- tells us whether to deduct from the pierceCount
					local actor = nil		-- will only be set if we need to do continuous hits, to store a new hitDelay on the actor
					
					if processedCollisions[actorId] then -- existing collision, process "continuous hit" logic to see if needs another hit
						newPierce = false
						if args.continuousHitDelay >= 0 then
							actor = ObjectGroup.find("actors"):findInstance(actorId)
							local hitTimer = actor:get(prefix.."continuousHitDelay")
							shouldHit = (hitTimer == nil or hitTimer <= 0)
							
							if not shouldHit then -- no hit yet, subtract from the hit delay timer
								actor:set(prefix.."continuousHitDelay", hitTimer - 1)
							end
						end
					else	-- new collision
						shouldHit = true
					end
					
					if shouldHit then
						if args.pierceDamagerProperties then -- create pierce damager
							local parent = Projectile.getParent(self)
							if args.pierceDamagerProperties.damagerType == Projectile.DamagerType.EXPLOSION then
								parent:fireExplosion(self.x, self.y,
								args.pierceDamagerProperties.explosionWidth/19,
								args.pierceDamagerProperties.explosionHeight/4,
								args.pierceDamagerProperties.damage,
								args.pierceDamagerProperties.explosionSprite,
								args.pierceDamagerProperties.hitSprite,
								args.pierceDamagerProperties.mlDamagerProperties)
							else
								local bullet = parent:fireBullet(self.x, self.y,
								args.pierceDamagerProperties.direction,
								args.pierceDamagerProperties.distance,
								args.pierceDamagerProperties.damage,
								args.pierceDamagerProperties.hitSprite,
								args.pierceDamagerProperties.mlDamagerProperties
								)
								bullet:set("specific_target", actorId)
							end
						end
						if pierceCount == nil or pierceCount == 0 then -- if that was the last pierce, destroy projectile
							self:destroy()
							return
						end
						if newPierce then self:set(prefix.."pierceCount", pierceCount -1) end-- subtract from remaining pierces
						if actor then actor:set(prefix.."continuousHitDelay", args.continuousHitDelay) end
					end
				end
			end
			--store current collisions for next check
			self:set(prefix.."processedActorCollisions", json.encode(currentCollisions))
		end
		
		-- check for map collisions
		local phaseCount = self:get(prefix.."phaseCount")
		if phaseCount == nil or phaseCount >= 0 then --need to watch for collisions
			local alreadyPhasing = self:get(prefix.."alreadyPhasing")
			if self:collidesMap(self.x, self.y) then
				--collision, check if currently mid-phase (not a new collision)
				if not alreadyPhasing then -- new collision,  explode if nil or 0, otherwise subtract and set to ignore current collision
					if (phaseCount == nil or phaseCount == 0) then
						self:destroy()
						return
					end
					self:set(prefix.."phaseCount", phaseCount -1)
					self:set(prefix.."alreadyPhasing", 1)
				end
			elseif alreadyPhasing then --just exited phase, reset ready for future checks
				self:set(prefix.."alreadyPhasing", nil)
			end
		end
		
		--check if timer expired
		local timer = self:get(prefix.."timer")
		if timer then
			if timer <= 0 then
				self:destroy()
				return
			end
			self:set(prefix.."timer", timer - 1)
		end
		
		--check if distance travelled
		local distance = self:get(prefix.."distance")
		if distance then
			local currentDistance = self:get(prefix.."travelled")
			local lastX = self:get(prefix.."lastX")
			local lastY = self:get(prefix.."lastY")
			local deltaX = math.abs(self.x - lastX)
			local deltaY = math.abs(self.y - lastY)
			local travelled = math.sqrt(deltaX^2 + deltaY^2)
			if currentDistance + travelled >= distance then
				self:destroy()
				return
			end
			
			self:set(prefix.."travelled", currentDistance + travelled)
			
			self:set(prefix.."lastX", self.x)
			self:set(prefix.."lastY", self.y)
		end
	end)
	projectileObject:addCallback("destroy", function(self)
		print("destroy")
		if not args.endDamagerProperties then return end
		local parent = Projectile.getParent(self)
		if args.endDamagerProperties.damagerType == Projectile.DamagerType.EXPLOSION then
			parent:fireExplosion(self.x, self.y,
			args.endDamagerProperties.explosionWidth/19,
			args.endDamagerProperties.explosionHeight/4,
			args.endDamagerProperties.damage,
			args.endDamagerProperties.explosionSprite,
			args.endDamagerProperties.hitSprite,
			args.endDamagerProperties.mlDamagerProperties)
		else
			parent:fireBullet(self.x, self.y,
			args.endDamagerProperties.direction,
			args.endDamagerProperties.distance,
			args.endDamagerProperties.damage,
			args.endDamagerProperties.hitSprite,
			args.endDamagerProperties.mlDamagerProperties)
			
		end
	end)
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
	
	--set movement
	projectileInstance.angle = direction
	local vy = math.sin(math.rad(direction)) * velocity
	local vx = math.cos(math.rad(direction)) * velocity
	projectileInstance:set("hspeed", vx)
	projectileInstance:set("vspeed", vy)
	
	--TODO: optional to override damage here
	projectileInstance:set(prefix.."parent", parent.id)
	projectileInstance:set(prefix.."team", parent:get("team"))
	if physics then
		projectileInstance:set(prefix.."ax", physics.ax)
		projectileInstance:set("gravity", physics.ay)
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
	--for continuous hits, set a variable prefix..[instanceID].."collision" with the frameDelay, as a timer
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