/*
 * BotCrews (Phase 9, Part 1). See BotCrews.h.
 */

#include "BotCrews.h"
#include "server/zone/objects/creature/CreatureObject.h"
#include "engine/lua/Lua.h"

#include <sys/stat.h>
#include <sys/types.h>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

using namespace server::zone::managers::bot;

namespace {

Logger& crewsLog() {
	static Logger logger("BotCrews");

	return logger;
}

// A Lua string literal
String quoted(const String& text) {
	StringBuffer out;

	out << "\"";

	for (int i = 0; i < text.length(); ++i) {
		char c = text.charAt(i);

		if (c == '"' || c == '\\')
			out << "\\" << c;
		else if (c == '\n')
			out << "\\n";
		else if (c == '\r')
			out << "\\r";
		else
			out << c;
	}

	out << "\"";

	return out.toString();
}

String list(const Vector<String>& items, const char* indent) {
	if (items.isEmpty())
		return "{}";

	StringBuffer out;

	out << "{\n";

	for (int i = 0; i < items.size(); ++i)
		out << indent << "\t" << quoted(items.get(i)) << ",\n";

	out << indent << "}";

	return out.toString();
}

String number(float value) {
	char buffer[40];

	snprintf(buffer, sizeof(buffer), "%.3f", value);

	return buffer;
}

}

String BotCrews::getDataDir() {
	const char* env = getenv("BOT_DATA_DIR");

	if (env != nullptr && env[0] != 0)
		return env;

	return "/data/bots";
}

String BotCrews::getPath() {
	const char* env = getenv("BOT_CREWS_FILE");

	if (env != nullptr && env[0] != 0)
		return env;

	return getDataDir() + "/crews.lua";
}

String BotCrews::accountFor(const String& firstName) {
	StringBuffer out;

	out << "bot_";

	int letters = 0;

	for (int i = 0; i < firstName.length(); ++i) {
		char c = firstName.charAt(i);

		if (isalnum((unsigned char)c)) {
			out << (char)tolower((unsigned char)c);
			++letters;
		}
	}

	return letters == 0 ? String("") : out.toString();
}

String BotCrews::serialize(const BotRosterList& entries, const PendingDeletionList& pending) {
	StringBuffer out;

	out << "-- Own crews (Phase 9): the bots hired at a recruiter, one crew per human character. Written by the server after each\n"
		<< "-- hire and let-go (BotCrews.cpp); data only, in the shape of custom_scripts/bots/roster.lua's entries plus owner (the\n"
		<< "-- hiring character's object id) and hiredAt. Edit it only while the server is stopped.\n"
		<< "BotOwnCrews = {\n\tbots = {\n";

	for (int i = 0; i < entries.size(); ++i) {
		const BotEntry* e = entries.get(i);

		out << "\t\t{\n"
			<< "\t\t\tname = " << quoted(e->name) << ",\n"
			<< "\t\t\taccount = " << quoted(e->account) << ",\n"
			<< "\t\t\tspecies = " << quoted(e->species) << ",\n"
			<< "\t\t\tsex = " << quoted(e->sex) << ",\n"
			<< "\t\t\thair = " << quoted(e->hair) << ",\n";

		if (e->hairColor >= 0)
			out << "\t\t\thairColor = " << e->hairColor << ",\n";

		if (e->skinTone >= 0)
			out << "\t\t\tskinTone = " << e->skinTone << ",\n";

		out << "\t\t\tjob = " << quoted(e->job) << ",\n"
			<< "\t\t\tcity = " << quoted(e->city) << ",\n"
			<< "\t\t\tonline = " << quoted(e->online) << ",\n"
			<< "\t\t\towner = " << e->owner << ",\n"
			<< "\t\t\thiredAt = " << e->hiredAt << ",\n";

		if (!e->weapon.isEmpty())
			out << "\t\t\tweapon = " << quoted(e->weapon) << ",\n";

		if (!e->campKit.isEmpty())
			out << "\t\t\tcampKit = " << quoted(e->campKit) << ",\n";

		if (!e->doctrine.isEmpty())
			out << "\t\t\tdoctrine = " << quoted(e->doctrine) << ",\n";

		out << "\t\t\tskills = " << list(e->skills, "\t\t\t") << ",\n"
			<< "\t\t\toutfit = " << list(e->outfit, "\t\t\t") << ",\n"
			<< "\t\t\tcarry = " << list(e->carry, "\t\t\t") << ",\n"
			<< "\t\t\tstation = {planet = " << quoted(e->planet) << ", x = " << number(e->x) << ", z = " << number(e->z)
				<< ", y = " << number(e->y) << ", cell = " << e->cell << ", heading = " << number(e->heading) << "},\n"
			<< "\t\t},\n";
	}

	out << "\t},\n";

	// Characters of bots let go, until a boot has checked them
	out << "\tdeleting = {\n";

	for (int i = 0; i < pending.size(); ++i) {
		const PendingDeletion* d = pending.get(i);

		out << "\t\t{oid = " << d->oid << ", first = " << quoted(d->firstName) << ", account = " << quoted(d->account)
			<< ", done = " << (d->done ? "true" : "false") << "},\n";
	}

	out << "\t},\n}\n";

	return out.toString();
}

bool BotCrews::save(const BotRosterList& entries, const PendingDeletionList& pending) {
	static Mutex saveMutex;
	Locker locker(&saveMutex);

	String path = getPath();
	int slash = path.lastIndexOf("/");

	if (slash > 0) {
		// The folder (one level; the volume itself exists)
		String dir = path.subString(0, slash);

		mkdir(dir.toCharArray(), 0755);
	}

	String temp = path + ".tmp";
	String text = serialize(entries, pending);

	FILE* file = fopen(temp.toCharArray(), "wb");

	if (file == nullptr) {
		crewsLog().error() << "can't write " << temp;

		return false;
	}

	bool ok = fwrite(text.toCharArray(), 1, text.length(), file) == (size_t)text.length();

	ok = fflush(file) == 0 && ok;
	ok = fsync(fileno(file)) == 0 && ok;
	ok = fclose(file) == 0 && ok;

	if (!ok || rename(temp.toCharArray(), path.toCharArray()) != 0) {
		crewsLog().error() << "can't replace " << path << " with " << temp;
		remove(temp.toCharArray());

		return false;
	}

	return true;
}

void BotCrews::loadPending(const String& path, PendingDeletionList& out) {
	Lua* lua = new Lua();
	lua->init();

	if (lua->runFile(path)) {
		LuaObject crews = lua->getGlobalObject("BotOwnCrews");

		if (crews.isValidTable()) {
			LuaObject list = crews.getObjectField("deleting");

			if (list.isValidTable()) {
				for (int i = 1; i <= list.getTableSize(); ++i) {
					LuaObject item = list.getObjectAt(i);

					if (item.isValidTable()) {
						Reference<PendingDeletion*> d = new PendingDeletion();

						d->oid = item.getLongField("oid");
						d->firstName = item.getStringField("first");
						d->account = item.getStringField("account");
						d->done = item.getBooleanField("done");

						if (d->oid != 0)
							out.add(d);
					}

					item.pop();
				}
			}

			list.pop();
		}

		crews.pop();
	}

	delete lua;
}

bool BotCrews::copyAside(const String& path, String& copy) {
	copy = path + ".bad-" + String::valueOf((uint64)Time().getTime());

	FILE* in = fopen(path.toCharArray(), "rb");

	if (in == nullptr)
		return false;

	FILE* out = fopen(copy.toCharArray(), "wb");

	if (out == nullptr) {
		fclose(in);
		return false;
	}

	char buffer[4096];
	size_t got;
	bool ok = true;

	while ((got = fread(buffer, 1, sizeof(buffer), in)) > 0)
		ok = fwrite(buffer, 1, got, out) == got && ok;

	fclose(in);
	ok = fclose(out) == 0 && ok;

	return ok;
}

String BotCrews::getDoctrineDir() {
	const char* env = getenv("TALK_DOCTRINE_DIR");

	if (env != nullptr && env[0] != 0)
		return env;

	return "/data/doctrine";
}

static String readFile(const String& path) {
	FILE* file = fopen(path.toCharArray(), "rb");

	if (file == nullptr)
		return "";

	StringBuffer out;
	char buffer[1024];
	size_t got;

	while ((got = fread(buffer, 1, sizeof(buffer) - 1, file)) > 0) {
		buffer[got] = 0;
		out << buffer;
	}

	fclose(file);

	return out.toString();
}

void BotCrews::writeDoctrine(const BotEntry& entry) {
	// The talk bridge reads /data/doctrine/base/<first>.txt (it wins over the image's seeds) and makes the bot's tactics from
	// it; "role:" says what role a name nobody listed plays. A file that is there stays (the creator may have edited it)
	if (entry.doctrine.isEmpty())
		return;

	const char* seedEnv = getenv("TALK_DOCTRINE_SEED");
	String seedDir = seedEnv != nullptr && seedEnv[0] != 0 ? String(seedEnv) : String("/opt/swgemu/talk/doctrine");
	String seed = readFile(seedDir + "/" + entry.doctrine + ".txt");

	if (seed.isEmpty()) {
		crewsLog().warning() << "no seed doctrine " << entry.doctrine << " in " << seedDir << " for " << entry.name;
		return;
	}

	String base = getDoctrineDir() + "/base";

	mkdir(getDoctrineDir().toCharArray(), 0755);
	mkdir(base.toCharArray(), 0755);

	String path = base + "/" + entry.firstName.toLowerCase() + ".txt";

	if (access(path.toCharArray(), F_OK) == 0)
		return;

	// (a seed that names its own role keeps it)
	String text = seed.beginsWith("role:") ? seed : "role: " + entry.job + "\n" + seed;

	FILE* file = fopen(path.toCharArray(), "wb");

	if (file == nullptr) {
		crewsLog().warning() << "can't write " << path;
		return;
	}

	fwrite(text.toCharArray(), 1, text.length(), file);
	fclose(file);
}

void BotCrews::removeDoctrine(const String& firstName) {
	String first = firstName.toLowerCase();
	String dir = getDoctrineDir();

	remove((dir + "/base/" + first + ".txt").toCharArray());
	remove((dir + "/taught/" + first + ".txt").toCharArray());
	remove((dir + "/tables/" + first + ".json").toCharArray());
}

int BotCrews::boxCount(CreatureObject* creature) {
	if (creature == nullptr)
		return 0;

	Vector<String> skills;

	creature->getSkillList()->getStringList(skills);

	int count = 0;

	for (int i = 0; i < skills.size(); ++i) {
		const String& name = skills.get(i);

		if (name.beginsWith("species_") || name.beginsWith("social_language_") || name.endsWith("_novice"))
			continue;

		++count;
	}

	return count;
}
