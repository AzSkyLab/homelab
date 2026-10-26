/*
 * BotCrews: the own crews' file (Phase 9, Part 1). A crew belongs to one human character: up to seven bots, one per
 * role, hired at a recruiter in a cantina and made at runtime (BotManager::hire). The roster is persistent: the entries
 * live in /data/bots/crews.lua (BOT_CREWS_FILE overrides the path; BOT_DATA_DIR overrides the folder), data only, in the
 * shape of roster.lua's entries plus owner (the character's object id) and hiredAt. BotManager reads it after the static
 * roster at boot, and BotCrews::save writes it again after each hire and let-go: to a temporary file in the same folder,
 * then renamed over the old one, so a crash leaves one or the other.
 */

#ifndef BOTCREWS_H_
#define BOTCREWS_H_

#include "BotEntry.h"

namespace server {
namespace zone {

namespace objects {
namespace creature {
class CreatureObject;
}
}

namespace managers {
namespace bot {

class BotCrews {
public:
	// Where the file lives (not necessarily there yet)
	static String getPath();

	// The folder of our runtime files (/data/bots by default, made when first needed), for the doctrine seeds' parent too
	static String getDataDir();

	// The file's text for these entries and the deletions still recorded
	static String serialize(const BotRosterList& entries, const PendingDeletionList& pending);

	// Writes them atomically (a temporary file, flushed to disk, renamed over the old). Returns false, logged, if the folder or
	// file can't be written. One writer at a time
	static bool save(const BotRosterList& entries, const PendingDeletionList& pending);

	// The pending deletions of the file (BotOwnCrews.deleting)
	static void loadPending(const String& path, PendingDeletionList& out);

	// Keeps a copy of a file that did not load, beside it (<path>.bad-<time>); false if the copy failed
	static bool copyAside(const String& path, String& copy);

	// The skill boxes a character counts as its level for a crew: every skill it has except the novice boxes and the
	// species and language ones
	static int boxCount(server::zone::objects::creature::CreatureObject* creature);

	// The doctrine folder the talk bridge reads (TALK_DOCTRINE_DIR, else /data/doctrine)
	static String getDoctrineDir();

	// A new bot's doctrine file, copied from the seed of its role (entry.doctrine names the Mos Eisley crew bot's file in the
	// image's talk/doctrine folder) with a "role:" line, unless one is there; and the files of a bot that goes
	static void writeDoctrine(const BotEntry& entry);
	static void removeDoctrine(const String& firstName);

	// "bot_" and the first name in lower case, letters and digits only; "" if nothing is left
	static String accountFor(const String& firstName);
};

} // namespace bot
} // namespace managers
} // namespace zone
} // namespace server

using namespace server::zone::managers::bot;

#endif /* BOTCREWS_H_ */
