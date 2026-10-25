/*
 * BotItems (Phase 3 bot players; combat packs in Phase 5). See BotItems.h.
 */

#include "BotItems.h"
#include "BotLoot.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "templates/params/creature/CreatureAttribute.h"
#include "server/zone/objects/creature/BuffAttribute.h"
#include "server/zone/objects/creature/buffs/Buff.h"
#include "server/zone/objects/creature/buffs/BuffList.h"
#include "server/zone/objects/tangible/pharmaceutical/PharmaceuticalObject.h"
#include "server/zone/objects/tangible/pharmaceutical/EnhancePack.h"
#include "server/zone/objects/tangible/pharmaceutical/WoundPack.h"
#include "server/zone/objects/tangible/pharmaceutical/StimPack.h"
#include "server/zone/objects/tangible/pharmaceutical/RangedStimPack.h"
#include "server/zone/objects/tangible/pharmaceutical/StatePack.h"
#include "server/zone/objects/tangible/pharmaceutical/CurePack.h"
#include "server/zone/objects/tangible/pharmaceutical/RevivePack.h"
#include "server/zone/objects/tangible/pharmaceutical/DotPack.h"
#include "server/zone/objects/scene/SceneObjectType.h"
#include "server/zone/objects/manufactureschematic/craftingvalues/CraftingValues.h"
#include "templates/manager/TemplateManager.h"
#include "templates/tangible/EnhancePackTemplate.h"
#include "templates/tangible/WoundPackTemplate.h"

using namespace server::zone::managers::bot;

namespace {

Logger& itemsLog() {
	static Logger logger("BotItems");

	return logger;
}

// Is `object` a pack of the same kind (enhance or wound) for the same attribute?
bool isSameKind(SceneObject* object, bool enhance, uint8 attribute) {
	if (object == nullptr || !object->isPharmaceuticalObject())
		return false;

	PharmaceuticalObject* pharma = cast<PharmaceuticalObject*>(object);

	if (enhance)
		return pharma->isEnhancePack() && cast<EnhancePack*>(pharma)->getAttribute() == attribute;

	if (!pharma->isWoundPack())
		return false;

	WoundPack* woundPack = cast<WoundPack*>(pharma);

	return !woundPack->isDroidReconstructionKit() && woundPack->getAttribute() == attribute;
}

void addValue(CraftingValues& values, const String& name, const String& group, float value) {
	values.addExperimentalAttribute(name, group, 0, 100000, 0, false, AttributesMap::LINEARCOMBINE);
	values.setCurrentValue(name, value);
}

// The combat packs (Phase 5), kept one per template: stims, ranged stims, state, cure and revive packs, and (Phase 7c)
// poison and disease packs
bool isCombatPackTemplate(SharedObjectTemplate* objectTemplate) {
	return objectTemplate->isStimPackTemplate() || objectTemplate->isStatePackTemplate() || objectTemplate->isCurePackTemplate()
		|| objectTemplate->isDotPackTemplate() || objectTemplate->getGameObjectType() == SceneObjectType::REVIVEPACK;
}

// What a DoT pack needs besides the usual: seconds, potency and range (0 keeps the pack's own)
class DotPackExtras {
public:
	int duration = 0;
	float potency = 0;
	float range = 0;
};

const float REVIVE_POWER = 400;

// The fields each combat pack's updateCraftingValues reads, as a crafting session would set them. What stockPack
// doesn't set (medicine use, range, area) stays as the pack has it. Pre: pack locked
bool setCombatPackValues(PharmaceuticalObject* pack, int uses, float power, const DotPackExtras& dot) {
	CraftingValues values;
	int useCount = Math::max(uses, pack->getUseCount());
	bool enoughUses = pack->getUseCount() >= uses;

	addValue(values, "charges", "exp_charges", useCount);
	addValue(values, "skillmodmin", "expEaseOfUse", pack->getMedicineUseRequired());

	if (pack->isRangedStimPack()) {
		RangedStimPack* stim = cast<RangedStimPack*>(pack);

		if (stim->getEffectiveness() == power && enoughUses)
			return true;

		addValue(values, "power", "exp_effectiveness", power);
		addValue(values, "range", "exp_charges", stim->getRange());

		if (stim->getArea() > 0)
			addValue(values, "area", "null", stim->getArea());

		stim->updateCraftingValues(&values, true);
	} else if (pack->isStimPack()) {
		StimPack* stim = cast<StimPack*>(pack);

		if (stim->isDroidRepairKit() || stim->isPetStimPack())
			return false;

		if (stim->getEffectiveness() == power && enoughUses)
			return true;

		addValue(values, "power", "exp_effectiveness", power);

		stim->updateCraftingValues(&values, true);
	} else if (pack->isCurePack()) {
		CurePack* cure = cast<CurePack*>(pack);

		if (cure->getEffectiveness() == power && enoughUses)
			return true;

		addValue(values, "power", "exp_effectiveness", power);

		if (cure->getArea() > 0)
			addValue(values, "area", "null", cure->getArea());

		cure->updateCraftingValues(&values, true);
	} else if (pack->isDotPackObject()) {
		DotPack* dotPack = cast<DotPack*>(pack);

		// Area packs would make the medic a defender of everything they hit
		if (dotPack->isArea())
			return false;

		float potency = dot.potency > 0 ? dot.potency : dotPack->getPotency();
		float range = dot.range > 0 ? dot.range : dotPack->getRange();
		float duration = dot.duration > 0 ? dot.duration : dotPack->getDuration();

		if (dotPack->getEffectiveness() == power && dotPack->getPotency() == potency && dotPack->getRange() == range && dotPack->getDuration() == (uint32) duration && enoughUses)
			return true;

		// The fields DotPack::updateCraftingValues reads, as a crafting session would set them
		addValue(values, "power", "exp_effectiveness", power);
		addValue(values, "potency", "expEaseOfUse", potency);
		addValue(values, "range", "exp_charges", range);
		addValue(values, "duration", "exp_effectiveness", duration);

		dotPack->updateCraftingValues(&values, true);
	} else if (pack->isStatePack()) {
		if (enoughUses)
			return true;

		cast<StatePack*>(pack)->updateCraftingValues(&values, true);
	} else if (pack->isRevivePack()) {
		RevivePack* revive = cast<RevivePack*>(pack);

		// A template revive pack has no power of its own (it heals one point and no wounds): 0 asks for a good
		// crafted one
		if (power <= 0)
			power = REVIVE_POWER;

		// Its crafting turns power into wounds healed, 2x for health
		if (revive->getHealthWoundHealed() == 2 * power && enoughUses)
			return true;

		addValue(values, "power", "exp_effectiveness", power);

		revive->updateCraftingValues(&values, true);
	} else {
		return false;
	}

	return true;
}

// Names for the buffs the bots give, by CRC (Core3 keeps only the CRC on a buff it makes in C++)
const VectorMap<uint32, String>& getKnownBuffNames() {
	static const VectorMap<uint32, String> names = []() {
		VectorMap<uint32, String> map;
		map.setNoDuplicateInsertPlan();

		for (int i = 0; i < BuffAttribute::ARRAYSIZE; ++i) {
			String name = "medical_enhance_" + BuffAttribute::getName(i);
			map.put(name.hashCode(), name);
		}

		const char* others[] = {"performance_enhance_dance_mind", "performance_enhance_music_focus", "performance_enhance_music_willpower"};

		for (const char* other : others)
			map.put(String(other).hashCode(), other);

		return map;
	}();

	return names;
}

}

bool BotItems::stockPack(CreatureObject* bot, const String& templateName, int uses, float power, int duration, float potency, float range) {
	if (bot == nullptr || !bot->isPlayerCreature())
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (zoneServer == nullptr || inventory == nullptr)
		return false;

	uint32 crc = templateName.hashCode();
	SharedObjectTemplate* objectTemplate = TemplateManager::instance()->getTemplate(crc);
	bool combatPack = objectTemplate != nullptr && isCombatPackTemplate(objectTemplate);

	if (objectTemplate == nullptr || !(objectTemplate->isEnhancePackTemplate() || objectTemplate->isWoundPackTemplate() || combatPack)) {
		itemsLog().error() << "stockPack: " << templateName << " is not a pack a bot stocks";
		return false;
	}

	bool enhance = objectTemplate->isEnhancePackTemplate();
	uint8 attribute = 0;

	if (enhance)
		attribute = static_cast<EnhancePackTemplate*>(objectTemplate)->getAttribute();
	else if (!combatPack)
		attribute = static_cast<WoundPackTemplate*>(objectTemplate)->getAttribute();

	bool inWorld = bot->getZone() != nullptr;

	Locker locker(bot);

	// One pack per kind and attribute (combat packs: per template): ours, the first of this template
	ManagedReference<PharmaceuticalObject*> pack;
	Vector<ManagedReference<SceneObject*>> extras;

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		ManagedReference<SceneObject*> object = inventory->getContainerObject(i);

		if (combatPack ? (object == nullptr || !object->isPharmaceuticalObject() || object->getServerObjectCRC() != crc) : !isSameKind(object, enhance, attribute))
			continue;

		// Looted medicine is goods for the humans: never the bot's stock, never destroyed as an extra
		if (BotLoot::isGood(bot, object->getObjectID()))
			continue;

		if (pack == nullptr && object->getServerObjectCRC() == crc)
			pack = cast<PharmaceuticalObject*>(object.get());
		else
			extras.add(object);
	}

	for (int i = 0; i < extras.size(); ++i) {
		SceneObject* extra = extras.get(i);

		Locker elocker(extra, bot);

		extra->destroyObjectFromWorld(true);
		extra->destroyObjectFromDatabase(true);
	}

	if (pack == nullptr) {
		ManagedReference<SceneObject*> object = zoneServer->createObject(crc, 1);

		if (object == nullptr || !object->isPharmaceuticalObject()) {
			itemsLog().error() << "stockPack: could not create " << templateName;

			if (object != nullptr)
				object->destroyObjectFromDatabase(true);

			return false;
		}

		Locker olocker(object, bot);

		if (!inventory->transferObject(object, -1, inWorld)) {
			itemsLog().error() << "stockPack: no room for " << templateName << " in " << bot->getFirstName() << "'s inventory";

			object->destroyObjectFromDatabase(true);
			return false;
		}

		pack = cast<PharmaceuticalObject*>(object.get());

		itemsLog().info(true) << bot->getFirstName() << " stocked " << templateName << ": power " << power << (enhance ? ", duration " + String::valueOf(duration) : String()) << ", uses " << uses;
	}

	Locker plocker(pack, bot);

	if (combatPack) {
		DotPackExtras dot;

		dot.duration = duration;
		dot.potency = potency;
		dot.range = range;

		if (!setCombatPackValues(pack, uses, power, dot)) {
			itemsLog().error() << "stockPack: " << templateName << " is a kind of pack a bot doesn't stock";
			return false;
		}

		return true;
	}

	int useCount = Math::max(uses, pack->getUseCount());

	if (enhance) {
		EnhancePack* enhancePack = cast<EnhancePack*>(pack.get());

		if (enhancePack->getEffectiveness() == power && enhancePack->getDuration() == duration && pack->getUseCount() >= uses)
			return true;

		// The fields EnhancePack::updateCraftingValues reads, as a crafting session would set them
		CraftingValues values;
		addValue(values, "power", "exp_effectiveness", power);
		addValue(values, "charges", "exp_charges", useCount);
		addValue(values, "duration", "exp_effectiveness", duration);
		addValue(values, "skillmodmin", "expEaseOfUse", enhancePack->getMedicineUseRequired());
		addValue(values, "absorption", "null", enhancePack->getAbsorption());

		enhancePack->updateCraftingValues(&values, true);
	} else {
		WoundPack* woundPack = cast<WoundPack*>(pack.get());

		if (woundPack->getEffectiveness() == power && pack->getUseCount() >= uses)
			return true;

		CraftingValues values;
		addValue(values, "power", "exp_effectiveness", power);
		addValue(values, "charges", "exp_charges", useCount);
		addValue(values, "skillmodmin", "expEaseOfUse", woundPack->getMedicineUseRequired());

		woundPack->updateCraftingValues(&values, true);
	}

	return true;
}

uint64 BotItems::findPack(CreatureObject* bot, const String& templateName) {
	if (bot == nullptr || templateName.isEmpty())
		return 0;

	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (inventory == nullptr)
		return 0;

	uint32 crc = templateName.hashCode();

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && object->isPharmaceuticalObject() && object->getServerObjectCRC() == crc &&
				!BotLoot::isGood(bot, object->getObjectID()))
			return object->getObjectID();
	}

	return 0;
}

int BotItems::getWounds(CreatureObject* creature, int pool) {
	if (creature == nullptr || pool < CreatureAttribute::HEALTH || pool > CreatureAttribute::WILLPOWER)
		return 0;

	return creature->getWounds(pool);
}

int BotItems::getShockWounds(CreatureObject* creature) {
	if (creature == nullptr)
		return 0;

	return (int) creature->getShockWounds();
}

void BotItems::listBuffs(CreatureObject* creature, Vector<BotBuffInfo>& out) {
	if (creature == nullptr)
		return;

	Locker locker(creature);

	const BuffList* buffList = creature->getBuffList();

	if (buffList == nullptr)
		return;

	const VectorMap<uint32, String>& knownNames = getKnownBuffNames();

	for (int i = 0; i < buffList->getBuffListSize(); ++i) {
		Buff* buff = buffList->getBuffByIndex(i);

		if (buff == nullptr)
			continue;

		BotBuffInfo info;
		info.crc = buff->getBuffCRC();
		info.name = buff->getBuffName();

		if (info.name.isEmpty())
			info.name = knownNames.contains(info.crc) ? knownNames.get(info.crc) : "0x" + String::hexvalueOf((int64) info.crc);

		info.secondsLeft = (int) buff->getTimeLeft();

		const VectorMap<byte, int>* attributeModifiers = buff->getAttributeModifiers();
		const VectorMap<String, int>* skillModifiers = buff->getSkillModifiers();

		if (attributeModifiers != nullptr && attributeModifiers->size() > 0)
			info.value = attributeModifiers->elementAt(0).getValue();
		else if (skillModifiers != nullptr && skillModifiers->size() > 0)
			info.value = skillModifiers->elementAt(0).getValue();

		out.add(info);
	}
}
