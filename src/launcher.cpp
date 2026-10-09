/*
** launcher.cpp
**
** This file is part of mkxp.
**
** mkxp is free software: you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation, either version 2 of the License, or
** (at your option) any later version.
**
** mkxp is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with mkxp.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "launcher.h"

#include "config.h"
#include "gl-fun.h"
#include "debugwriter.h"

#include <SDL.h>
#include <SDL_image.h>
#include <SDL_ttf.h>

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include <stdlib.h>

#include <algorithm>
#include <fstream>
#include <iterator>
#include <map>
#include <vector>

extern unsigned char assets_liberation_ttf[];
extern unsigned int assets_liberation_ttf_len;

namespace
{

struct Game
{
	std::string path;
	std::string title;
	/* RGSS version, or one of the values below */
	int version;
};

/* RPG Maker MV and MZ games, run by Outsider (see main.cpp) */
const int versionMV = 4;
const int versionMZ = 5;

struct Color
{
	Uint8 r, g, b;
};

const Color colBackground = {  18,  20,  26 };
const Color colPanel      = {  32,  35,  45 };
const Color colAccent     = {  52,  98, 204 };
const Color colText       = { 236, 237, 242 };
const Color colDim        = { 150, 156, 172 };

const Uint32 repeatDelay = 400;
const Uint32 repeatRate = 70;
const Sint16 axisDeadzone = 16000;

/* Button numbers of the DualSense in the PS5 SDL port, which follow
 * SDL's game controller layout (as do most pads' first buttons) */
const Uint8 joyConfirm = 0;  /* Cross */
const Uint8 joyRescan = 3;   /* Triangle */
const Uint8 joyPageUp = 9;   /* L1 */
const Uint8 joyPageDown = 10;/* R1 */

std::string joinPath(const std::string &dir, const std::string &name)
{
	if (!dir.empty() && dir[dir.size()-1] == '/')
		return dir + name;

	return dir + "/" + name;
}

std::string baseName(const std::string &path)
{
	size_t pos = path.find_last_of('/');

	return pos == std::string::npos ? path : path.substr(pos + 1);
}

std::string absolutePath(const std::string &path)
{
	char cwd[PATH_MAX];

	if (path.empty() || path[0] == '/' || !getcwd(cwd, sizeof(cwd)))
		return path;

	return joinPath(cwd, path);
}

bool isDir(const std::string &path)
{
	struct stat st;

	return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool isFile(const std::string &path)
{
	struct stat st;

	return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

std::vector<std::string> listDir(const std::string &dir, bool dirs)
{
	std::vector<std::string> result;
	DIR *d = opendir(dir.c_str());

	if (!d)
		return result;

	while (struct dirent *e = readdir(d))
	{
		if (e->d_name[0] == '.')
			continue;

		std::string path = joinPath(dir, e->d_name);

		if (dirs ? isDir(path) : isFile(path))
			result.push_back(e->d_name);
	}

	closedir(d);
	std::sort(result.begin(), result.end());

	return result;
}

/* Creates 'dir' and any missing parents */
void makeDirs(const std::string &dir)
{
	for (size_t pos = 1; pos != std::string::npos; ++pos)
	{
		pos = dir.find('/', pos);
		mkdir(dir.substr(0, pos).c_str(), 0755);

		if (pos == std::string::npos)
			break;
	}
}

bool isWritable(const std::string &dir)
{
	/* access() doesn't know about read-only mounts everywhere */
	std::string probe = joinPath(dir, ".mkxp-write-test");
	int fd = open(probe.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd < 0)
		return false;

	close(fd);
	unlink(probe.c_str());

	return true;
}

std::string lastGameFile(const Config &conf)
{
#ifdef MKXP_PS5_NATIVE
	(void) conf;
	return "/download0/launcher-last-game";
#else
	return conf.commonDataPath + "launcher-last-game";
#endif
}

bool gameLess(const Game &a, const Game &b)
{
	int cmp = strcasecmp(a.title.c_str(), b.title.c_str());

	return cmp != 0 ? cmp < 0 : a.path < b.path;
}

const char *makerName(int version)
{
	switch (version)
	{
	case 1: return "RPG Maker XP";
	case 2: return "RPG Maker VX";
	case 3: return "RPG Maker VX Ace";
	case versionMV: return "RPG Maker MV";
	case versionMZ: return "RPG Maker MZ";
	}

	return "RPG Maker";
}

/* The folder of the RPG Maker MV/MZ game in 'dir' (the one with js/main.js:
 * 'dir' itself, or www/ in games packaged with NW.js), or an empty string */
std::string scriptGameRoot(const std::string &dir, int *version)
{
	const char *roots[] = { "", "www" };

	for (size_t i = 0; i < 2; ++i)
	{
		std::string root = roots[i][0] ? joinPath(dir, roots[i]) : dir;

		if (!isFile(joinPath(root, "js/main.js")))
			continue;

		if (isFile(joinPath(root, "js/rmmz_core.js")))
		{
			*version = versionMZ;
			return root;
		}

		if (isFile(joinPath(root, "js/rpg_core.js")))
		{
			*version = versionMV;
			return root;
		}
	}

	return std::string();
}

void appendUtf8(std::string &out, unsigned long c)
{
	if (c < 0x80)
	{
		out += (char) c;
	}
	else if (c < 0x800)
	{
		out += (char) (0xC0 | (c >> 6));
		out += (char) (0x80 | (c & 0x3F));
	}
	else if (c < 0x10000)
	{
		out += (char) (0xE0 | (c >> 12));
		out += (char) (0x80 | ((c >> 6) & 0x3F));
		out += (char) (0x80 | (c & 0x3F));
	}
	else
	{
		out += (char) (0xF0 | (c >> 18));
		out += (char) (0x80 | ((c >> 12) & 0x3F));
		out += (char) (0x80 | ((c >> 6) & 0x3F));
		out += (char) (0x80 | (c & 0x3F));
	}
}

/* The string value of the first "key" in a JSON file, or an empty string */
std::string jsonString(const std::string &file, const std::string &key)
{
	std::ifstream in(file.c_str(), std::ios::binary);
	std::string json((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());

	size_t pos = json.find("\"" + key + "\"");
	if (pos == std::string::npos)
		return std::string();

	pos = json.find_first_not_of(" \t\r\n", pos + key.size() + 2);
	if (pos == std::string::npos || json[pos] != ':')
		return std::string();

	pos = json.find_first_not_of(" \t\r\n", pos + 1);
	if (pos == std::string::npos || json[pos] != '"')
		return std::string();

	std::string out;

	for (++pos; pos < json.size() && json[pos] != '"'; ++pos)
	{
		if (json[pos] != '\\')
		{
			out += json[pos];
			continue;
		}

		if (++pos >= json.size())
			break;

		switch (json[pos])
		{
		case 'n': out += '\n'; break;
		case 't': out += '\t'; break;
		case 'r': case 'b': case 'f': break;
		case 'u':
		{
			unsigned long c = strtoul(json.substr(pos + 1, 4).c_str(), 0, 16);
			pos += 4;

			/* UTF-16 surrogate pair */
			if (c >= 0xD800 && c < 0xDC00 && json.compare(pos + 1, 2, "\\u") == 0)
			{
				unsigned long low = strtoul(json.substr(pos + 3, 4).c_str(), 0, 16);
				c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
				pos += 6;
			}

			appendUtf8(out, c);
			break;
		}
		default: out += json[pos];
		}
	}

	return out;
}

class Picker
{
public:
	Picker(SDL_Window *win, const Config &conf)
	    : win(win), conf(conf),
	      selected(0), scroll(0), heldDir(0), nextRepeat(0),
	      kbDir(0), hatDir(0), axisDir(0), pendingMove(0),
	      canvas(0), joystick(0),
	      program(0), vertShader(0), fragShader(0),
	      vao(0), vbo(0), ibo(0), tex(0)
	{
		iniName = conf.execName + ".ini";

		for (size_t i = 0; i < conf.gameLibraries.size(); ++i)
			libraries.push_back(absolutePath(conf.gameLibraries[i]));

		SDL_GL_GetDrawableSize(win, &width, &height);
		scale = height / 1080.0f;

		fontLarge = openFont(60);
		fontMedium = openFont(34);
		fontSmall = openFont(24);

		canvas = SDL_CreateRGBSurfaceWithFormat(0, width, height, 32,
		                                        SDL_PIXELFORMAT_ABGR8888);

		if (SDL_NumJoysticks() > 0)
			joystick = SDL_JoystickOpen(0);
	}

	~Picker()
	{
		teardownGL();

		for (std::map<std::string, SDL_Surface*>::iterator it = previews.begin();
		     it != previews.end(); ++it)
			if (it->second)
				SDL_FreeSurface(it->second);

		if (canvas)
			SDL_FreeSurface(canvas);

		TTF_CloseFont(fontLarge);
		TTF_CloseFont(fontMedium);
		TTF_CloseFont(fontSmall);

		if (joystick)
			SDL_JoystickClose(joystick);
	}

	std::string run()
	{
		scan();
		selectLastGame();

		if (!canvas || !fontLarge || !fontMedium || !fontSmall || !setupGL())
		{
			Debug() << "Launcher: unable to set up the game list:" << SDL_GetError();

			/* Better than a blank screen */
			return games.empty() ? std::string() : games[selected].path;
		}

		bool dirty = true;

		while (true)
		{
			SDL_Event e;
			int action = 0;

			while (SDL_PollEvent(&e))
			{
				int a = handleEvent(e);

				if (a)
					action = a;
			}

			if (action == Quit)
				return std::string();

			if (action == Rescan)
			{
				std::string current = games.empty() ? std::string() : games[selected].path;
				scan();
				selectPath(current);
				dirty = true;
			}

			if (action == Confirm && !games.empty())
			{
				const Game &game = games[selected];
				std::ofstream(lastGameFile(conf).c_str()) << game.path << "\n";

				/* Shown while the game loads */
				renderLoading(game);
				present();

				return game.path;
			}

			if (action == PageUp || action == PageDown)
				pendingMove += (action == PageUp ? -1 : 1) * std::max(visibleRows() - 1, 1);

			updateRepeat();

			if (pendingMove)
			{
				move(pendingMove);
				pendingMove = 0;
				dirty = true;
			}

			if (dirty)
			{
				render();
				dirty = false;
			}

			present();
			SDL_Delay(10);
		}
	}

private:
	enum Action
	{
		NoAction = 0,
		Confirm,
		Rescan,
		PageUp,
		PageDown,
		Quit
	};

	SDL_Window *win;
	const Config &conf;

	std::string iniName;
	std::vector<std::string> libraries;
	std::vector<Game> games;
	int selected;
	int scroll;

	/* Held up/down direction (-1, 0, 1), its sources, and the
	 * selection change still to apply */
	int heldDir;
	Uint32 nextRepeat;
	int kbDir, hatDir, axisDir;
	int pendingMove;

	int width, height;
	float scale;
	TTF_Font *fontLarge, *fontMedium, *fontSmall;
	SDL_Surface *canvas;
	std::map<std::string, SDL_Surface*> previews;

	SDL_Joystick *joystick;

	GLuint program, vertShader, fragShader;
	GLuint vao, vbo, ibo, tex;

	int px(float v) const
	{
		return (int) (v * scale + 0.5f);
	}

	TTF_Font *openFont(int size)
	{
		SDL_RWops *ops = SDL_RWFromConstMem(assets_liberation_ttf,
		                                    assets_liberation_ttf_len);

		return TTF_OpenFontRW(ops, 1, std::max(px(size), 8));
	}

	/* Library scanning */

	bool hasGame(const std::string &dir) const
	{
		return isFile(joinPath(dir, iniName));
	}

	/* Adds the game in 'dir', if there is one */
	bool tryAddGame(const std::string &dir)
	{
		if (hasGame(dir))
		{
			addGame(dir);
			return true;
		}

#ifdef MKXP_WITH_OUTSIDER
		int version = 0;
		std::string root = scriptGameRoot(dir, &version);

		if (!root.empty())
		{
			Game game;
			game.path = root;
			game.version = version;
			game.title = jsonString(joinPath(root, "data/System.json"), "gameTitle");

			if (game.title.empty())
				game.title = baseName(dir);

			games.push_back(game);
			return true;
		}
#endif

		return false;
	}

	void addGame(const std::string &dir)
	{
		Game game;
		game.path = dir;
		game.title = baseName(dir);
		game.version = 0;

		/* Reuse mkxp's own Game.ini parsing and RGSS version detection */
		char cwd[PATH_MAX];
		if (getcwd(cwd, sizeof(cwd)) && chdir(dir.c_str()) == 0)
		{
			Config gameConf;
			gameConf.rgssVersion = 0;
			gameConf.defScreenW = gameConf.defScreenH = 0;
			gameConf.execName = conf.execName;
			gameConf.titleLanguage = conf.titleLanguage;
			gameConf.gameFolder = dir;
			gameConf.readGameINI();

			game.title = gameConf.game.title;
			game.version = gameConf.rgssVersion;

			if (chdir(cwd) != 0)
				Debug() << "Launcher: unable to switch back into" << cwd;
		}

		games.push_back(game);
	}

	void scan()
	{
		games.clear();

		for (size_t i = 0; i < libraries.size(); ++i)
		{
			std::vector<std::string> entries = listDir(libraries[i], true);

			for (size_t j = 0; j < entries.size(); ++j)
			{
				std::string dir = joinPath(libraries[i], entries[j]);

				if (tryAddGame(dir))
					continue;

				/* Archives often extract to "Name/Name/Game.ini" */
				std::vector<std::string> sub = listDir(dir, true);
				if (sub.size() == 1)
					tryAddGame(joinPath(dir, sub[0]));
			}
		}

		std::sort(games.begin(), games.end(), gameLess);
		Debug() << "Launcher: found" << games.size() << "games";

		selected = std::min(selected, std::max((int) games.size() - 1, 0));
	}

	void selectPath(const std::string &path)
	{
		for (size_t i = 0; i < games.size(); ++i)
			if (games[i].path == path)
				selected = i;
	}

	void selectLastGame()
	{
		std::ifstream file(lastGameFile(conf).c_str());
		std::string path;

		if (std::getline(file, path))
			selectPath(path);
	}

	/* Input */

	int handleEvent(const SDL_Event &e)
	{
		switch (e.type)
		{
		case SDL_QUIT:
			return Quit;

		case SDL_KEYDOWN:
			if (e.key.repeat)
				break;

			switch (e.key.keysym.sym)
			{
			case SDLK_RETURN:
			case SDLK_KP_ENTER:
			case SDLK_SPACE:
				return Confirm;
			case SDLK_F5:
				return Rescan;
			case SDLK_PAGEUP:
				return PageUp;
			case SDLK_PAGEDOWN:
				return PageDown;
#ifndef __PROSPERO__
			case SDLK_ESCAPE:
				return Quit;
#endif
			case SDLK_UP:
				setDir(kbDir, -1);
				break;
			case SDLK_DOWN:
				setDir(kbDir, 1);
				break;
			}
			break;

		case SDL_KEYUP:
			if ((e.key.keysym.sym == SDLK_UP && kbDir < 0) ||
			    (e.key.keysym.sym == SDLK_DOWN && kbDir > 0))
				setDir(kbDir, 0);
			break;

		case SDL_JOYBUTTONDOWN:
			switch (e.jbutton.button)
			{
			case joyConfirm:
				return Confirm;
			case joyRescan:
				return Rescan;
			case joyPageUp:
				return PageUp;
			case joyPageDown:
				return PageDown;
			}
			break;

		case SDL_JOYHATMOTION:
			setDir(hatDir, (e.jhat.value & SDL_HAT_UP) ? -1 :
			               (e.jhat.value & SDL_HAT_DOWN) ? 1 : 0);
			break;

		case SDL_JOYAXISMOTION:
			if (e.jaxis.axis == 1)
				setDir(axisDir, e.jaxis.value < -axisDeadzone ? -1 :
				                e.jaxis.value > axisDeadzone ? 1 : 0);
			break;

		case SDL_JOYDEVICEADDED:
			if (!joystick)
				joystick = SDL_JoystickOpen(e.jdevice.which);
			break;
		}

		return NoAction;
	}

	/* Updates one source of the held direction; moving happens on
	 * the press itself, so that quick taps aren't lost */
	void setDir(int &source, int dir)
	{
		source = dir;
		int held = kbDir ? kbDir : hatDir ? hatDir : axisDir;

		if (held == heldDir)
			return;

		heldDir = held;
		nextRepeat = SDL_GetTicks() + repeatDelay;
		pendingMove += held;
	}

	/* Repeats the held direction */
	void updateRepeat()
	{
		Uint32 now = SDL_GetTicks();

		if (heldDir && SDL_TICKS_PASSED(now, nextRepeat))
		{
			nextRepeat = now + repeatRate;
			pendingMove += heldDir;
		}
	}

	bool move(int delta)
	{
		if (games.empty())
			return false;

		int prev = selected;
		selected = std::max(0, std::min((int) games.size() - 1, selected + delta));

		return selected != prev;
	}

	/* Drawing, into a software canvas that is presented with GL */

	int listX() const { return px(80); }
	int listY() const { return px(200); }
	int listW() const { return (int) (width * 0.44f); }
	int rowH() const { return px(100); }

	int visibleRows() const
	{
		return std::max((height - listY() - px(120)) / rowH(), 1);
	}

	void fill(int x, int y, int w, int h, Color c)
	{
		SDL_Rect r = { x, y, w, h };
		SDL_FillRect(canvas, &r, SDL_MapRGBA(canvas->format, c.r, c.g, c.b, 255));
	}

	/* Draws 'text' with its top left at (x, y), shortened with an
	 * ellipsis to fit 'maxW' pixels; returns the drawn width */
	int text(TTF_Font *font, std::string str, int x, int y, Color c, int maxW = 0)
	{
		if (str.empty())
			return 0;

		int w = 0, h = 0;
		TTF_SizeUTF8(font, str.c_str(), &w, &h);

		if (maxW > 0 && w > maxW)
		{
			while (!str.empty() && w > maxW)
			{
				/* Drop one UTF-8 character */
				size_t len = str.size() - 1;
				while (len > 0 && (str[len] & 0xC0) == 0x80)
					--len;

				str.erase(len);
				TTF_SizeUTF8(font, (str + "...").c_str(), &w, &h);
			}

			str += "...";
		}

		SDL_Color color = { c.r, c.g, c.b, 255 };
		SDL_Surface *surf = TTF_RenderUTF8_Blended(font, str.c_str(), color);

		if (!surf)
			return 0;

		SDL_Rect dst = { x, y, surf->w, surf->h };
		SDL_BlitSurface(surf, 0, canvas, &dst);
		w = surf->w;
		SDL_FreeSurface(surf);

		return w;
	}

	int textWidth(TTF_Font *font, const std::string &str)
	{
		int w = 0, h = 0;
		TTF_SizeUTF8(font, str.c_str(), &w, &h);

		return w;
	}

	/* The game's title screen picture, if it isn't in an archive */
	SDL_Surface *preview(const Game &game)
	{
		std::map<std::string, SDL_Surface*>::iterator it = previews.find(game.path);

		if (it != previews.end())
			return it->second;

		const char *dirs[] =
		{
			"Graphics/Titles1", /* VX Ace */
			"Graphics/Titles",  /* XP */
			"Graphics/System",  /* VX: Title.png */
			"img/titles1"       /* MV, MZ (unless encrypted) */
		};

		SDL_Surface *result = 0;

		for (size_t i = game.version >= versionMV ? 3 : 0; i < 4 && !result; ++i)
		{
			std::string dir = joinPath(game.path, dirs[i]);
			std::vector<std::string> files = listDir(dir, false);

			for (size_t j = 0; j < files.size() && !result; ++j)
			{
				const std::string &name = files[j];
				size_t dot = name.find_last_of('.');
				std::string stem = name.substr(0, dot);
				std::string ext = dot == std::string::npos ? "" : name.substr(dot + 1);

				if (strcasecmp(ext.c_str(), "png") && strcasecmp(ext.c_str(), "jpg"))
					continue;

				if (i == 2 && strcasecmp(stem.c_str(), "Title"))
					continue;

				SDL_Surface *img = IMG_Load(joinPath(dir, name).c_str());

				if (img)
				{
					result = SDL_ConvertSurfaceFormat(img, SDL_PIXELFORMAT_ABGR8888, 0);
					SDL_FreeSurface(img);
				}
			}
		}

		previews[game.path] = result;

		return result;
	}

	void renderHeader(const char *subtitle)
	{
		fill(0, 0, width, height, colBackground);

		int x = listX();
		x += text(fontLarge, "mkxp", x, px(56), colText);
		text(fontMedium, subtitle, x + px(28), px(56) + px(22), colDim);
	}

	void renderEmpty()
	{
		int x = listX();
		int y = listY();

		text(fontMedium, "No games found", x, y, colText);
		y += px(70);
#ifdef MKXP_WITH_OUTSIDER
		text(fontSmall, "Copy each game's folder (the one containing " + iniName +
		     ", or www/ or js/ for MV and MZ games) into one of these folders:",
		     x, y, colDim, width - 2 * x);
#else
		text(fontSmall, "Copy each game's folder (the one containing " + iniName +
		     ") into one of these folders:", x, y, colDim, width - 2 * x);
#endif
		y += px(50);

		for (size_t i = 0; i < libraries.size(); ++i, y += px(40))
			text(fontSmall, libraries[i], x + px(30), y, colText, width - 2 * x);

		y += px(30);
		text(fontSmall, "Then press Triangle (F5) to look again.", x, y, colDim);
	}

	void renderList()
	{
		int rows = visibleRows();

		if (selected < scroll)
			scroll = selected;
		if (selected >= scroll + rows)
			scroll = selected - rows + 1;

		int x = listX(), w = listW(), h = rowH();
		int pad = px(24);

		for (int i = scroll; i < (int) games.size() && i < scroll + rows; ++i)
		{
			const Game &game = games[i];
			int y = listY() + (i - scroll) * h;

			if (i == selected)
				fill(x, y, w, h - px(8), colAccent);

			text(fontMedium, game.title, x + pad, y + px(12), colText, w - 2 * pad);
			text(fontSmall, makerName(game.version), x + pad, y + px(56),
			     i == selected ? colText : colDim, w - 2 * pad);
		}

		/* Position in the list */
		char count[32];
		snprintf(count, sizeof(count), "%d / %d", selected + 1, (int) games.size());
		text(fontSmall, count, x + w - textWidth(fontSmall, count),
		     listY() - px(44), colDim);

		/* Preview and details of the selected game */
		const Game &game = games[selected];
		int prevX = x + w + px(60);
		int prevW = width - prevX - px(80);
		int prevH = std::min(prevW * 3 / 4, height - listY() - px(260));

		fill(prevX, listY(), prevW, prevH, colPanel);

		if (SDL_Surface *img = preview(game))
		{
			float fit = std::min((float) prevW / img->w, (float) prevH / img->h);
			SDL_Rect dst;
			dst.w = (int) (img->w * fit);
			dst.h = (int) (img->h * fit);
			dst.x = prevX + (prevW - dst.w) / 2;
			dst.y = listY() + (prevH - dst.h) / 2;
			SDL_BlitScaled(img, 0, canvas, &dst);
		}
		else
		{
			const char *none = "No preview";
			text(fontSmall, none, prevX + (prevW - textWidth(fontSmall, none)) / 2,
			     listY() + prevH / 2 - px(14), colDim);
		}

		int y = listY() + prevH + px(30);
		text(fontMedium, game.title, prevX, y, colText, prevW);
		text(fontSmall, game.path, prevX, y + px(52), colDim, prevW);
	}

	void renderFooter()
	{
		std::string help = games.empty()
			? "Triangle / F5: Look again"
			: "Cross / Enter: Play     L1 R1: Page     Triangle / F5: Look again";

		text(fontSmall, help, listX(), height - px(80), colDim, width - 2 * listX());
	}

	void render()
	{
		renderHeader(games.empty() ? "" : "Choose a game");

		if (games.empty())
			renderEmpty();
		else
			renderList();

		renderFooter();
		upload();
	}

	void renderLoading(const Game &game)
	{
		renderHeader("");
		text(fontMedium, "Starting " + game.title + "...", listX(), listY(),
		     colText, width - 2 * listX());
		upload();
	}

	/* GL presentation: one textured quad covering the window */

	GLuint compile(GLenum type, const char *src)
	{
		GLuint shader = gl.CreateShader(type);
		GLint ok = 0;

		gl.ShaderSource(shader, 1, &src, 0);
		gl.CompileShader(shader);
		gl.GetShaderiv(shader, GL_COMPILE_STATUS, &ok);

		if (!ok)
		{
			char log[1024] = "";
			gl.GetShaderInfoLog(shader, sizeof(log), 0, log);
			Debug() << "Launcher: shader error:" << log;
		}

		return shader;
	}

	bool setupGL()
	{
		static const char *vertCore =
			"#version 330\n"
			"in vec2 position;\n"
			"out vec2 v_texCoord;\n"
			"void main() {\n"
			"	v_texCoord = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);\n"
			"	gl_Position = vec4(position, 0.0, 1.0);\n"
			"}\n";
		static const char *fragCore =
			"#version 330\n"
			"uniform sampler2D canvas;\n"
			"in vec2 v_texCoord;\n"
			"out vec4 fragColor;\n"
			"void main() {\n"
			"	fragColor = texture(canvas, v_texCoord);\n"
			"}\n";
		static const char *vertLegacy =
			"attribute vec2 position;\n"
			"varying vec2 v_texCoord;\n"
			"void main() {\n"
			"	v_texCoord = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);\n"
			"	gl_Position = vec4(position, 0.0, 1.0);\n"
			"}\n";
		static const char *fragLegacy =
			"#ifdef GL_ES\n"
			"precision mediump float;\n"
			"#endif\n"
			"uniform sampler2D canvas;\n"
			"varying vec2 v_texCoord;\n"
			"void main() {\n"
			"	gl_FragColor = texture2D(canvas, v_texCoord);\n"
			"}\n";

		static const GLfloat quad[] = { -1, -1,  1, -1,  -1, 1,  1, 1 };
		static const GLushort indices[] = { 0, 1, 2, 2, 1, 3 };

		vertShader = compile(GL_VERTEX_SHADER, gl.glslcore ? vertCore : vertLegacy);
		fragShader = compile(GL_FRAGMENT_SHADER, gl.glslcore ? fragCore : fragLegacy);

		program = gl.CreateProgram();
		gl.AttachShader(program, vertShader);
		gl.AttachShader(program, fragShader);
		gl.BindAttribLocation(program, 0, "position");
		gl.LinkProgram(program);

		GLint ok = 0;
		gl.GetProgramiv(program, GL_LINK_STATUS, &ok);

		if (!ok)
		{
			char log[1024] = "";
			gl.GetProgramInfoLog(program, sizeof(log), 0, log);
			Debug() << "Launcher: program error:" << log;

			return false;
		}

		gl.UseProgram(program);
		gl.Uniform1i(gl.GetUniformLocation(program, "canvas"), 0);

		/* Core profiles draw only with a vertex array object bound */
		if (gl.GenVertexArrays)
		{
			gl.GenVertexArrays(1, &vao);
			gl.BindVertexArray(vao);
		}

		gl.GenBuffers(1, &vbo);
		gl.BindBuffer(GL_ARRAY_BUFFER, vbo);
		gl.BufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
		gl.EnableVertexAttribArray(0);
		gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);

		gl.GenBuffers(1, &ibo);
		gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
		gl.BufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);

		gl.ActiveTexture(GL_TEXTURE0);
		gl.GenTextures(1, &tex);
		gl.BindTexture(GL_TEXTURE_2D, tex);
		gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
		              GL_RGBA, GL_UNSIGNED_BYTE, 0);

		gl.Disable(GL_BLEND);
		gl.Viewport(0, 0, width, height);

		return gl.GetError() == GL_NO_ERROR;
	}

	void upload()
	{
		if (!tex)
			return;

		/* ABGR8888 is R, G, B, A in memory; rows are 4 byte aligned */
		gl.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
		gl.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height,
		                 GL_RGBA, GL_UNSIGNED_BYTE, canvas->pixels);
	}

	void present()
	{
		if (program)
			gl.DrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 0);

		SDL_GL_SwapWindow(win);
	}

	void teardownGL()
	{
		/* Leave the context as the engine expects to find it */
		if (vao)
		{
			gl.BindVertexArray(0);
			gl.DeleteVertexArrays(1, &vao);
		}

		if (vbo || ibo)
		{
			gl.BindBuffer(GL_ARRAY_BUFFER, 0);
			gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
			gl.DeleteBuffers(1, &vbo);
			gl.DeleteBuffers(1, &ibo);
		}

		if (!vao && vbo)
			gl.DisableVertexAttribArray(0);

		if (tex)
		{
			gl.BindTexture(GL_TEXTURE_2D, 0);
			gl.DeleteTextures(1, &tex);
		}

		if (program)
		{
			gl.UseProgram(0);
			gl.DeleteProgram(program);
		}

		if (vertShader)
			gl.DeleteShader(vertShader);
		if (fragShader)
			gl.DeleteShader(fragShader);
	}
};

} // namespace

bool Launcher::wanted(const Config &conf)
{
	if (conf.gameLibraries.empty() || !conf.customScript.empty())
		return false;

	if (conf.gameFolder != ".")
		return false;

	/* The working directory holds a game: run it as before */
	return !isFile(conf.execName + ".ini");
}

std::string Launcher::run(SDL_Window *win, const Config &conf)
{
#ifdef MKXP_PS5_NATIVE
	/* Have the console's internal storage library ready to copy games
	 * into (USB drives might not be mounted, the title is read-only) */
	for (size_t i = 0; i < conf.gameLibraries.size(); ++i)
		if (conf.gameLibraries[i].compare(0, 6, "/data/") == 0)
			makeDirs(conf.gameLibraries[i]);
#endif

	Picker picker(win, conf);
	std::string path = picker.run();

	/* Don't pass the button press on to the game */
	SDL_FlushEvents(SDL_KEYDOWN, SDL_TEXTINPUT);
	SDL_FlushEvents(SDL_JOYAXISMOTION, SDL_JOYBUTTONUP);

	return path;
}

bool Launcher::isScriptGame(const std::string &gameDir)
{
	int version;

	return scriptGameRoot(gameDir, &version) == gameDir;
}

std::string Launcher::saveFolder(const std::string &gameDir, const Config &conf)
{
	if (isWritable(gameDir))
		return gameDir;

#ifdef MKXP_PS5_NATIVE
	(void) conf;
	std::string dir = joinPath("/download0", baseName(gameDir));
#else
	std::string dir = conf.commonDataPath + baseName(gameDir);
#endif

	mkdir(dir.c_str(), 0755);

	return dir;
}
