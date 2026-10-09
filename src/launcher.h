/*
** launcher.h
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

#ifndef LAUNCHER_H
#define LAUNCHER_H

#include <string>

struct Config;
struct SDL_Window;

/* Game picker shown before the engine starts, when no game folder is
 * configured and the working directory doesn't hold a game itself. It
 * lists the subfolders of the configured game libraries that contain a
 * game (Game.ini), and is driven by a game controller or the keyboard. */
namespace Launcher
{
	/* Whether the launcher should be shown for this configuration
	 * (call from within the initial working directory) */
	bool wanted(const Config &conf);

	/* Runs the picker on 'win', whose GL context must be current.
	 * Returns the absolute path of the chosen game folder, or an
	 * empty string if the user quit. */
	std::string run(SDL_Window *win, const Config &conf);

	/* Where save files go for a game launched from 'gameDir':
	 * the game folder itself when it's writable, or a per-game
	 * folder in writable storage otherwise */
	std::string saveFolder(const std::string &gameDir, const Config &conf);
}

#endif // LAUNCHER_H
