/*
 * BotChat (Phase 3 bot players). See BotChat.h.
 */

#include "BotChat.h"
#include "BotManager.h"
#include "BotLua.h"
#include "server/zone/ZoneServer.h"
#include "server/zone/Zone.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "server/zone/objects/player/PlayerObject.h"
#include "server/zone/managers/objectcontroller/ObjectController.h"
#include "server/zone/packets/chat/ChatInstantMessageToClient.h"
#include "server/chat/ChatManager.h"
#include "server/ServerCore.h"
#include "conf/ConfigManager.h"

namespace {

Mutex socialMutex;
VectorMap<String, uint32> socialIds;
bool socialLoaded = false;

// Speech from a human player, not a bot and not an NPC. Core3.BotManager.DevHearBots (config, off by default) lets
// bots hear bots' spatial chat, so the hook can be tested on a server with no game client
bool isHuman(CreatureObject* creature) {
	static const bool devHearBots = ConfigManager::instance()->getBool("Core3.BotManager.DevHearBots", false);

	return creature != nullptr && creature->isPlayerCreature() && (devHearBots || !BotManager::instance()->isBot(creature));
}

void hear(CreatureObject* bot, CreatureObject* speaker, const String& text, const char* channel) {
	Reference<CreatureObject*> botRef = bot;
	Reference<CreatureObject*> speakerRef = speaker;
	String message = text;
	String channelName = channel;

	// Ordered per bot, so what it hears arrives in order, after its login and before its logout
	bot->executeOrderedTask([botRef, speakerRef, message, channelName]() {
		Locker locker(botRef);

		if (!BotManager::instance()->isOnlineBot(botRef))
			return;

		BotLua::callJobsHeard(botRef, speakerRef, message, channelName);
	}, "BotHeard");
}

}

void BotChat::onSpatialChat(CreatureObject* speaker, const UnicodeString& text) {
	if (!isHuman(speaker) || text.length() == 0)
		return;

	Zone* zone = speaker->getZone();

	if (zone == nullptr)
		return;

	Vector<Reference<CreatureObject*>> bots;
	BotManager::instance()->getOnlineBots(bots);

	if (bots.isEmpty())
		return;

	Vector3 position = speaker->getWorldPosition();
	String message = text.toString();

	for (int i = 0; i < bots.size(); ++i) {
		CreatureObject* bot = bots.get(i);

		if (bot == speaker || bot->getZone() != zone)
			continue;

		if (bot->getWorldPosition().squaredDistanceTo(position) > HEAR_RANGE * HEAR_RANGE)
			continue;

		hear(bot, speaker, message, "spatial");
	}
}

void BotChat::onTell(CreatureObject* receiver, CreatureObject* sender, const UnicodeString& text) {
	if (receiver == nullptr || receiver == sender || sender == nullptr || !sender->isPlayerCreature() ||
			BotManager::instance()->isBot(sender) || text.length() == 0)
		return;

	if (!BotManager::instance()->isOnlineBot(receiver))
		return;

	hear(receiver, sender, text.toString(), "tell");
}

bool BotChat::say(CreatureObject* bot, const String& text, const String& mood) {
	if (!BotManager::instance()->isOnlineBot(bot) || text.isEmpty())
		return false;

	Reference<CreatureObject*> ref = bot;
	String message = text;
	String moodName = mood;

	bot->executeOrderedTask([ref, message, moodName]() {
		Locker locker(ref);

		ZoneServer* zoneServer = ref->getZoneServer();
		ChatManager* chatManager = zoneServer != nullptr ? zoneServer->getChatManager() : nullptr;

		if (chatManager == nullptr || ref->getZone() == nullptr)
			return;

		uint32 moodID = moodName.isEmpty() ? 0 : chatManager->getMoodID(moodName.toLowerCase());

		if (moodID == 0)
			moodID = ref->getMoodID();

		// Spatial chat type 0 is the default ("say"), language 1 is Basic
		chatManager->broadcastChatMessage(ref, UnicodeString(message), 0, 0, moodID, 0, 1);
	}, "BotSay");

	return true;
}

bool BotChat::tell(CreatureObject* bot, const String& toFirstName, const String& text) {
	if (!BotManager::instance()->isOnlineBot(bot) || toFirstName.isEmpty() || text.isEmpty())
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();
	ChatManager* chatManager = zoneServer != nullptr ? zoneServer->getChatManager() : nullptr;

	if (chatManager == nullptr)
		return false;

	String firstName = toFirstName;
	int space = firstName.indexOf(" ");

	if (space != -1)
		firstName = firstName.subString(0, space);

	Reference<CreatureObject*> receiver = chatManager->getPlayer(firstName);

	if (receiver == nullptr || receiver == bot || !receiver->isOnline())
		return false;

	PlayerObject* receiverGhost = receiver->getPlayerObject();

	if (receiverGhost == nullptr || receiverGhost->isIgnoring(bot->getFirstName().toLowerCase()))
		return false;

	// What ChatManager sends for a player's tell. A bot receiving it has no client, and bots don't hear bots
	BaseMessage* message = new ChatInstantMessageToClient("SWG", zoneServer->getGalaxyName(), bot->getFirstName(), UnicodeString(text));
	receiver->sendMessage(message);

	return true;
}

uint32 BotChat::getSocialId(const String& name) {
	Locker locker(&socialMutex);

	if (!socialLoaded) {
		ZoneServer* zoneServer = ServerCore::getZoneServer();
		ChatManager* chatManager = zoneServer != nullptr ? zoneServer->getChatManager() : nullptr;

		if (chatManager == nullptr)
			return 0;

		// ChatManager keeps id -> name (social_types.iff, ids from 1); a bot needs name -> id
		int misses = 0;

		for (uint32 id = 1; id < 4000 && misses < 20; ++id) {
			String social = chatManager->getSocialType(id);

			if (social.isEmpty()) {
				++misses;
				continue;
			}

			misses = 0;
			socialIds.put(social.toLowerCase(), id);
		}

		socialLoaded = true;
	}

	int pos = socialIds.find(name.toLowerCase());

	return pos == -1 ? 0 : socialIds.elementAt(pos).getValue();
}

bool BotChat::emote(CreatureObject* bot, const String& emote, uint64 targetOid) {
	uint32 socialId = getSocialId(emote);

	if (socialId == 0)
		return false;

	// socialinternal arguments: target, emote id, show the animation, show the text
	StringBuffer args;
	args << targetOid << " " << socialId << " 1 1";

	return enqueue(bot, "socialinternal", targetOid, args.toString());
}

bool BotChat::face(CreatureObject* bot, SceneObject* target) {
	if (!BotManager::instance()->isOnlineBot(bot) || target == nullptr || target == bot)
		return false;

	Reference<CreatureObject*> ref = bot;
	Reference<SceneObject*> targetRef = target;

	bot->executeOrderedTask([ref, targetRef]() {
		Locker locker(ref);

		if (ref->getZone() == nullptr)
			return;

		// World positions, so it works across cells; a heading in a cell is relative to the building
		Vector3 from = ref->getWorldPosition();
		Vector3 to = targetRef->getWorldPosition();
		float dx = to.getX() - from.getX();
		float dy = to.getY() - from.getY();

		if (dx * dx + dy * dy < 0.01f)
			return;

		float heading = M_PI / 2 - atan2(dy, dx);

		ManagedReference<SceneObject*> parent = ref->getParent().get();

		if (parent != nullptr) {
			ManagedReference<SceneObject*> root = ref->getRootParent();

			if (root != nullptr && root != ref)
				heading -= root->getDirection()->getRadians();
		}

		while (heading < 0)
			heading += 2 * M_PI;

		while (heading >= 2 * M_PI)
			heading -= 2 * M_PI;

		if (fabs(heading - ref->getDirection()->getRadians()) < 0.05f)
			return;

		ref->updateDirection(heading);
	}, "BotFace");

	return true;
}

bool BotChat::enqueue(CreatureObject* bot, const String& command, uint64 targetOid, const String& args) {
	if (!BotManager::instance()->isOnlineBot(bot) || command.isEmpty())
		return false;

	ZoneServer* zoneServer = bot->getZoneServer();
	ObjectController* objectController = zoneServer != nullptr ? zoneServer->getObjectController() : nullptr;

	if (objectController == nullptr)
		return false;

	uint32 crc = command.toLowerCase().hashCode();

	if (objectController->getQueueCommand(crc) == nullptr)
		return false;

	// A new action counter per command, as the client sends: the queue runs them in that order
	if (bot->isLockedByCurrentThread()) {
		bot->enqueueCommand(crc, bot->incrementLastActionCounter(), targetOid, UnicodeString(args));
	} else {
		// The caller may hold another object's lock; take the bot's in its own task
		Reference<CreatureObject*> ref = bot;
		UnicodeString arguments(args);

		bot->executeOrderedTask([ref, crc, targetOid, arguments]() {
			Locker locker(ref);

			ref->enqueueCommand(crc, ref->incrementLastActionCounter(), targetOid, arguments);
		}, "BotEnqueue");
	}

	return true;
}
