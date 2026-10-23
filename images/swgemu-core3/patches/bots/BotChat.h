/*
 * BotChat: what bot players hear and say (Phase 3 bot players, see BotManager.h).
 *
 * In: a human's spatial chat within HEAR_RANGE metres of an online bot, and a human's tell to a bot, reach the jobs
 * screenplay as BotJobs:onHeard(pBot, pSpeaker, text, channel). The hooks are in ChatManagerImplementation
 * (patches/0003). Bots never hear bots or themselves.
 * Out: spatial chat, tells, social emotes, facing, and commands, all as the bot.
 */

#ifndef BOTCHAT_H_
#define BOTCHAT_H_

#include "engine/engine.h"

namespace server {
namespace zone {
namespace objects {
namespace scene {
class SceneObject;
}
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

class BotChat {
public:
	static const int HEAR_RANGE = 25;

	// Hook: ChatManagerImplementation::handleSpatialChatInternalMessage, after the message went out (speaker locked)
	static void onSpatialChat(server::zone::objects::creature::CreatureObject* speaker, const UnicodeString& text);

	// Hook: ChatManagerImplementation::handleChatInstantMessageToCharacter, after the tell was delivered
	static void onTell(server::zone::objects::creature::CreatureObject* receiver, server::zone::objects::creature::CreatureObject* sender, const UnicodeString& text);

	// Spatial chat as the bot, with a mood name ("" for its current mood). Runs in the bot's ordered task queue
	static bool say(server::zone::objects::creature::CreatureObject* bot, const String& text, const String& mood);

	// A tell from the bot to an online player by first name. False if they're offline or ignoring the bot
	static bool tell(server::zone::objects::creature::CreatureObject* bot, const String& toFirstName, const String& text);

	// A social emote by name ("wave", "bow"), at a target oid or 0, through the real socialinternal command
	static bool emote(server::zone::objects::creature::CreatureObject* bot, const String& emote, uint64 targetOid);

	// Turn the bot toward the target, broadcast. Runs in the bot's ordered task queue
	static bool face(server::zone::objects::creature::CreatureObject* bot, server::zone::objects::scene::SceneObject* target);

	// Queue a real command by its lowercase name, as the client does. The bot is locked here if the caller hasn't
	static bool enqueue(server::zone::objects::creature::CreatureObject* bot, const String& command, uint64 targetOid, const String& args);

	// The social_types id of an emote name, or 0
	static uint32 getSocialId(const String& name);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTCHAT_H_ */
