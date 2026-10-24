/*
 * BotSlice (Phase 4 bot players). See BotSlice.h.
 */

#include "BotSlice.h"
#include "BotManager.h"
#include "BotTrade.h"
#include "server/ServerCore.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/player/sessions/SlicingSession.h"
#include "server/zone/objects/player/sui/SuiWindowType.h"
#include "server/zone/objects/player/sui/listbox/SuiListBox.h"
#include "server/zone/objects/scene/SceneObjectType.h"
#include "server/zone/objects/scene/SessionFacadeType.h"
#include "server/zone/objects/tangible/tool/smuggler/PrecisionLaserKnife.h"
#include "server/zone/objects/tangible/weapon/WeaponObject.h"
#include "server/zone/objects/tangible/wearables/ArmorObject.h"

const char* BotSlice::LASER_KNIFE = "object/tangible/slicing/slicing_laser_knife.iff";
const char* BotSlice::MOLECULAR_CLAMP = "object/tangible/slicing/slicing_molecular_clamp.iff";
const char* BotSlice::ARMOR_KIT = "object/tangible/slicing/slicing_armor_upgrade_kit.iff";
const char* BotSlice::WEAPON_KIT = "object/tangible/slicing/slicing_weapon_upgrade_kit.iff";

namespace {

Logger& sliceLog() {
	static Logger logger("BotSlice");

	return logger;
}

// Room kept free in the bot's inventory for the items it's handed
const int FREE_SLOTS = 5;

int countOfType(SceneObject* inventory, uint32 gameObjectType) {
	int count = 0;

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && object->getGameObjectType() == gameObjectType)
			++count;
	}

	return count;
}

// Creates `templateName` in the bot's inventory. Pre: bot locked
ManagedReference<SceneObject*> createInInventory(CreatureObject* bot, SceneObject* inventory, const String& templateName) {
	ZoneServer* zoneServer = bot->getZoneServer();

	if (zoneServer == nullptr)
		return nullptr;

	if (inventory->getContainerObjectsSize() + FREE_SLOTS >= inventory->getContainerVolumeLimit()) {
		sliceLog().error() << bot->getFirstName() << "'s inventory is too full to stock " << templateName;
		return nullptr;
	}

	ManagedReference<SceneObject*> object = zoneServer->createObject(templateName.hashCode(), 1);

	if (object == nullptr) {
		sliceLog().error() << "could not create " << templateName;
		return nullptr;
	}

	Locker olocker(object, bot);

	if (!inventory->transferObject(object, -1, bot->getZone() != nullptr)) {
		object->destroyObjectFromDatabase(true);
		return nullptr;
	}

	return object;
}

bool stockType(CreatureObject* bot, SceneObject* inventory, uint32 gameObjectType, const String& templateName, int count) {
	int have = countOfType(inventory, gameObjectType);

	for (; have < count; ++have) {
		if (createInInventory(bot, inventory, templateName) == nullptr)
			return false;
	}

	return true;
}

// Why the bot won't slice this, or "" if it can. Pre: bot locked
String checkSlice(CreatureObject* bot, TangibleObject* item, const String& kind) {
	if (kind == "armor") {
		if (!bot->hasSkill("combat_smuggler_slicing_03"))
			return "skill";
	} else if (kind == "weapon") {
		if (cast<WeaponObject*>(item)->isJediWeapon())
			return "not sliceable";

		if (!bot->hasSkill("combat_smuggler_slicing_02"))
			return "skill";
	} else {
		return "not armor or weapon";
	}

	if (item->isSliced())
		return "already sliced";

	if (!item->isSliceable())
		return "not sliceable";

	if (bot->containsActiveSession(SessionFacadeType::SLICING) || item->containsActiveSession(SessionFacadeType::SLICING))
		return "busy";

	return "";
}

const char* kindOf(SceneObject* object) {
	if (object->isArmorObject())
		return "armor";

	if (object->isWeaponObject())
		return "weapon";

	return "other";
}

float jsonFloat(const JSONSerializationType& j, const char* object, const char* field, float fallback) {
	if (!j.contains(object) || !j[object].contains(field) || !j[object][field].is_number())
		return fallback;

	return j[object][field].get<float>();
}

// Core3's slicing window, answered as a client would: clamp, the right cable, the other. Pre: bot locked; the item is
// in its inventory and passed checkSlice
String runSlice(CreatureObject* bot, TangibleObject* item, BotSliceResult& result) {
	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return "no ghost";

	// The kit goes when the window opens, the clamp and two knife charges in the cuts
	BotSlice::stockTools(bot, 1);

	ManagedReference<SlicingSession*> session = new SlicingSession(bot);
	session->initalizeSlicingMenu(bot, item);

	if (!bot->containsActiveSession(SessionFacadeType::SLICING))
		return "could not start";

	ManagedReference<SuiBox*> box = ghost->getSuiBoxFromWindowType(SuiWindowType::SLICING_MENU);

	if (box == nullptr || !box->isListBox()) {
		session->cancelSession();
		return "no window";
	}

	SuiListBox* listBox = cast<SuiListBox*>(box.get());

	// 2: use a molecular clamp, which shows the right cable
	session->handleMenuSelect(bot, 2, listBox);

	JSONSerializationType state;
	session->writeJSON(state);

	if (!state.contains("SlicingSession") || !state["SlicingSession"].value("usedClamp", false)) {
		session->cancelSession();
		return "no clamp";
	}

	int firstCable = state["SlicingSession"].value("firstCable", 0) == 0 ? 0 : 1;

	// 0 blue, 1 red: the right one first, then the other
	session->handleMenuSelect(bot, firstCable, listBox);
	session->handleMenuSelect(bot, 1 - firstCable, listBox);

	if (bot->containsActiveSession(SessionFacadeType::SLICING)) {
		session->cancelSession();
		return "unfinished";
	}

	// The roll, from the item
	Locker ilocker(item, bot);

	JSONSerializationType itemState;
	item->writeJSON(itemState);

	if (result.kind == "armor") {
		float effectiveness = jsonFloat(itemState, "ArmorObject", "effectivenessSlice", 1);
		float encumbrance = jsonFloat(itemState, "ArmorObject", "encumbranceSlice", 1);

		if (effectiveness > 1.001f) {
			result.stat = "effectiveness";
			result.percent = (int) round((effectiveness - 1) * 100);
		} else if (encumbrance < 0.999f) {
			result.stat = "encumbrance";
			result.percent = (int) round((1 - encumbrance) * 100);
		}
	} else {
		float damage = jsonFloat(itemState, "WeaponObject", "damageSlice", 1);
		float speed = jsonFloat(itemState, "WeaponObject", "speedSlice", 1);

		if (damage > 1.001f) {
			result.stat = "damage";
			result.percent = (int) round((damage - 1) * 100);
		} else if (speed < 0.999f) {
			result.stat = "speed";
			result.percent = (int) round((1 - speed) * 100);
		}
	}

	if (!item->isSliced() || result.percent <= 0)
		return "failed";

	result.ok = true;

	return "";
}

}

bool BotSlice::stockTools(CreatureObject* bot, int count) {
	if (bot == nullptr || !bot->isPlayerCreature())
		return false;

	SceneObject* inventory = bot->getSlottedObject("inventory");

	if (inventory == nullptr)
		return false;

	count = Math::max(1, Math::min(count, 10));

	Locker locker(bot);

	// One knife, refilled when it can't make a slice's two cuts
	ManagedReference<SceneObject*> knifeObject;

	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && object->getGameObjectType() == SceneObjectType::LASERKNIFE) {
			knifeObject = object;
			break;
		}
	}

	if (knifeObject == nullptr) {
		knifeObject = createInInventory(bot, inventory, LASER_KNIFE);

		if (knifeObject == nullptr)
			return false;

		sliceLog().info(true) << bot->getFirstName() << " stocked a laser knife";
	}

	PrecisionLaserKnife* knife = knifeObject.castTo<PrecisionLaserKnife*>();

	if (knife == nullptr)
		return false;

	{
		Locker klocker(knife, bot);

		if (knife->getUseCount() < 2 || knife->getCharges() < 2) {
			knife->setUseCount(KNIFE_CHARGES);
			knife->updateCharges(KNIFE_CHARGES);
		}
	}

	return stockType(bot, inventory, SceneObjectType::MOLECULARCLAMP, MOLECULAR_CLAMP, count)
		&& stockType(bot, inventory, SceneObjectType::ARMORUPGRADEKIT, ARMOR_KIT, count)
		&& stockType(bot, inventory, SceneObjectType::WEAPONUPGRADEKIT, WEAPON_KIT, count);
}

bool BotSlice::getItemInfo(uint64 itemOid, BotItemInfo& out) {
	ZoneServer* zoneServer = ServerCore::getZoneServer();

	if (zoneServer == nullptr || itemOid == 0)
		return false;

	ManagedReference<SceneObject*> object = zoneServer->getObject(itemOid);

	if (object == nullptr)
		return false;

	out.name = object->getDisplayedName();
	out.parent = object->getParentID();
	out.kind = kindOf(object);

	if (!object->isTangibleObject())
		return true;

	TangibleObject* item = object->asTangibleObject();

	out.sliced = item->isSliced();
	out.sliceable = out.kind != "other" && item->isSliceable();

	if (out.kind == "weapon") {
		WeaponObject* weapon = cast<WeaponObject*>(item);

		out.powerup = weapon->hasPowerup();

		if (weapon->isJediWeapon())
			out.sliceable = false;
	}

	return true;
}

void BotSlice::slice(CreatureObject* bot, uint64 itemOid, CreatureObject* owner, BotSliceResult& result) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot)) {
		result.error = "no bot";
		return;
	}

	Locker locker(bot);

	ZoneServer* zoneServer = bot->getZoneServer();
	SceneObject* inventory = bot->getSlottedObject("inventory");
	ManagedReference<SceneObject*> object = zoneServer != nullptr && itemOid != 0 ? zoneServer->getObject(itemOid) : nullptr;

	if (object == nullptr || inventory == nullptr || !object->isTangibleObject()) {
		result.error = "no item";
		return;
	}

	// Core3 slices only items directly in the slicer's inventory; anything else isn't the bot's to hand on either
	if (!inventory->hasObjectInContainer(itemOid)) {
		result.error = "not in inventory";
		return;
	}

	ManagedReference<TangibleObject*> item = object->asTangibleObject();
	result.kind = kindOf(item);

	String error = checkSlice(bot, item, result.kind);

	if (error.isEmpty()) {
		try {
			error = runSlice(bot, item, result);
		} catch (const Exception& e) {
			error = "exception";
			sliceLog().error() << "slicing " << itemOid << ": " << e.getMessage();
		}
	}

	result.error = error;

	// Back to the owner in the same step, sliced or not
	String returnError;

	if (owner != nullptr) {
		result.returned = BotTrade::returnItem(bot, item, owner, returnError);

		if (!result.returned)
			result.error = result.error.isEmpty() ? returnError : result.error + ", " + returnError;
	}

	StringBuffer message;
	message << bot->getFirstName() << (result.ok ? " sliced " : " did not slice ") << item->getDisplayedName() << " (" << itemOid << ")";

	if (owner != nullptr)
		message << " for " << owner->getFirstName();

	if (result.ok)
		message << ": " << result.kind << " " << result.stat << " " << result.percent << "%";

	if (!error.isEmpty())
		message << ": " << error;

	if (owner != nullptr)
		message << (result.returned ? ", returned to the owner's inventory" : ", not returned (" + returnError + ")");

	sliceLog().info(true) << message.toString();
}
