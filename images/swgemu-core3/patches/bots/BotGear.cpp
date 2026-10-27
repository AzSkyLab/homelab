/*
 * BotGear (Phase 9 Part 3). See BotGear.h.
 */

#include "BotGear.h"
#include "BotLoot.h"
#include "BotManager.h"
#include "BotTrade.h"
#include "server/ServerCore.h"
#include "server/zone/Zone.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/player/FactionStatus.h"
#include "server/zone/objects/scene/TransferErrorCode.h"
#include "server/zone/objects/tangible/TangibleObject.h"
#include "server/zone/objects/tangible/weapon/WeaponObject.h"
#include "server/zone/objects/tangible/wearables/ArmorObject.h"
#include "server/zone/objects/tangible/pharmaceutical/PharmaceuticalObject.h"
#include "server/zone/objects/tangible/pharmaceutical/EnhancePack.h"
#include "server/zone/objects/tangible/pharmaceutical/WoundPack.h"
#include "server/zone/objects/tangible/pharmaceutical/StimPack.h"
#include "server/zone/objects/tangible/pharmaceutical/RangedStimPack.h"
#include "server/zone/objects/tangible/pharmaceutical/CurePack.h"
#include "server/zone/objects/tangible/pharmaceutical/DotPack.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "templates/SharedTangibleObjectTemplate.h"
#include "templates/manager/TemplateManager.h"

using namespace server::zone::managers::bot;

namespace {

Logger& gearLog() {
	static Logger logger("BotGear");

	return logger;
}

const char* PLAY = "BotGear";
const char* GIVEN_VAR = "given";
const char* MODE_VAR = "give";

// The oids in a comma list of the bot's ScreenPlayData. Pre: bot locked
void readOids(CreatureObject* bot, const char* variable, SortedVector<uint64>& out) {
	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return;

	String list = ghost->getScreenPlayData(PLAY, variable);

	if (list.isEmpty())
		return;

	StringTokenizer tokens(list);
	tokens.setDelimeter(",");

	while (tokens.hasMoreTokens()) {
		String token;
		tokens.getStringToken(token);

		uint64 oid = UnsignedLong::valueOf(token);

		if (oid != 0)
			out.put(oid);
	}
}

void writeOids(CreatureObject* bot, const char* variable, const SortedVector<uint64>& oids) {
	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return;

	if (oids.isEmpty()) {
		ghost->deleteScreenPlayData(PLAY, variable);
		return;
	}

	StringBuffer list;

	for (int i = 0; i < oids.size(); ++i)
		list << (i > 0 ? "," : "") << oids.get(i);

	ghost->setScreenPlayData(PLAY, variable, list.toString());
}

String familyOf(WeaponObject* weapon) {
	if (weapon->isFlameThrower() || weapon->isHeavyAcidRifle() || weapon->isHeavyWeapon() || weapon->isSpecialHeavyWeapon())
		return "heavy";

	if (weapon->isRifleWeapon())
		return "rifle";

	if (weapon->isCarbineWeapon())
		return "carbine";

	if (weapon->isPistolWeapon())
		return "pistol";

	if (weapon->isOneHandMeleeWeapon())
		return "onehand";

	if (weapon->isTwoHandMeleeWeapon())
		return "twohand";

	if (weapon->isPolearmWeaponObject())
		return "polearm";

	if (weapon->isThrownWeapon())
		return "thrown";

	if (weapon->isUnarmedWeapon())
		return "unarmed";

	return "other";
}

String slotOf(SceneObject* object) {
	String slot;

	if (object->getArrangementDescriptorSize() > 0) {
		const Vector<String>* slots = object->getArrangementDescriptor(0);

		for (int i = 0; slots != nullptr && i < slots->size(); ++i)
			slot += (i > 0 ? "|" : "") + slots->get(i);
	}

	return slot;
}

bool inSlot(SceneObject* object, const char* name) {
	return slotOf(object).contains(name);
}

float armorRating(ArmorObject* armor) {
	return (armor->getKinetic() + armor->getEnergy() + armor->getElectricity() + armor->getStun() + armor->getBlast() + armor->getHeat() +
		armor->getCold() + armor->getAcid()) / 8.0f;
}

int conditionLeft(SceneObject* object) {
	if (!object->isTangibleObject())
		return 100;

	TangibleObject* tano = object->asTangibleObject();
	int max = tano->getMaxCondition();

	if (max <= 0)
		return 100;

	int left = (int) ((max - tano->getConditionDamage()) * 100.0f / max);

	return left < 0 ? 0 : (left > 100 ? 100 : left);
}

String lower(const String& text) {
	return text.toLowerCase();
}

// The medicine skill a pack asks of the bot, and the skill mod that counts
bool packFacts(CreatureObject* bot, PharmaceuticalObject* pack, const String& kind, int& required, bool& usable, float& power) {
	required = pack->getMedicineUseRequired();
	power = 0;

	bool combat = kind == "ranged" || kind == "dot" || kind == "dotarea";
	int skill = bot->getSkillMod(combat ? "combat_healing_ability" : "healing_ability");

	usable = pack->getUseCount() > 0 && required <= skill;

	if (pack->isStimPack()) {
		power = cast<StimPack*>(pack)->getEffectiveness();
	} else if (pack->isRangedStimPack()) {
		power = cast<RangedStimPack*>(pack)->getEffectiveness();
	} else if (pack->isCurePack()) {
		power = cast<CurePack*>(pack)->getEffectiveness();
	} else if (pack->isEnhancePack()) {
		power = cast<EnhancePack*>(pack)->getEffectiveness();
	} else if (pack->isWoundPack()) {
		power = cast<WoundPack*>(pack)->getEffectiveness();
	} else if (dynamic_cast<DotPack*>(pack) != nullptr) {
		power = dynamic_cast<DotPack*>(pack)->getEffectiveness();
	}

	return true;
}


void describe(CreatureObject* bot, SceneObject* object, bool worn, bool given, BotGearItem* out) {
	String kind, family;

	BotGear::classify(object, kind, family);

	out->oid = object->getObjectID();
	out->templateName = object->getObjectTemplate() != nullptr ? object->getObjectTemplate()->getFullTemplateString() : "";
	out->name = object->getDisplayedName();
	out->kind = kind;
	out->family = family;
	out->slot = slotOf(object);
	out->worn = worn;
	out->given = given;
	out->left = conditionLeft(object);

	if (object->isTangibleObject())
		out->broken = object->asTangibleObject()->isBroken();

	if (object->isWeaponObject()) {
		WeaponObject* weapon = cast<WeaponObject*>(object);

		out->certified = weapon->isCertifiedFor(bot);
		out->uses = kind == "grenade" ? object->asTangibleObject()->getUseCount() : 1;

		float speed = weapon->getAttackSpeed();

		out->power = speed > 0 ? (weapon->getMinDamage() + weapon->getMaxDamage()) / 2.0f / speed : 0;
	} else if (object->isArmorObject()) {
		out->power = armorRating(cast<ArmorObject*>(object));
	} else if (object->isPharmaceuticalObject()) {
		PharmaceuticalObject* pack = cast<PharmaceuticalObject*>(object);

		out->uses = pack->getUseCount();

		packFacts(bot, pack, kind, out->required, out->usable, out->power);
	}
}

}

void BotGear::classify(SceneObject* item, String& kind, String& family) {
	kind = "other";
	family = "";

	if (item == nullptr)
		return;

	String name = lower(item->getObjectTemplate() != nullptr ? item->getObjectTemplate()->getFullTemplateString() : "");

	if (item->isWeaponObject()) {
		WeaponObject* weapon = cast<WeaponObject*>(item);

		if (weapon->isMineWeapon())
			return;

		family = familyOf(weapon);
		kind = weapon->isThrownWeapon() ? "grenade" : "weapon";
	} else if (item->isArmorObject()) {
		kind = "armor";
	} else if (item->isWearableObject()) {
		kind = "clothing";
	} else if (item->isPharmaceuticalObject()) {
		PharmaceuticalObject* pack = cast<PharmaceuticalObject*>(item);

		if (name.contains("/pet/"))
			kind = "medicine";
		else if (pack->isRangedStimPack())
			kind = "ranged";
		else if (pack->isStimPack())
			kind = "stim";
		else if (pack->isStatePack())
			kind = "state";
		else if (pack->isRevivePack())
			kind = "revive";
		else if (pack->isCurePack())
			kind = name.contains("_area_") ? "curearea" : "cure";
		else if (dynamic_cast<DotPack*>(pack) != nullptr)
			kind = name.contains("_area_") ? "dotarea" : "dot";
		else if (pack->isEnhancePack())
			kind = "enhance";
		else if (pack->isWoundPack())
			kind = "wound";
		else
			kind = "medicine";
	} else if (item->isCampKit()) {
		kind = "camp";
	}
}

void BotGear::list(CreatureObject* bot, Vector<Reference<BotGearItem*>>& out) {
	if (bot == nullptr)
		return;

	Locker locker(bot);

	SortedVector<uint64> given;
	readOids(bot, GIVEN_VAR, given);

	// (the looted goods and the gifts are read once, not once per item)
	SortedVector<uint64> loot;
	BotLoot::recorded(bot, loot);

	// (an item that takes more than one slot is listed under each: once is enough)
	SortedVector<uint64> seen;

	for (int i = 0; i < bot->getSlottedObjectsSize(); ++i) {
		SceneObject* object = bot->getSlottedObject(i);

		if (object == nullptr || !(object->isWearableObject() || object->isArmorObject() || object->isWeaponObject()))
			continue;

		if (seen.contains(object->getObjectID()))
			continue;

		seen.put(object->getObjectID());

		// (the bare-handed weapon every creature has)
		if (inSlot(object, "default_weapon") || inSlot(object, "hair"))
			continue;

		Reference<BotGearItem*> item = new BotGearItem();

		describe(bot, object, true, given.contains(object->getObjectID()), item);
		out.add(item);
	}

	SceneObject* inventory = bot->getInventory();

	for (int i = 0; inventory != nullptr && i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object == nullptr || loot.contains(object->getObjectID()))
			continue;

		Reference<BotGearItem*> item = new BotGearItem();

		describe(bot, object, false, given.contains(object->getObjectID()), item);

		if (item->kind == "other")
			continue;

		out.add(item);
	}
}

bool BotGear::equip(CreatureObject* bot, uint64 itemOid, String& why) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot)) {
		why = "failed";
		return false;
	}

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> item = zoneServer != nullptr ? zoneServer->getObject(itemOid) : nullptr;

	if (item == nullptr || !item->isTangibleObject()) {
		why = "no item";
		return false;
	}

	Locker locker(bot);

	SceneObject* inventory = bot->getInventory();

	if (inventory == nullptr || !inventory->hasObjectInContainer(itemOid)) {
		why = "no item";
		return false;
	}

	bool inWorld = bot->getZone() != nullptr;

	if (item->isWeaponObject() && !cast<WeaponObject*>(item.get())->isCertifiedFor(bot)) {
		why = "cert";
		return false;
	}

	Locker ilocker(item, bot);

	// Make room: what is in the way goes to the pack, and comes back if the new piece is refused
	Vector<ManagedReference<SceneObject*>> moved;

	if (item->getArrangementDescriptorSize() > 0) {
		const Vector<String>* slots = item->getArrangementDescriptor(0);

		for (int i = 0; slots != nullptr && i < slots->size(); ++i) {
			ManagedReference<SceneObject*> occupant = bot->getSlottedObject(slots->get(i));

			if (occupant == nullptr || occupant == item)
				continue;

			if (!(occupant->isWearableObject() || occupant->isArmorObject() || occupant->isWeaponObject() || occupant->isInstrument())) {
				why = "slot";
				return false;
			}

			Locker olocker(occupant, bot);

			if (!inventory->transferObject(occupant, -1, inWorld, true)) {
				why = "slot";
				return false;
			}

			moved.add(occupant);
		}
	}

	String error;
	int result = bot->canAddObject(item, 4, error);

	if (result != 0) {
		for (int i = 0; i < moved.size(); ++i) {
			Locker olocker(moved.get(i), bot);

			bot->transferObject(moved.get(i), 4, inWorld);
		}

		if (result == TransferErrorCode::NOTENOUGHENCUMBRANCE) {
			why = "heavy";
		} else if (error.contains("insufficient_skill")) {
			why = "cert";
		} else {
			// The species list, else the faction (Core3 says the same thing for both)
			SharedTangibleObjectTemplate* tanoData = dynamic_cast<SharedTangibleObjectTemplate*>(item->getObjectTemplate());
			String race = bot->getObjectTemplate()->getFullTemplateString();

			why = (tanoData != nullptr && !tanoData->getPlayerRaces()->contains(race.hashCode())) ? "species" : "faction";
		}

		gearLog().info(true) << bot->getFirstName() << " can't wear " << item->getDisplayedName() << ": " << why << " (" << result << " " << error << ")";

		return false;
	}

	if (!bot->transferObject(item, 4, inWorld)) {
		for (int i = 0; i < moved.size(); ++i) {
			Locker olocker(moved.get(i), bot);

			bot->transferObject(moved.get(i), 4, inWorld);
		}

		why = "failed";
		return false;
	}

	if (item->isWeaponObject()) {
		// As TransferItemWeaponCommand does
		ManagedReference<WeaponObject*> weapon = item.castTo<WeaponObject*>();

		bot->setWeapon(weapon, true);
		weapon->setCertified(weapon->isCertifiedFor(bot));

		PlayerManager* playerManager = zoneServer->getPlayerManager();

		if (playerManager != nullptr)
			bot->setLevel(playerManager->calculatePlayerLevel(bot));
	}

	gearLog().info(true) << bot->getFirstName() << " put on " << item->getDisplayedName();

	return true;
}

bool BotGear::unequip(CreatureObject* bot, uint64 itemOid) {
	if (bot == nullptr)
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> item = zoneServer != nullptr ? zoneServer->getObject(itemOid) : nullptr;

	if (item == nullptr)
		return false;

	Locker locker(bot);

	SceneObject* inventory = bot->getInventory();

	if (inventory == nullptr || inventory->hasObjectInContainer(itemOid))
		return inventory != nullptr;

	Locker ilocker(item, bot);

	bool ok = inventory->transferObject(item, -1, bot->getZone() != nullptr, true);

	if (ok && item->isWeaponObject()) {
		// Bare-handed again
		ManagedReference<SceneObject*> bare = bot->getSlottedObject("default_weapon");

		if (bare != nullptr && bare->isWeaponObject())
			bot->setWeapon(cast<WeaponObject*>(bare.get()), true);
	}

	return ok;
}

void BotGear::markGiven(CreatureObject* bot, const Vector<uint64>& oids) {
	if (bot == nullptr)
		return;

	Locker locker(bot);

	SortedVector<uint64> given;
	readOids(bot, GIVEN_VAR, given);

	for (int i = 0; i < oids.size(); ++i)
		given.put(oids.get(i));

	writeOids(bot, GIVEN_VAR, given);
}

bool BotGear::isGiven(CreatureObject* bot, uint64 oid) {
	if (bot == nullptr)
		return false;

	Locker locker(bot);

	SortedVector<uint64> given;
	readOids(bot, GIVEN_VAR, given);

	return given.contains(oid);
}

uint64 BotGear::findPack(CreatureObject* bot, const String& wanted, int& uses) {
	uses = 0;

	if (bot == nullptr || wanted.isEmpty())
		return 0;

	String kind = wanted, word;
	int colon = wanted.indexOf(':');

	if (colon >= 0) {
		kind = wanted.subString(0, colon);
		word = wanted.subString(colon + 1);
	}

	Locker locker(bot);

	SceneObject* inventory = bot->getInventory();

	if (inventory == nullptr)
		return 0;

	SortedVector<uint64> loot;
	BotLoot::recorded(bot, loot);

	uint64 best = 0;
	float bestPower = -1;

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object == nullptr || loot.contains(object->getObjectID()))
			continue;

		String itemKind, family;
		classify(object, itemKind, family);

		if (itemKind != kind)
			continue;

		if (!word.isEmpty() && !lower(object->getObjectTemplate()->getFullTemplateString()).contains(word))
			continue;

		int itemUses = 0;
		float power = 0;

		if (object->isPharmaceuticalObject()) {
			PharmaceuticalObject* pack = cast<PharmaceuticalObject*>(object);
			int required = 0;
			bool usable = false;

			packFacts(bot, pack, kind, required, usable, power);

			if (!usable)
				continue;

			itemUses = pack->getUseCount();
		} else if (object->isWeaponObject() && itemKind == "grenade") {
			itemUses = object->asTangibleObject()->getUseCount();

			if (itemUses <= 0 || !cast<WeaponObject*>(object)->isCertifiedFor(bot))
				continue;

			power = cast<WeaponObject*>(object)->getMaxDamage();
		} else {
			continue;
		}

		uses += itemUses;

		if (power > bestPower) {
			best = object->getObjectID();
			bestPower = power;
		}
	}

	return best;
}

void BotGear::campKits(CreatureObject* bot, Vector<String>& out) {
	if (bot == nullptr)
		return;

	Locker locker(bot);

	SceneObject* inventory = bot->getInventory();

	SortedVector<uint64> loot;
	BotLoot::recorded(bot, loot);

	for (int i = 0; inventory != nullptr && i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && object->isCampKit() && !loot.contains(object->getObjectID()))
			out.add(object->getObjectTemplate()->getFullTemplateString());
	}
}

// A filter: "all", or a kind ("weapon", "armor", "stim"...), or a weapon family ("rifle"...)
static bool matches(const String& filter, const String& kind, const String& family) {
	if (filter == "all" || filter == kind || (!family.isEmpty() && filter == family))
		return true;

	// "packs" and "medicine": any of the medicines
	if (filter == "medicine" || filter == "packs")
		return kind == "stim" || kind == "ranged" || kind == "state" || kind == "cure" || kind == "curearea" || kind == "revive" ||
			kind == "dot" || kind == "dotarea" || kind == "enhance" || kind == "wound" || kind == "medicine";

	// "gear" is the arms and armour without the clothes
	if (filter == "gear")
		return kind == "weapon" || kind == "armor";

	return false;
}

int BotGear::prepareGiveBack(CreatureObject* bot, const String& filter) {
	if (bot == nullptr)
		return 0;

	Locker locker(bot);

	SortedVector<uint64> given;
	readOids(bot, GIVEN_VAR, given);

	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return 0;

	Vector<uint64> wornGiven;

	for (int i = 0; i < bot->getSlottedObjectsSize(); ++i) {
		SceneObject* object = bot->getSlottedObject(i);

		if (object != nullptr && given.contains(object->getObjectID()))
			wornGiven.add(object->getObjectID());
	}

	// What is worn and asked for goes into the pack first; the goods are what is in the pack
	for (int i = 0; i < wornGiven.size(); ++i) {
		ManagedReference<SceneObject*> object = bot->getZoneServer()->getObject(wornGiven.get(i));

		if (object == nullptr)
			continue;

		String kind, family;
		classify(object, kind, family);

		if (matches(filter, kind, family))
			unequip(bot, wornGiven.get(i));
	}

	SceneObject* inventory = bot->getInventory();
	int count = 0;

	for (int i = 0; inventory != nullptr && i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object == nullptr || !given.contains(object->getObjectID()))
			continue;

		String kind, family;
		classify(object, kind, family);

		if (matches(filter, kind, family))
			++count;
	}

	if (count > 0)
		ghost->setScreenPlayData(PLAY, MODE_VAR, filter);
	else
		ghost->deleteScreenPlayData(PLAY, MODE_VAR);

	return count;
}

void BotGear::endGiveBack(CreatureObject* bot) {
	if (bot == nullptr)
		return;

	Locker locker(bot);

	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost != nullptr)
		ghost->deleteScreenPlayData(PLAY, MODE_VAR);
}

String BotGear::giveMode(CreatureObject* bot) {
	PlayerObject* ghost = bot != nullptr ? bot->getPlayerObject() : nullptr;

	return ghost != nullptr ? ghost->getScreenPlayData(PLAY, MODE_VAR) : String("");
}

void BotGear::givenGoods(CreatureObject* bot, const String& mode, Vector<Reference<BotGoodsItem*>>& out) {
	SceneObject* inventory = bot->getInventory();

	if (inventory == nullptr)
		return;

	SortedVector<uint64> given;
	readOids(bot, GIVEN_VAR, given);

	SortedVector<uint64> kept;

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object == nullptr || !given.contains(object->getObjectID()))
			continue;

		kept.put(object->getObjectID());

		String kind, family;
		classify(object, kind, family);

		if (!matches(mode, kind, family))
			continue;

		Reference<BotGoodsItem*> entry = new BotGoodsItem();
		entry->oid = object->getObjectID();
		entry->name = object->getDisplayedName();
		entry->resource = false;
		entry->quantity = 1;
		entry->tradable = !object->isNoTrade() && !object->containsNoTradeObjectRecursive();
		out.add(entry);
	}

	// What is worn stays recorded; what has left the bot (used up, handed back) does not
	for (int i = 0; i < bot->getSlottedObjectsSize(); ++i) {
		SceneObject* object = bot->getSlottedObject(i);

		if (object != nullptr && given.contains(object->getObjectID()))
			kept.put(object->getObjectID());
	}

	if (kept.size() != given.size())
		writeOids(bot, GIVEN_VAR, kept);
}

bool BotGear::returnGiven(uint64 botOid, uint64 ownerOid, String& why) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();

	if (zoneServer == nullptr) {
		why = "no server";
		return false;
	}

	ManagedReference<SceneObject*> botObject = zoneServer->getObject(botOid);
	ManagedReference<SceneObject*> ownerObject = zoneServer->getObject(ownerOid);

	if (botObject == nullptr || !botObject->isCreatureObject()) {
		why = "no such bot";
		return false;
	}

	ManagedReference<CreatureObject*> bot = botObject->asCreatureObject();

	SortedVector<uint64> given;

	{
		Locker locker(bot);
		readOids(bot, GIVEN_VAR, given);
	}

	if (given.isEmpty())
		return true;

	if (ownerObject == nullptr || !ownerObject->isPlayerCreature()) {
		why = "owner offline";
		return false;
	}

	ManagedReference<CreatureObject*> owner = ownerObject->asCreatureObject();

	Locker olocker(owner);
	Locker blocker(bot, owner);

	if (owner->getZone() == nullptr || !owner->isOnline()) {
		why = "owner offline";
		return false;
	}

	// Room for them all first, so a let-go never leaves half of it in the bot
	SceneObject* inventory = owner->getInventory();

	if (inventory == nullptr) {
		why = "owner offline";
		return false;
	}

	Vector<ManagedReference<SceneObject*>> items;

	for (int i = 0; i < given.size(); ++i) {
		ManagedReference<SceneObject*> item = zoneServer->getObject(given.get(i));

		if (item != nullptr && item->isASubChildOf(bot))
			items.add(item);
	}

	if (inventory->getContainerObjectsSize() + items.size() + 1 >= (int) inventory->getContainerVolumeLimit()) {
		why = "inventory full";
		return false;
	}

	SortedVector<uint64> left = given;

	for (int i = 0; i < items.size(); ++i) {
		String error;

		// A worn gift comes off first (a weapon in hand goes back to bare hands), so the bot is not left firing what the owner holds
		unequip(bot, items.get(i)->getObjectID());

		if (!BotTrade::handStraight(bot, items.get(i), owner, error)) {
			why = error;
			writeOids(bot, GIVEN_VAR, left);

			return false;
		}

		left.drop(items.get(i)->getObjectID());
	}

	writeOids(bot, GIVEN_VAR, SortedVector<uint64>());
	gearLog().info(true) << bot->getFirstName() << " handed " << items.size() << " item(s) back to " << owner->getFirstName();

	return true;
}

uint64 BotGear::starterStims(CreatureObject* bot, int uses) {
	if (bot == nullptr)
		return 0;

	uint32 crc = String("object/tangible/medicine/crafted/crafted_stimpack_sm_s1_a.iff").hashCode();
	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getInventory();

	if (zoneServer == nullptr || inventory == nullptr)
		return 0;

	ManagedReference<SceneObject*> item = zoneServer->createObject(crc, 1);

	if (item == nullptr || !item->isTangibleObject())
		return 0;

	Locker ilocker(item, bot);

	if (!inventory->transferObject(item, -1, bot->getZone() != nullptr, true)) {
		item->destroyObjectFromDatabase(true);
		return 0;
	}

	item->asTangibleObject()->setUseCount(uses, true);

	return item->getObjectID();
}

uint64 BotGear::devGive(CreatureObject* bot, const String& templateName, int uses) {
	if (bot == nullptr || templateName.isEmpty())
		return 0;

	uint32 crc = templateName.hashCode();

	if (TemplateManager::instance()->getTemplate(crc) == nullptr)
		return 0;

	ZoneServer* zoneServer = bot->getZoneServer();
	Locker locker(bot);

	SceneObject* inventory = bot->getInventory();

	if (zoneServer == nullptr || inventory == nullptr)
		return 0;

	ManagedReference<SceneObject*> item = zoneServer->createObject(crc, 1);

	if (item == nullptr)
		return 0;

	Locker ilocker(item, bot);

	if (!inventory->transferObject(item, -1, bot->getZone() != nullptr, true)) {
		item->destroyObjectFromDatabase(true);
		return 0;
	}

	if (uses > 0 && item->isTangibleObject())
		item->asTangibleObject()->setUseCount(uses, true);

	Vector<uint64> oids;
	oids.add(item->getObjectID());

	ilocker.release();
	markGiven(bot, oids);

	return item->getObjectID();
}

bool BotGear::devCondition(CreatureObject* bot, uint64 oid, int percent) {
	if (bot == nullptr)
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> item = zoneServer != nullptr ? zoneServer->getObject(oid) : nullptr;

	if (item == nullptr || !item->isTangibleObject())
		return false;

	Locker locker(item, bot);

	TangibleObject* tano = item->asTangibleObject();
	int max = tano->getMaxCondition();

	if (max <= 0)
		return false;

	tano->setConditionDamage(max * (100 - percent) / 100.0f, true);

	return true;
}
