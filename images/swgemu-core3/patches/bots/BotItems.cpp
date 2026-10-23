/*
 * BotItems (Phase 3 bot players). See BotItems.h.
 */

#include "BotItems.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "templates/params/creature/CreatureAttribute.h"
#include "server/zone/objects/creature/BuffAttribute.h"
#include "server/zone/objects/creature/buffs/Buff.h"
#include "server/zone/objects/creature/buffs/BuffList.h"
#include "server/zone/objects/tangible/pharmaceutical/PharmaceuticalObject.h"
#include "server/zone/objects/tangible/pharmaceutical/EnhancePack.h"
#include "server/zone/objects/tangible/pharmaceutical/WoundPack.h"
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

bool BotItems::stockPack(CreatureObject* bot, const String& templateName, int uses, float power, int duration) {
	if (bot == nullptr || !bot->isPlayerCreature())
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (zoneServer == nullptr || inventory == nullptr)
		return false;

	uint32 crc = templateName.hashCode();
	SharedObjectTemplate* objectTemplate = TemplateManager::instance()->getTemplate(crc);

	if (objectTemplate == nullptr || !(objectTemplate->isEnhancePackTemplate() || objectTemplate->isWoundPackTemplate())) {
		itemsLog().error() << "stockPack: " << templateName << " is not an enhance or wound pack";
		return false;
	}

	bool enhance = objectTemplate->isEnhancePackTemplate();
	uint8 attribute = enhance ? static_cast<EnhancePackTemplate*>(objectTemplate)->getAttribute() : static_cast<WoundPackTemplate*>(objectTemplate)->getAttribute();
	bool inWorld = bot->getZone() != nullptr;

	Locker locker(bot);

	// One pack per kind and attribute: ours, the first of this template
	ManagedReference<PharmaceuticalObject*> pack;
	Vector<ManagedReference<SceneObject*>> extras;

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		ManagedReference<SceneObject*> object = inventory->getContainerObject(i);

		if (!isSameKind(object, enhance, attribute))
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
