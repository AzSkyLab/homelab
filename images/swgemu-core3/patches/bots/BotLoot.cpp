/*
 * BotLoot (Phase 7 bot players). See BotLoot.h.
 */

#include "BotLoot.h"
#include "BotManager.h"
#include "BotTrade.h"
#include "server/ServerCore.h"
#include "server/zone/Zone.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/creature/ai/AiAgent.h"
#include "server/zone/objects/creature/ai/Creature.h"
#include "server/zone/objects/group/GroupObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/resource/ResourceContainer.h"
#include "server/zone/objects/resource/ResourceSpawn.h"
#include "server/zone/objects/transaction/TransactionLog.h"
#include "server/zone/managers/creature/CreatureManager.h"
#include "server/zone/managers/resource/ResourceManager.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/zone/managers/group/GroupLootTask.h"
#include "server/zone/objects/creature/commands/TransferItemMiscCommand.h"

namespace {

Logger& lootLog() {
	static Logger logger("BotLoot");

	return logger;
}

const char* GOODS_PLAY = "BotLoot";
const char* GOODS_VAR = "goods";

// Room kept free in the bot's inventory (packs and kits are made there)
const int RESERVE_SLOTS = 3;

// The oids of what the bot looted, from its character. Pre: bot locked
void readGoods(CreatureObject* bot, SortedVector<uint64>& out) {
	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return;

	String list = ghost->getScreenPlayData(GOODS_PLAY, GOODS_VAR);

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

// Pre: bot locked
void writeGoods(CreatureObject* bot, const SortedVector<uint64>& goods) {
	PlayerObject* ghost = bot->getPlayerObject();

	if (ghost == nullptr)
		return;

	if (goods.isEmpty()) {
		ghost->deleteScreenPlayData(GOODS_PLAY, GOODS_VAR);
		return;
	}

	StringBuffer list;

	for (int i = 0; i < goods.size(); ++i)
		list << (i > 0 ? "," : "") << goods.get(i);

	ghost->setScreenPlayData(GOODS_PLAY, GOODS_VAR, list.toString());
}

// The units in each resource container in the inventory (container oid -> units). Pre: bot locked
void resourceUnits(SceneObject* inventory, VectorMap<uint64, int>& out) {
	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* object = inventory->getContainerObject(i);

		if (object != nullptr && object->isResourceContainer())
			out.put(object->getObjectID(), static_cast<ResourceContainer*>(object)->getQuantity());
	}
}

String resourceClass(ResourceContainer* container) {
	ManagedReference<ResourceSpawn*> spawn = container->getSpawnObject();

	if (spawn != nullptr)
		return spawn->getFinalClass();

	return container->getDisplayedName();
}


// The crafting score of a spawn's stats: what a crafter weighs. Hide and bone go into armor segments (OQ, SR, UT, MA),
// meat into food (OQ, PE, FL, DR). The average of the four, 0 when the resource has none of them
int craftingScore(bool meat, const BotHarvestOption& o) {
	int sum = meat ? o.oq + o.pe + o.fl + o.dr : o.oq + o.sr + o.ut + o.ma;

	return sum / 4;
}

// The stat that leads for a kind, with its name
void leadStat(const BotHarvestOption& o, String& name, int& value) {
	bool meat = o.kind == "meat";
	const char* names[4] = {"OQ", meat ? "PE" : "SR", meat ? "FL" : "UT", meat ? "DR" : "MA"};
	int values[4] = {o.oq, meat ? o.pe : o.sr, meat ? o.fl : o.ut, meat ? o.dr : o.ma};

	name = "";
	value = 0;

	for (int i = 0; i < 4; ++i) {
		if (values[i] > value) {
			value = values[i];
			name = names[i];
		}
	}
}

// "OQ 870, SR 640, UT 500, MA 702": the stats that make the score
String statsText(const BotHarvestOption& o) {
	StringBuffer text;

	if (o.kind == "meat")
		text << "OQ " << o.oq << ", PE " << o.pe << ", FL " << o.fl << ", DR " << o.dr;
	else
		text << "OQ " << o.oq << ", SR " << o.sr << ", UT " << o.ut << ", MA " << o.ma;

	return text.toString();
}

// One kind of the creature's: the current spawn of its class on this planet, as CreatureManager::harvest finds it. The
// class string is trimmed (a template once had a trailing space; Core3 trims it when it loads the template)
void addOption(ResourceManager* resources, const String& zoneName, const char* kind, const String& rawType, float max,
		Vector<Reference<BotHarvestOption*>>& out) {
	String type = rawType.trim();

	if (type.isEmpty() || max <= 0)
		return;

	Reference<BotHarvestOption*> option = new BotHarvestOption();
	option->kind = kind;
	option->yield = (int) max;

	ManagedReference<ResourceSpawn*> spawn = resources != nullptr ? resources->getCurrentSpawn(type, zoneName) : nullptr;

	if (spawn != nullptr) {
		option->harvestable = true;
		option->spawn = spawn->getName();
		option->resource = spawn->getFinalClass();
		option->oq = spawn->getValueOf("res_quality");
		option->sr = spawn->getValueOf("res_shock_resistance");
		option->ut = spawn->getValueOf("res_toughness");
		option->ma = spawn->getValueOf("res_malleability");
		option->dr = spawn->getValueOf("res_decay_resist");
		option->fl = spawn->getValueOf("res_flavor");
		option->pe = spawn->getValueOf("res_potential_energy");
		option->score = craftingScore(option->kind == "meat", *option);
	}

	out.add(option);
}

// Every kind the creature has, with its current spawn. Reads only; a read lock on the resource manager
void creatureOptions(Creature* creature, Vector<Reference<BotHarvestOption*>>& out) {
	Zone* zone = creature->getZone();

	if (zone == nullptr)
		return;

	ManagedReference<ResourceManager*> resources = zone->getZoneServer()->getResourceManager();

	if (resources == nullptr)
		return;

	String zoneName = zone->getZoneName();
	ReadLocker locker(resources.get());

	addOption(resources, zoneName, "meat", creature->getMeatType(), creature->getMeatMax(), out);
	addOption(resources, zoneName, "hide", creature->getHideType(), creature->getHideMax(), out);
	addOption(resources, zoneName, "bone", creature->getBoneType(), creature->getBoneMax(), out);
}

// Is a better than b: the higher crafting score, then the higher yield
bool betterOption(const BotHarvestOption& a, const BotHarvestOption& b) {
	if (a.score != b.score)
		return a.score > b.score;

	return a.yield > b.yield;
}
}

bool BotLoot::lootCorpse(CreatureObject* bot, uint64 corpseOid, BotLootResult& out) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot)) {
		out.error = "no bot";
		return false;
	}

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(corpseOid) : nullptr;

	if (object == nullptr || !object->isAiAgent()) {
		out.error = object != nullptr && object->isPlayerCreature() ? "player corpse" : "no corpse";
		return false;
	}

	ManagedReference<AiAgent*> corpse = object.castTo<AiAgent*>();

	if (corpse == nullptr || corpse->isPlayerCreature()) {
		out.error = "player corpse";
		return false;
	}

	// The bot's group: the corpse has to be its group's
	ManagedReference<GroupObject*> group;
	uint64 groupId = 0;

	{
		Locker blocker(bot);

		if (!bot->isGrouped() || bot->isDead()) {
			out.error = "not grouped";
			return false;
		}

		group = bot->getGroup();
		groupId = bot->getGroupID();
	}

	if (group == nullptr || groupId == 0) {
		out.error = "not grouped";
		return false;
	}

	// Credits first, with only the corpse locked, as GroupLootTask does: Core3's own split among the group's players
	// in range, and patches/0007 leaves the bots out of it
	{
		Locker clocker(corpse);

		if (!corpse->isDead()) {
			out.error = "alive";
			return false;
		}

		SceneObject* lootContainer = corpse->getSlottedObject("inventory");

		if (lootContainer == nullptr || lootContainer->getContainerPermissions()->getOwnerID() != groupId) {
			out.error = "not the group's";
			return false;
		}

		if (bot->getDistanceTo(corpse) > 16.f) {
			out.error = "too far";
			return false;
		}

		out.credits = corpse->getCashCredits();

		if (out.credits > 0) {
			Reference<GroupLootTask*> task = new GroupLootTask(group, bot, corpse, true);
			task->splitCredits();
		}
	}

	// Then the items
	Locker blocker(bot);
	Locker clocker(corpse, bot);

	SceneObject* lootContainer = corpse->getSlottedObject("inventory");
	SceneObject* botInventory = bot->getInventory();

	if (lootContainer == nullptr || botInventory == nullptr || !corpse->isDead()) {
		out.error = "no corpse";
		return false;
	}

	SortedVector<uint64> goods;
	readGoods(bot, goods);

	auto trxGroup = TransactionLog::getNewTrxGroup();

	for (int i = lootContainer->getContainerObjectsSize() - 1; i >= 0; --i) {
		SceneObject* item = lootContainer->getContainerObject(i);

		if (item == nullptr)
			continue;

		if (botInventory->getContainerObjectsSize() + RESERVE_SLOTS >= (int) botInventory->getContainerVolumeLimit()) {
			out.full = true;
			break;
		}

		uint64 itemOid = item->getObjectID();

		TransactionLog trx(corpse, bot, item, TrxCode::NPCLOOTCLAIM);
		trx.setTrxGroup(trxGroup);

		String itemName = item->getDisplayedName();

		TransferItemMiscCommand::doTransferItemMisc(bot, item, botInventory, -1, trx);

		if (botInventory->hasObjectInContainer(itemOid)) {
			goods.put(itemOid);
			out.moved++;

			if (out.names.size() < NAMES_KEPT)
				out.names.add(itemName);
		}
	}

	writeGoods(bot, goods);

	out.left = lootContainer->getContainerObjectsSize();
	out.ok = true;

	lootLog().info(true) << bot->getFirstName() << " loots " << corpse->getDisplayedName() << ": " << out.moved << " item(s), "
		<< out.left << " left, " << out.credits << " credits to the group";

	if (out.left == 0) {
		PlayerManager* playerManager = zoneServer->getPlayerManager();

		// The corpse goes at once if no one in the group can still harvest it
		if (playerManager != nullptr)
			playerManager->rescheduleCorpseDestruction(bot, corpse);
	}

	return true;
}

void BotLoot::corpsesNear(CreatureObject* bot, SceneObject* center, float range, Vector<Reference<BotCorpseInfo*>>& out) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot))
		return;

	if (center == nullptr)
		center = bot;

	Zone* zone = center->getZone();
	uint64 groupId = bot->getGroupID();

	if (zone == nullptr || groupId == 0 || range <= 0)
		return;

	if (range > 128)
		range = 128;

	// World coordinates: indoors or mounted, the position is relative to a cell or a vehicle
	Vector3 at = center->getWorldPosition();

	SortedVector<ManagedReference<TreeEntry*>> objects(512, 512);
	zone->getInRangeObjects(at.getX(), at.getZ(), at.getY(), range, &objects, true);

	VectorMap<float, Reference<BotCorpseInfo*>> found;
	found.setAllowDuplicateInsertPlan();

	for (int i = 0; i < objects.size(); ++i) {
		SceneObject* object = static_cast<SceneObject*>(objects.get(i).get());

		if (object == nullptr || !object->isAiAgent() || object->isPlayerCreature())
			continue;

		AiAgent* corpse = object->asAiAgent();

		if (corpse == nullptr || !corpse->isDead() || corpse->isPet() || corpse->getZone() == nullptr)
			continue;

		SceneObject* inventory = corpse->getSlottedObject("inventory");

		if (inventory == nullptr || inventory->getContainerPermissions()->getOwnerID() != groupId)
			continue;

		Reference<BotCorpseInfo*> info = new BotCorpseInfo();
		info->oid = corpse->getObjectID();
		info->distance = center->getDistanceTo(corpse);
		info->items = inventory->getContainerObjectsSize();
		info->credits = corpse->getCashCredits();
		info->name = corpse->getDisplayedName();

		if (corpse->isCreature()) {
			Creature* creature = static_cast<Creature*>(corpse);

			info->harvest = creature->hasOrganics() && creature->getDnaState() != CreatureManager::DNADEATH;
		}

		if (info->items == 0 && info->credits == 0 && !info->harvest)
			continue;

		found.put(info->distance, info);
	}

	for (int i = 0; i < found.size() && i < CORPSES_MAX; ++i)
		out.add(found.elementAt(i).getValue());
}

bool BotLoot::harvest(CreatureObject* bot, uint64 corpseOid, const String& kind, BotHarvestResult& out) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot)) {
		out.error = "no bot";
		return false;
	}

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(corpseOid) : nullptr;

	if (object == nullptr || !object->isCreatureObject()) {
		out.error = "no corpse";
		return false;
	}

	CreatureObject* creo = object->asCreatureObject();

	if (!creo->isCreature()) {
		out.error = "not a creature";
		return false;
	}

	ManagedReference<Creature*> creature = cast<Creature*>(creo);

	if (creature == nullptr) {
		out.error = "not a creature";
		return false;
	}

	Locker blocker(bot);
	Locker clocker(creature, bot);

	if (!creature->isDead() || creature->getZone() == nullptr) {
		out.error = "alive";
		return false;
	}

	if (!bot->isInRange(creature, 7.f)) {
		out.error = "too far";
		return false;
	}

	if (creature->getDnaState() == CreatureManager::DNADEATH) {
		out.error = "nothing to harvest";
		return false;
	}

	// meat 234, hide 235, bone 236 (the harvest radial's ids)
	int type = 0;
	String want = kind.toLowerCase();
	Vector<Reference<BotHarvestOption*>> options;
	creatureOptions(creature, options);

	// Only what the planet has a spawn of can be harvested. The asked-for kind if the creature has it, else the best
	Reference<BotHarvestOption*> pick;

	for (int i = 0; i < options.size(); ++i) {
		BotHarvestOption* option = options.get(i);

		if (!option->harvestable)
			continue;

		if (option->kind == want) {
			pick = option;
			break;
		}

		if (pick == nullptr || betterOption(*option, *pick))
			pick = option;
	}

	// Asked for a kind the creature hasn't got
	out.fallback = pick != nullptr && pick->kind != want && !want.isEmpty() && want != "any";

	// The best of the others, to say why the pick is the pick
	Reference<BotHarvestOption*> runnerUp;

	for (int i = 0; i < options.size(); ++i) {
		BotHarvestOption* option = options.get(i);

		if (option->harvestable && option != pick.get() && (runnerUp == nullptr || betterOption(*option, *runnerUp)))
			runnerUp = option;
	}

	if (pick != nullptr) {
		type = pick->kind == "meat" ? 234 : pick->kind == "hide" ? 235 : 236;
		out.spawn = pick->spawn;
		out.score = pick->score;
		leadStat(*pick, out.lead, out.leadValue);
		out.stats = statsText(*pick);

		if (runnerUp != nullptr) {
			out.altKind = runnerUp->kind;
			out.altScore = runnerUp->score;
		}
	}

	if (type == 0) {
		out.error = "nothing to harvest";
		return false;
	}

	if (!creature->canHarvestMe(bot)) {
		out.error = "cannot harvest";
		return false;
	}

	SceneObject* inventory = bot->getInventory();

	if (inventory == nullptr) {
		out.error = "failed";
		return false;
	}

	VectorMap<uint64, int> before;
	resourceUnits(inventory, before);

	ManagedReference<CreatureManager*> manager = creature->getZone()->getCreatureManager();

	if (manager == nullptr) {
		out.error = "failed";
		return false;
	}

	manager->harvest(creature, bot, type);

	VectorMap<uint64, int> after;
	resourceUnits(inventory, after);

	for (int i = 0; i < after.size(); ++i) {
		uint64 oid = after.elementAt(i).getKey();
		int units = after.elementAt(i).getValue();
		int was = before.contains(oid) ? before.get(oid) : 0;

		if (units > was) {
			out.amount += units - was;

			ManagedReference<SceneObject*> container = zoneServer->getObject(oid);

			if (container != nullptr && out.resource.isEmpty())
				out.resource = resourceClass(static_cast<ResourceContainer*>(container.get()));
		}
	}

	out.kind = type == 234 ? "meat" : type == 235 ? "hide" : "bone";
	out.ok = out.amount > 0;

	if (!out.ok)
		out.error = "failed";

	lootLog().info(true) << bot->getFirstName() << " harvests " << creature->getDisplayedName() << ": " << out.amount << " units of "
		<< out.kind << " (" << out.resource << ", spawn " << out.spawn << ", score " << out.score << (out.fallback ? ", fallback" : "") << ")";

	return out.ok;
}

bool BotLoot::harvestChoice(CreatureObject* bot, uint64 corpseOid, Vector<Reference<BotHarvestOption*>>& out, String& error) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot)) {
		error = "no bot";
		return false;
	}

	ZoneServer* zoneServer = bot->getZoneServer();
	ManagedReference<SceneObject*> object = zoneServer != nullptr ? zoneServer->getObject(corpseOid) : nullptr;

	if (object == nullptr || !object->isCreatureObject()) {
		error = "no corpse";
		return false;
	}

	if (!object->asCreatureObject()->isCreature()) {
		error = "not a creature";
		return false;
	}

	ManagedReference<Creature*> creature = cast<Creature*>(object->asCreatureObject());

	if (creature == nullptr) {
		error = "not a creature";
		return false;
	}

	creatureOptions(creature, out);

	return true;
}

void BotLoot::goods(CreatureObject* bot, Vector<Reference<BotGoodsItem*>>& out) {
	if (bot == nullptr)
		return;

	Locker locker(bot);

	SceneObject* inventory = bot->getInventory();
	ZoneServer* zoneServer = bot->getZoneServer();

	if (inventory == nullptr || zoneServer == nullptr)
		return;

	SortedVector<uint64> recorded;
	readGoods(bot, recorded);

	SortedVector<uint64> kept;

	for (int i = 0; i < recorded.size(); ++i) {
		uint64 oid = recorded.get(i);

		if (!inventory->hasObjectInContainer(oid))
			continue;

		ManagedReference<SceneObject*> item = zoneServer->getObject(oid);

		if (item == nullptr)
			continue;

		kept.put(oid);

		Reference<BotGoodsItem*> entry = new BotGoodsItem();
		entry->oid = oid;
		entry->name = item->getDisplayedName();
		entry->resource = item->isResourceContainer();
		entry->quantity = entry->resource ? static_cast<ResourceContainer*>(item.get())->getQuantity() : 1;
		entry->tradable = !item->isNoTrade() && !item->containsNoTradeObjectRecursive();
		out.add(entry);
	}

	// Harvested resources: all the containers in the pack
	for (int i = 0; i < inventory->getContainerObjectsSize(); ++i) {
		SceneObject* item = inventory->getContainerObject(i);

		if (item == nullptr || !item->isResourceContainer() || kept.contains(item->getObjectID()))
			continue;

		ResourceContainer* container = static_cast<ResourceContainer*>(item);

		Reference<BotGoodsItem*> entry = new BotGoodsItem();
		entry->oid = item->getObjectID();
		entry->name = resourceClass(container);
		entry->resource = true;
		entry->quantity = container->getQuantity();
		entry->tradable = !item->isNoTrade();
		out.add(entry);
	}

	if (kept.size() != recorded.size())
		writeGoods(bot, kept);
}

bool BotLoot::offerGoods(CreatureObject* bot, CreatureObject* player, int& offered, int& remaining, String& error) {
	if (bot == nullptr || !BotManager::instance()->isOnlineBot(bot)) {
		error = "no bot";
		return false;
	}

	if (player == nullptr || player == bot || !player->isPlayerCreature() || !player->isOnline() || player->getZone() == nullptr) {
		error = "no player";
		return false;
	}

	Locker blocker(bot);

	Vector<Reference<BotGoodsItem*>> all;
	goods(bot, all);

	Vector<uint64> chosen;
	int tradable = 0;

	for (int i = 0; i < all.size(); ++i) {
		if (all.get(i)->tradable)
			++tradable;
	}

	if (tradable == 0) {
		error = "no goods";
		return false;
	}

	Locker clocker(player, bot);

	if (bot->getDistanceTo(player) >= OFFER_RANGE) {
		error = "too far";
		return false;
	}

	if (BotTrade::hasBundle(bot)) {
		error = "busy";
		return false;
	}

	// Core3's room rule for a trade: the receiver's pack, with the items it gets, stays under its limit
	SceneObject* inventory = player->getInventory();

	if (inventory == nullptr) {
		error = "no player";
		return false;
	}

	int room = (int) inventory->getContainerVolumeLimit() - inventory->getContainerObjectsSize() - 1;

	if (room <= 0) {
		error = "inventory full";
		return false;
	}

	int limit = Math::min(room, (int) MAX_BUNDLE);

	for (int i = 0; i < all.size() && chosen.size() < limit; ++i) {
		if (all.get(i)->tradable)
			chosen.add(all.get(i)->oid);
	}

	if (!BotTrade::giveBundle(bot, player, chosen)) {
		error = "busy";
		return false;
	}

	offered = chosen.size();
	remaining = tradable - chosen.size();

	lootLog().info(true) << bot->getFirstName() << " offers " << offered << " item(s) to " << player->getFirstName() << " (" << remaining
		<< " more to follow)";

	return true;
}

void BotLoot::cancelOffer(CreatureObject* bot) {
	if (bot == nullptr)
		return;

	Locker locker(bot);

	BotTrade::cancelBundle(bot);
}

bool BotLoot::markGood(CreatureObject* bot, uint64 itemOid) {
	if (bot == nullptr)
		return false;

	Locker locker(bot);

	SceneObject* inventory = bot->getInventory();

	if (inventory == nullptr || !inventory->hasObjectInContainer(itemOid))
		return false;

	SortedVector<uint64> goods;
	readGoods(bot, goods);
	goods.put(itemOid);
	writeGoods(bot, goods);

	return true;
}

bool BotLoot::isGood(CreatureObject* bot, uint64 itemOid) {
	if (bot == nullptr || itemOid == 0)
		return false;

	SortedVector<uint64> goods;
	readGoods(bot, goods);

	return goods.contains(itemOid);
}
