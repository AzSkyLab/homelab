/*
 * BotFactory (Phase 3 bot players). See BotFactory.h.
 *
 * The character is made the way PlayerCreationManager::createCharacter makes one for a client: the species
 * template's child objects (PlayerObject, inventory, datapad, bank, mission bag), the starting profession's and the
 * species' HAM, the species' starting skills, starting cash and items, hair, then a characters_dirty row that the
 * next save moves into characters. What a client would choose (name, species, hair, profession) comes from the
 * roster instead, and the tutorial is skipped: the character is saved offline at its station.
 */

#include "BotFactory.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/db/ServerDatabase.h"
#include "server/ServerCore.h"
#include "server/zone/managers/player/PlayerManager.h"
#include "server/zone/managers/player/creation/PlayerCreationManager.h"
#include "server/zone/managers/skill/SkillManager.h"
#include "server/zone/managers/name/NameManager.h"
#include "server/zone/managers/jedi/JediManager.h"
#include "server/zone/managers/collision/CollisionManager.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/objects/cell/CellObject.h"
#include "server/zone/objects/scene/WorldCoordinates.h"
#include "server/zone/objects/tangible/TangibleObject.h"
#include "server/zone/objects/transaction/TransactionLog.h"
#include "templates/manager/TemplateManager.h"
#include "templates/creature/PlayerCreatureTemplate.h"
#include "templates/customization/CustomizationIdManager.h"
#include "templates/customization/AssetCustomizationManagerTemplate.h"
#include "templates/params/PaletteColorCustomizationVariable.h"
#include "templates/datatables/DataTableIff.h"
#include "templates/datatables/DataTableRow.h"
#include "engine/lua/Lua.h"

using namespace server::zone::managers::bot;

namespace {

Logger& factoryLog() {
	static Logger logger("BotFactory");

	return logger;
}

String getRaceFile(const BotEntry& entry) {
	return "object/creature/player/" + entry.species + "_" + entry.sex + ".iff";
}

bool isValidAccountName(const String& name) {
	if (name.length() < 3 || name.length() > 32)
		return false;

	for (int i = 0; i < name.length(); ++i) {
		char c = name.charAt(i);

		if (!isalnum(c) && c != '_')
			return false;
	}

	return true;
}

bool isEquipped(CreatureObject* creature, uint32 templateCRC) {
	for (int i = 0; i < creature->getSlottedObjectsSize(); ++i) {
		Reference<SceneObject*> object = creature->getSlottedObject(i);

		if (object != nullptr && object->getServerObjectCRC() == templateCRC)
			return true;
	}

	return false;
}

}

String BotFactory::getStartingProfession(const String& job) {
	if (job == "doctor")
		return "science_medic";

	if (job == "dancer" || job == "musician")
		return "social_entertainer";

	if (job == "smuggler" || job == "rifleman")
		return "combat_marksman";

	if (job == "tank")
		return "combat_brawler";

	if (job == "medic")
		return "science_medic";

	if (job == "ranger" || job == "squadleader")
		return "outdoors_scout";

	if (job == "entertainer")
		return "social_entertainer";

	if (job == "commando")
		return "combat_marksman";

	if (job == "mayor" || job == "citizen")
		return "crafting_artisan";

	return "";
}

bool BotFactory::parseEntry(LuaObject& bot, BotEntry& entry) {
	entry.name = bot.getStringField("name").trim();
	entry.account = bot.getStringField("account").trim();
	entry.species = bot.getStringField("species").trim().toLowerCase();
	entry.sex = bot.getStringField("sex").trim().toLowerCase();
	entry.hair = bot.getStringField("hair").trim();
	entry.job = bot.getStringField("job").trim().toLowerCase();
	entry.city = bot.getStringField("city").trim();
	entry.online = bot.getStringField("online").trim().toLowerCase();
	entry.owner = bot.getLongField("owner");
	entry.hiredAt = bot.getLongField("hiredAt");
	entry.hairColor = bot.getSignedIntField("hairColor", -1);
	entry.skinTone = bot.getSignedIntField("skinTone", -1);
	entry.weapon = bot.getStringField("weapon").trim();
	entry.campKit = bot.getStringField("campKit").trim();
	entry.doctrine = bot.getStringField("doctrine").trim().toLowerCase();

	int space = entry.name.indexOf(" ");
	entry.firstName = space == -1 ? entry.name : entry.name.subString(0, space);

	LuaObject skills = bot.getObjectField("skills");

	if (skills.isValidTable()) {
		for (int j = 1; j <= skills.getTableSize(); ++j)
			entry.skills.add(skills.getStringAt(j));
	}

	skills.pop();

	LuaObject outfit = bot.getObjectField("outfit");

	if (outfit.isValidTable()) {
		for (int j = 1; j <= outfit.getTableSize(); ++j)
			entry.outfit.add(outfit.getStringAt(j));
	}

	outfit.pop();

	LuaObject carry = bot.getObjectField("carry");

	if (carry.isValidTable()) {
		for (int j = 1; j <= carry.getTableSize(); ++j)
			entry.carry.add(carry.getStringAt(j));
	}

	carry.pop();

	LuaObject station = bot.getObjectField("station");

	if (station.isValidTable()) {
		entry.planet = station.getStringField("planet");
		entry.x = station.getFloatField("x");
		entry.z = station.getFloatField("z");
		entry.y = station.getFloatField("y");
		entry.cell = station.getLongField("cell");
		entry.heading = station.getFloatField("heading");
	}

	station.pop();

	return true;
}

bool BotFactory::loadRoster(const String& path, BotRosterList& out, BotSettings& settings, const char* globalName,
		const BotRosterList* known, BotRosterList* invalid) {
	Logger& logger = factoryLog();

	{
		File file(path);

		if (!file.setReadOnly()) {	// opens it: File::exists() only says whether it is open
			logger.warning() << "no roster at " << path;
			return false;
		}

		file.close();
	}

	Lua* lua = new Lua();
	lua->init();

	if (!lua->runFile(path)) {
		logger.error() << "could not run " << path;

		delete lua;
		return false;
	}

	LuaObject roster = lua->getGlobalObject(globalName);

	if (!roster.isValidTable()) {
		logger.error() << path << " has no " << globalName << " table";

		roster.pop();
		delete lua;
		return false;
	}

	LuaObject settingsTable = roster.getObjectField("settings");

	if (settingsTable.isValidTable()) {
		settings.loginDelay = settingsTable.getIntField("loginDelay", settings.loginDelay);
		settings.logoutDelay = settingsTable.getIntField("logoutDelay", settings.logoutDelay);
	}

	settingsTable.pop();

	LuaObject bots = roster.getObjectField("bots");

	if (!bots.isValidTable()) {
		logger.error() << path << " has no " << globalName << ".bots table";

		bots.pop();
		roster.pop();
		delete lua;
		return false;
	}

	// What an entry must differ from: the entries already in the manager (the roster, for the own crews), then the
	// ones accepted from this file
	BotRosterList scope;

	if (known != nullptr)
		scope = *known;

	for (int i = 1; i <= bots.getTableSize(); ++i) {
		LuaObject bot = bots.getObjectAt(i);

		if (!bot.isValidTable()) {
			logger.warning() << "roster bot " << i << " is not a table, skipped";

			bot.pop();
			continue;
		}

		Reference<BotEntry*> entry = new BotEntry();

		parseEntry(bot, *entry);
		bot.pop();

		String reason;

		if (!validateEntry(*entry, scope, reason)) {
			logger.error() << "roster bot " << i << " (" << entry->name << ") skipped: " << reason;

			if (invalid != nullptr)
				invalid->add(entry);

			continue;
		}

		scope.add(entry);
		out.add(entry);
	}

	bots.pop();
	roster.pop();

	delete lua;

	logger.info(true) << "loaded " << out.size() << " bots from " << path;

	return true;
}

bool BotFactory::validateEntry(const BotEntry& entry, const BotRosterList& accepted, String& reason) {
	if (entry.name.isEmpty() || entry.firstName.isEmpty()) {
		reason = "no name";
		return false;
	}

	if (!isValidAccountName(entry.account)) {
		reason = "account '" + entry.account + "' must be 3-32 letters, digits or _";
		return false;
	}

	if (entry.sex != "male" && entry.sex != "female") {
		reason = "sex must be male or female";
		return false;
	}

	if (entry.online == "owner" && entry.owner == 0) {
		reason = "online \"owner\" with no owner";
		return false;
	}

	if (entry.owner != 0 && entry.online != "owner") {
		reason = "an own-crew bot is online \"owner\"";
		return false;
	}

	if (entry.hairColor < -1 || entry.skinTone < -1) {
		reason = "a palette index below -1";
		return false;
	}

	if (getStartingProfession(entry.job).isEmpty()) {
		reason = "unknown job '" + entry.job + "' (doctor, dancer, musician, smuggler, tank, rifleman, medic, ranger, squadleader, entertainer, commando, mayor or citizen)";
		return false;
	}

	String raceFile = getRaceFile(entry);
	PlayerCreatureTemplate* playerTemplate = dynamic_cast<PlayerCreatureTemplate*>(TemplateManager::instance()->getTemplate(raceFile.hashCode()));

	if (playerTemplate == nullptr) {
		reason = "unknown species " + raceFile;
		return false;
	}

	ZoneServer* zoneServer = ServerCore::getZoneServer();

	if (zoneServer != nullptr && zoneServer->getNameManager() != nullptr) {
		int result = zoneServer->getNameManager()->validateName(entry.name, playerTemplate->getSpecies());

		if (result != NameManagerResult::ACCEPTED) {
			reason = "the name manager declines '" + entry.name + "' (result " + String::valueOf(result) + ")";
			return false;
		}
	}

	if (!entry.hair.isEmpty()) {
		HairAssetData* hairData = CustomizationIdManager::instance()->getHairAssetData(entry.hair);

		if (hairData == nullptr) {
			reason = "unknown hair " + entry.hair;
			return false;
		}

		if (hairData->getServerPlayerTemplate() != raceFile) {
			reason = "hair " + entry.hair + " is for " + hairData->getServerPlayerTemplate();
			return false;
		}

		if (entry.owner != 0 && !hairData->isAvailableAtCreation()) {
			reason = "hair " + entry.hair + " is not offered at character creation";
			return false;
		}
	}

	for (int i = 0; i < entry.skills.size(); ++i) {
		if (SkillManager::instance()->getSkill(entry.skills.get(i)) == nullptr) {
			reason = "unknown skill " + entry.skills.get(i);
			return false;
		}
	}

	for (int i = 0; i < entry.carry.size(); ++i) {
		if (TemplateManager::instance()->getTemplate(entry.carry.get(i).hashCode()) == nullptr) {
			reason = "unknown carry template " + entry.carry.get(i);
			return false;
		}
	}

	for (int i = 0; i < entry.outfit.size(); ++i) {
		if (TemplateManager::instance()->getTemplate(entry.outfit.get(i).hashCode()) == nullptr) {
			reason = "unknown outfit template " + entry.outfit.get(i);
			return false;
		}
	}

	if (entry.planet.isEmpty()) {
		reason = "no station planet";
		return false;
	}

	if (zoneServer != nullptr && zoneServer->getZone(entry.planet) == nullptr) {
		reason = "planet " + entry.planet + " is not enabled";
		return false;
	}

	for (int i = 0; i < accepted.size(); ++i) {
		const BotEntry* other = accepted.get(i);

		if (other->firstName.toLowerCase() == entry.firstName.toLowerCase()) {
			reason = "first name " + entry.firstName + " is already used by " + other->name;
			return false;
		}

		if (other->account.toLowerCase() == entry.account.toLowerCase()) {
			reason = "account " + entry.account + " is already used by " + other->name;
			return false;
		}
	}

	return true;
}

uint64 BotFactory::ensureCharacter(ZoneServer* zoneServer, const BotEntry& entry) {
	static Mutex mutex;

	Logger& logger = factoryLog();

	if (zoneServer == nullptr)
		return 0;

	// Zones, the name map and the boot cleanup of characters_dirty come first
	for (int i = 0; i < 600 && zoneServer->isServerLoading(); ++i)
		Thread::sleep(500);

	if (zoneServer->isServerShuttingDown() || zoneServer->isServerOffline() || zoneServer->isServerLoading()) {
		logger.error() << entry.name << ": the server isn't up";
		return 0;
	}

	Locker locker(&mutex);

	uint32 accountID = ensureAccount(entry.account);

	if (accountID == 0)
		return 0;

	uint64 oid = findCharacter(accountID, zoneServer->getGalaxyID(), entry.firstName);

	if (oid == 0)
		return createCharacter(zoneServer, entry, accountID);

	ManagedReference<SceneObject*> object = zoneServer->getObject(oid, true);

	if (object == nullptr || !object->isPlayerCreature()) {
		logger.error() << entry.name << ": account " << entry.account << " lists character " << oid << " but the object database doesn't have it";
		return 0;
	}

	CreatureObject* creature = object->asCreatureObject();

	Locker clocker(creature);

	PlayerObject* ghost = creature->getPlayerObject();

	if (ghost == nullptr) {
		logger.error() << entry.name << ": character " << oid << " has no PlayerObject";
		return 0;
	}

	PlayerManager* playerManager = zoneServer->getPlayerManager();

	if (playerManager != nullptr && !playerManager->existsName(entry.firstName))
		playerManager->addPlayer(creature);

	awardSkills(creature, entry);
	ensureHair(zoneServer, creature, entry);
	ensureLook(zoneServer, creature, entry);
	ensureOutfit(zoneServer, creature, entry);
	ensureCarry(zoneServer, creature, entry);

	if (creature->getZone() == nullptr && creature->getParent() == nullptr && !ghost->isOnline())
		placeAtStation(zoneServer, creature, entry);

	return oid;
}

uint32 BotFactory::ensureAccount(const String& username) {
	Logger& logger = factoryLog();

	String name = username;
	Database::escapeString(name);

	StringBuffer query;
	query << "SELECT account_id FROM accounts WHERE username = '" << name << "' LIMIT 1";

	try {
		UniqueReference<ResultSet*> result(ServerDatabase::instance()->executeQuery(query));

		if (result != nullptr && result->next())
			return result->getUnsignedInt(0);

		// The stored hash is of a random secret that is never kept, so no password logs in
		String salt = Crypto::randomSalt();
		String hash = Crypto::SHA256Hash(Crypto::randomSalt<64>() + salt);

		StringBuffer insert;
		insert << "INSERT INTO accounts (username, password, station_id, salt, admin_level) VALUES ('"
				<< name << "', '" << hash << "', " << System::random() << ", '" << salt << "', 0)";

		// executeQuery, not executeStatement: that one is queued, and the account must exist before the next query
		UniqueReference<ResultSet*> inserted(ServerDatabase::instance()->executeQuery(insert));

		UniqueReference<ResultSet*> created(ServerDatabase::instance()->executeQuery(query));

		if (created != nullptr && created->next()) {
			uint32 accountID = created->getUnsignedInt(0);

			logger.info(true) << "created account " << username << " (" << accountID << ")";

			return accountID;
		}
	} catch (const DatabaseException& e) {
		logger.error() << "account " << username << ": " << e.getMessage();
	}

	logger.error() << "could not make account " << username;

	return 0;
}

uint64 BotFactory::findCharacter(uint32 accountID, int galaxyID, const String& firstName) {
	String name = firstName;
	Database::escapeString(name);

	StringBuffer query;
	query << "SELECT character_oid FROM characters WHERE account_id = " << accountID << " AND galaxy_id = " << galaxyID
			<< " AND firstname = '" << name << "'"
			<< " UNION SELECT character_oid FROM characters_dirty WHERE account_id = " << accountID << " AND galaxy_id = " << galaxyID
			<< " AND firstname = '" << name << "'";

	try {
		UniqueReference<ResultSet*> result(ServerDatabase::instance()->executeQuery(query));

		if (result != nullptr && result->next())
			return result->getUnsignedLong(0);
	} catch (const DatabaseException& e) {
		factoryLog().error() << "character lookup for " << firstName << ": " << e.getMessage();
	}

	return 0;
}

uint64 BotFactory::createCharacter(ZoneServer* zoneServer, const BotEntry& entry, uint32 accountID) {
	Logger& logger = factoryLog();

	PlayerManager* playerManager = zoneServer->getPlayerManager();

	String raceFile = getRaceFile(entry);
	uint32 serverObjectCRC = raceFile.hashCode();

	PlayerCreatureTemplate* playerTemplate = dynamic_cast<PlayerCreatureTemplate*>(TemplateManager::instance()->getTemplate(serverObjectCRC));

	if (playerTemplate == nullptr || playerManager == nullptr) {
		logger.error() << entry.name << ": no player template " << raceFile;
		return 0;
	}

	// The checks PlayerManager::checkPlayerName makes for a client
	if (playerManager->existsName(entry.firstName)) {
		logger.error() << entry.name << ": another character already has the first name " << entry.firstName;
		return 0;
	}

	NameManager* nameManager = zoneServer->getNameManager();

	if (nameManager != nullptr) {
		int result = nameManager->validateName(entry.name, playerTemplate->getSpecies());

		if (result != NameManagerResult::ACCEPTED) {
			logger.error() << entry.name << ": the name manager declines the name (result " << result << ")";
			return 0;
		}
	}

	// player_creation_manager.lua, as PlayerCreationManager reads it
	int startingCash = 100, startingBank = 1000, skillPoints = 250;

	Lua* lua = new Lua();
	lua->init();

	if (lua->runFile("scripts/managers/player_creation_manager.lua")) {
		startingCash = lua->getGlobalInt("startingCash");
		startingBank = lua->getGlobalInt("startingBank");
		skillPoints = lua->getGlobalInt("skillPoints");
	}

	delete lua;

	ManagedReference<CreatureObject*> playerCreature = zoneServer->createObject(serverObjectCRC, 2).castTo<CreatureObject*>();

	if (playerCreature == nullptr) {
		logger.error() << entry.name << ": could not create " << raceFile;
		return 0;
	}

	Locker playerLocker(playerCreature);

	playerCreature->createChildObjects();

	// A height in the middle half of the species' range, the same for a name every time
	float minScale = playerTemplate->getMinScale();
	float maxScale = playerTemplate->getMaxScale();
	float fraction = 0.25f + 0.5f * ((entry.name.hashCode() % 1000) / 999.f);

	playerCreature->setHeight(minScale + (maxScale - minScale) * fraction, false);
	playerCreature->setCustomObjectName(entry.name, false);

	playerCreature->clearCashCredits(false);
	playerCreature->clearBankCredits(false);

	{
		TransactionLog trx(TrxCode::CHARACTERCREATION, playerCreature, startingCash, true);
		playerCreature->addCashCredits(startingCash, false);
	}
	{
		TransactionLog trx(TrxCode::CHARACTERCREATION, playerCreature, startingBank, false);
		playerCreature->addBankCredits(startingBank, false);
	}

	ManagedReference<PlayerObject*> ghost = playerCreature->getPlayerObject();

	if (ghost == nullptr) {
		logger.error() << entry.name << ": the template made no PlayerObject";

		playerCreature->destroyPlayerCreatureFromDatabase(true);
		return 0;
	}

	String profession = getStartingProfession(entry.job);

	// Skill points before any skill
	ghost->setSkillPoints(skillPoints);
	ghost->setStarterProfession(profession);

	setStartingHam(playerCreature, profession, entry.species + "_" + entry.sex);

	SkillManager* skillManager = SkillManager::instance();
	skillManager->awardSkill(profession + "_novice", playerCreature, false, true, true);

	const Vector<String>& startingSkills = playerTemplate->getStartingSkills();

	for (int i = 0; i < startingSkills.size(); ++i)
		skillManager->awardSkill(startingSkills.get(i), playerCreature, false, true, true);

	ghost->setAccountID(accountID);
	ghost->initializeAccount();

	ghost->setLanguageID(playerTemplate->getDefaultLanguage(), false);

	Time now;
	ghost->setBirthDate(now.getTime());

	ensureHair(zoneServer, playerCreature, entry);
	ensureLook(zoneServer, playerCreature, entry);

	SceneObject* inventory = playerCreature->getSlottedObject("inventory");

	if (inventory != nullptr)
		PlayerCreationManager::instance()->addStartingItemsInto(playerCreature, inventory);

	awardSkills(playerCreature, entry);
	ensureOutfit(zoneServer, playerCreature, entry);
	ensureCarry(zoneServer, playerCreature, entry);

	if (!placeAtStation(zoneServer, playerCreature, entry)) {
		playerCreature->destroyPlayerCreatureFromDatabase(true);
		return 0;
	}

	uint64 oid = playerCreature->getObjectID();

	// The next save moves this row into characters, with the object (ObjectManager::onCommitData)
	try {
		StringBuffer query;
		query << "INSERT INTO `characters_dirty` (`character_oid`, `account_id`, `galaxy_id`, `firstname`, `surname`, `race`, `gender`, `template`)"
				<< " VALUES (" << oid << "," << accountID << "," << zoneServer->getGalaxyID() << ",'"
				<< playerCreature->getFirstName().escapeString() << "','" << playerCreature->getLastName().escapeString() << "',"
				<< playerTemplate->getRace() << "," << (entry.sex == "female" ? 1 : 0) << ",'" << raceFile.escapeString() << "')";

		UniqueReference<ResultSet*> inserted(ServerDatabase::instance()->executeQuery(query));	// synchronous, as above
	} catch (const DatabaseException& e) {
		logger.error() << entry.name << ": " << e.getMessage();

		playerCreature->destroyPlayerCreatureFromDatabase(true);
		return 0;
	}

	playerManager->addPlayer(playerCreature);

	JediManager::instance()->onPlayerCreated(playerCreature);

	logger.info(true) << "created " << entry.name << " (" << entry.species << " " << entry.sex << ", " << entry.job << ", " << entry.city
			<< ") on account " << entry.account << ", oid " << oid << ": " << playerCreature->getSkillList()->size() << " skill boxes, "
			<< ghost->getSkillPoints() << " skill points left, at " << entry.planet << " cell " << entry.cell;

	return oid;
}

void BotFactory::setStartingHam(CreatureObject* creature, const String& profession, const String& raceName) {
	TemplateManager* templateManager = TemplateManager::instance();

	int ham[9] = {0};

	IffStream* iffStream = templateManager->openIffFile("datatables/creation/profession_mods.iff");

	if (iffStream != nullptr) {
		DataTableIff professionMods;
		professionMods.readObject(iffStream);

		delete iffStream;

		auto rows = professionMods.getRowsByColumn(0, profession);

		if (rows.size() > 0) {
			for (int i = 0; i < 9; ++i) {
				int value = 0;
				rows.get(0)->getValue(i + 1, value);
				ham[i] += value;
			}
		}
	}

	iffStream = templateManager->openIffFile("datatables/creation/racial_mods.iff");

	if (iffStream != nullptr) {
		DataTableIff racialMods;
		racialMods.readObject(iffStream);

		delete iffStream;

		// Column 0 holds the male template names, column 1 the female
		auto rows = racialMods.getRowsByColumn(raceName.endsWith("_female") ? 1 : 0, raceName);

		if (rows.size() > 0) {
			for (int i = 0; i < 9; ++i) {
				int value = 0;
				rows.get(0)->getValue(i + 2, value);
				ham[i] += value;
			}
		}
	}

	for (int i = 0; i < 9; ++i) {
		creature->setBaseHAM(i, ham[i], false);
		creature->setHAM(i, ham[i], false);
		creature->setMaxHAM(i, ham[i], false);
	}
}

void BotFactory::awardSkills(CreatureObject* creature, const BotEntry& entry) {
	SkillManager* skillManager = SkillManager::instance();

	for (int i = 0; i < entry.skills.size(); ++i) {
		const String& skillName = entry.skills.get(i);

		if (creature->hasSkill(skillName))
			continue;

		// With every skill it requires, and no experience needed
		if (!skillManager->awardSkill(skillName, creature, false, true, true) || !creature->hasSkill(skillName))
			factoryLog().error() << entry.name << ": could not award " << skillName << " (skill points left: " << creature->getPlayerObject()->getSkillPoints() << ")";
	}
}

// Sets each palette variable of the appearance whose palette file name contains `needle` ("hair", "skin") to an index,
// kept within the palette's creation colours. Returns how many it set. object must be locked.
static int setPalette(TangibleObject* object, const String& appearance, const char* needle, int index, bool notify) {
	VectorMap<String, Reference<CustomizationVariable*> > variables;
	variables.setNullValue(nullptr);

	AssetCustomizationManagerTemplate::instance()->getCustomizationVariables(appearance.hashCode(), variables, false);

	int count = 0;

	for (int i = 0; i < variables.size(); ++i) {
		String name = variables.elementAt(i).getKey();
		PaletteColorCustomizationVariable* palette = dynamic_cast<PaletteColorCustomizationVariable*>(variables.elementAt(i).getValue().get());

		if (palette == nullptr)
			continue;

		String file = palette->getPaletteFileName();

		if (!file.toLowerCase().contains(needle))
			continue;

		int slash = file.lastIndexOf("/");
		String paletteName = slash == -1 ? file : file.subString(slash + 1);
		int dot = paletteName.indexOf(".");

		if (dot != -1)
			paletteName = paletteName.subString(0, dot);

		int value = index;
		PaletteData* data = CustomizationIdManager::instance()->getPaletteData(paletteName);

		if (data != nullptr && data->getCreationIndexes() > 0 && value >= data->getCreationIndexes())
			value = data->getCreationIndexes() - 1;

		object->setCustomizationVariable(name, value, notify);
		factoryLog().info() << "look: " << name << " (" << file << ") set to " << value << " of "
			<< (data != nullptr ? data->getCreationIndexes() : -1);
		++count;
	}

	return count;
}


void BotFactory::ensureLook(ZoneServer* zoneServer, CreatureObject* creature, const BotEntry& entry) {
	bool inWorld = creature->getZone() != nullptr;

	if (entry.hairColor >= 0) {
		Reference<SceneObject*> current = creature->getSlottedObject("hair");

		if (current != nullptr && current->isTangibleObject()) {
			TangibleObject* hair = cast<TangibleObject*>(current.get());
			SharedObjectTemplate* shared = hair->getObjectTemplate();

			if (shared != nullptr) {
				Locker locker(hair, creature);

				setPalette(hair, shared->getAppearanceFilename(), "hair", entry.hairColor, inWorld);
			}
		}
	}

	if (entry.skinTone >= 0) {
		SharedObjectTemplate* shared = creature->getObjectTemplate();

		if (shared != nullptr)
			setPalette(creature, shared->getAppearanceFilename(), "skin", entry.skinTone, inWorld);
	}
}

void BotFactory::ensureHair(ZoneServer* zoneServer, CreatureObject* creature, const BotEntry& entry) {
	if (entry.hair.isEmpty())
		return;

	Reference<SceneObject*> current = creature->getSlottedObject("hair");

	if (current != nullptr && current->getServerObjectCRC() == entry.hair.hashCode())
		return;

	// As PlayerCreationManager::addHair
	HairAssetData* hairData = CustomizationIdManager::instance()->getHairAssetData(entry.hair);

	if (hairData == nullptr || hairData->getServerPlayerTemplate() != creature->getObjectTemplate()->getFullTemplateString()) {
		factoryLog().error() << entry.name << ": hair " << entry.hair << " doesn't fit " << creature->getObjectTemplate()->getFullTemplateString();
		return;
	}

	ManagedReference<SceneObject*> hair = zoneServer->createObject(entry.hair.hashCode(), 1);

	if (hair == nullptr)
		return;

	Locker locker(hair, creature);

	if (!hair->isTangibleObject()) {
		hair->destroyObjectFromDatabase(true);
		return;
	}

	if (current != nullptr) {
		Locker clocker(current, creature);

		current->destroyObjectFromWorld(true);
		current->destroyObjectFromDatabase(true);
	}

	TangibleObject* tanoHair = cast<TangibleObject*>(hair.get());
	tanoHair->setContainerDenyPermission("owner", ContainerPermissions::MOVECONTAINER);
	tanoHair->setContainerDefaultDenyPermission(ContainerPermissions::MOVECONTAINER);

	creature->transferObject(tanoHair, 4, creature->getZone() != nullptr);
}

void BotFactory::ensureOutfit(ZoneServer* zoneServer, CreatureObject* creature, const BotEntry& entry) {
	SortedVector<uint32> wanted;

	for (int i = 0; i < entry.outfit.size(); ++i)
		wanted.put(entry.outfit.get(i).hashCode());

	SceneObject* inventory = creature->getSlottedObject("inventory");
	bool inWorld = creature->getZone() != nullptr;

	for (int i = 0; i < entry.outfit.size(); ++i) {
		const String& templateName = entry.outfit.get(i);
		uint32 crc = templateName.hashCode();

		if (isEquipped(creature, crc))
			continue;

		ManagedReference<SceneObject*> item = zoneServer->createObject(crc, 1);

		if (item == nullptr) {
			factoryLog().error() << entry.name << ": could not create " << templateName;
			continue;
		}

		Locker locker(item, creature);

		// Make room: a worn (or held) item the roster no longer lists goes to the inventory
		if (item->getArrangementDescriptorSize() > 0 && inventory != nullptr) {
			const Vector<String>* slots = item->getArrangementDescriptor(0);

			for (int j = 0; slots != nullptr && j < slots->size(); ++j) {
				Reference<SceneObject*> occupant = creature->getSlottedObject(slots->get(j));

				if (occupant == nullptr || wanted.contains(occupant->getServerObjectCRC()) || !(occupant->isWearableObject() || occupant->isArmorObject() || occupant->isWeaponObject()))
					continue;

				Locker olocker(occupant, creature);

				if (!inventory->transferObject(occupant, -1, inWorld)) {
					occupant->destroyObjectFromWorld(true);
					occupant->destroyObjectFromDatabase(true);
				}
			}
		}

		String error;
		int result = creature->canAddObject(item, 4, error);

		if (result != 0) {
			factoryLog().error() << entry.name << ": can't wear " << templateName << " (" << result << " " << error << ")";

			item->destroyObjectFromDatabase(true);
			continue;
		}

		creature->transferObject(item, 4, inWorld);
	}
}

void BotFactory::ensureCarry(ZoneServer* zoneServer, CreatureObject* creature, const BotEntry& entry) {
	SceneObject* inventory = creature->getSlottedObject("inventory");

	if (inventory == nullptr)
		return;

	bool inWorld = creature->getZone() != nullptr;

	for (int i = 0; i < entry.carry.size(); ++i) {
		const String& templateName = entry.carry.get(i);
		uint32 crc = templateName.hashCode();
		bool has = false;

		for (int j = 0; j < inventory->getContainerObjectsSize() && !has; ++j) {
			SceneObject* item = inventory->getContainerObject(j);

			has = item != nullptr && item->getServerObjectCRC() == crc;
		}

		if (has)
			continue;

		ManagedReference<SceneObject*> item = zoneServer->createObject(crc, 1);

		if (item == nullptr) {
			factoryLog().error() << entry.name << ": could not create " << templateName;
			continue;
		}

		Locker locker(item, creature);

		if (!inventory->transferObject(item, -1, inWorld)) {
			factoryLog().error() << entry.name << ": no room in the inventory for " << templateName;
			item->destroyObjectFromDatabase(true);
		}
	}
}

bool BotFactory::placeAtStation(ZoneServer* zoneServer, CreatureObject* creature, const BotEntry& entry) {
	PlayerObject* ghost = creature->getPlayerObject();
	Zone* zone = zoneServer->getZone(entry.planet);

	if (ghost == nullptr || zone == nullptr) {
		factoryLog().error() << entry.name << ": planet " << entry.planet << " is not enabled";
		return false;
	}

	Vector3 world(entry.x, entry.y, entry.z);

	if (entry.cell != 0) {
		ManagedReference<SceneObject*> object = zoneServer->getObject(entry.cell);

		if (object == nullptr || !object->isCellObject()) {
			factoryLog().error() << entry.name << ": station cell " << entry.cell << " is not a cell";
			return false;
		}

		CellObject* cell = cast<CellObject*>(object.get());
		ManagedReference<SceneObject*> building = cell->getRootParent();

		if (building == nullptr || building->getZone() != zone) {
			factoryLog().error() << entry.name << ": station cell " << entry.cell << " is not in a building on " << entry.planet;
			return false;
		}

		world = WorldCoordinates(Vector3(entry.x, entry.y, entry.z), cell).getWorldPosition();
	} else if (entry.z == 0) {
		world.setZ(CollisionManager::getWorldFloorCollision(entry.x, entry.y, zone, false));
	}

	// The login falls back to the last logout position if the building is gone: make it the station's world position
	creature->initializePosition(world.getX(), world.getZ(), world.getY());
	ghost->setLastLogoutWorldPosition();

	if (entry.cell != 0)
		creature->initializePosition(entry.x, entry.z, entry.y);

	creature->setDirection(Math::deg2rad(entry.heading));

	ghost->setSavedTerrainName(entry.planet);
	ghost->setSavedParentID(entry.cell);
	ghost->getLastValidatedPosition()->update(creature);

	return true;
}
