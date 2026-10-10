# Crossword Plugin for KOReader

Play classic crossword puzzles on your e-reader. Five ways to get puzzles:

1. **Local files** — drop `.puz` (Across Lite), `.ipuz` or NYT archive `.json` files into `koreader/data/crossword/` (survives plugin updates) or `plugins/crossword.koplugin/puzzles/` and open them from the library.
2. **Download from sources** — fetch today's free puzzles from USA Today, Universal, Wall Street Journal, Washington Post, and more with one tap.
3. **Guardian** — fetch any of the daily free puzzles from [The Guardian](https://www.theguardian.com/crosswords) (Quick, Cryptic, Everyman, Speedy, Prize, Weekend, Quiptic) — pick *Today's …* to download the latest, or open a specific number by URL.
4. **Crosshare** — fetch free community puzzles from [crosshare.org](https://crosshare.org) by ID or URL.
5. **Generator** — produce puzzles locally from any installed StarDict dictionary, current book, or Vocabulary Builder. Works fully offline and supports Turkish, English, and any other language you have a word list for.

## Menu

Located under **Tools → Crossword**:

- **Continue** — resume the last open puzzle.
- **Library** — list puzzles shipped in the `puzzles/` folder and previously opened ones.
- **Recently played** — resume puzzles with preserved progress across sessions.
- **Download from sources** — one-tap downloads of today's free puzzles from:
  - USA Today
  - Universal Crossword (daily & Sunday)
  - Wall Street Journal
  - Washington Post Sunday
  - Jonesin' (Thursday puzzle)
  - Newsday
  - **BEQ (Brendan Emmett Quigley)** — Latest puzzle (Monday & Thursday)
  - **New York Times (Archive)** — Every NYT puzzle from 1976 to March 2018
- **Guardian crosswords** — sub-menu: *Today's Quick / Cryptic / Everyman / Speedy / Prize / Weekend / Quiptic*, plus *By number…* and *From URL…*.
- **Get from Crosshare** — sub-menu: *Paste Crosshare URL or ID…* (Crosshare does not publish a browseable API, so discovery still happens in a browser).
- **Generate puzzle** — pick a word source, size, and difficulty to build a new puzzle.
- **Settings** — keyboard layout, hint behavior, default generator settings.

## Free Puzzle Sources

All sources in the "Download from sources" menu are **completely free** and require **no authentication**:

- **USA Today** — Daily puzzle, beginner to intermediate difficulty
- **Universal Crossword** — Daily (Mon-Sat) and Sunday editions, accessible difficulty
- **Wall Street Journal** — Daily puzzle, intermediate to challenging
- **Washington Post** — Sunday puzzle only
- **Jonesin'** — Thursday puzzle (published on Tuesday), quirky and fun
- **Newsday** — Daily puzzle, intermediate difficulty
- **BEQ (Brendan Emmett Quigley)** — Latest puzzle (Monday & Thursday), challenging and creative. Always fetches the most recent puzzle from brendanemmettquigley.com
- **New York Times (Archive)** — Complete archive from Jan 1976 to Mar 9, 2018 (the archive is no longer updated). Use "By date…" to pick a puzzle, or step day by day from the in-game menu.

**Note**: The Atlantic, LA Times, and New Yorker sources have been temporarily disabled due to website changes that broke HTML parsing. They may be re-enabled in future updates.

### Download Past Puzzles

Use the **"By date…"** option to download puzzles from previous days:
- Enter dates as `YYYY-MM-DD` (e.g., `2026-05-15`) or `MM/DD/YYYY` (e.g., `05/15/2026`)
- Or use relative dates: `yesterday`, `3 days ago`, `7 days ago`, etc.
- Archives typically go back several months to years

Puzzles are automatically cached, so you can download once and replay offline.

### Source Reliability

**Most Reliable (✅ Tested & Working):**
- **USA Today / Universal** — Direct .puz downloads from Herbach mirror ✅
- **Wall Street Journal** — Direct .puz downloads from Herbach mirror ✅
- **New York Times Archive** — GitHub archive, 1976–2018 ✅
- **Washington Post Sunday** — Herbach mirror, Sunday only ✅
- **Jonesin'** — Herbach mirror, Thursday puzzle (published Tuesday) ✅
- **BEQ** — HTML parsing from brendanemmettquigley.com, always gets latest puzzle ✅

**Moderately Reliable (⚠️ May Have Issues):**
- **Newsday** — Tries multiple backup URLs, but CDN may change
- **Universal Sunday** — Sunday only, otherwise shows last Sunday's puzzle

**Important Notes:**
- The **Herbach mirror** (herbach.dnsalias.com) occasionally goes down for maintenance
- Some sources only publish on specific days (Sunday, Thursday, etc.)
- If a source fails, try **NYT Archive** — it has 42 years of reliable puzzles (1976–2018)!
- Historical puzzles (via "By date…") are more reliable than today's puzzle for some sources

## New York Times Archive

The plugin includes **every New York Times crossword from Jan 1, 1976 to Mar 9, 2018** via the [doshea/nyt_crosswords](https://github.com/doshea/nyt_crosswords) GitHub archive! 

- **42 years** of puzzles available for free; the archive stopped being updated in March 2018, so later dates are not available
- No subscription or authentication required
- Use "By date…" to access any historical puzzle
- Gaps: the longest are Aug 10 – Nov 5, 1978 and Aug 30, 2015 – May 1, 2016; about 100 shorter stretches (mostly single days) are also missing, and from mid-2016 on only scattered days exist. The plugin knows every missing date and warns before downloading.
- While an archive puzzle is open, **☰ Menu** shows `◀ previous date` / `next date ▶` buttons that step to the neighbouring puzzle, skipping missing days.

**Offline use:** copy the whole repository (git clone or the GitHub zip, folder `nyt_crosswords` or `nyt_crosswords-master`) into `koreader/data/crossword/` or the plugin's `puzzles/` folder. "By date…" then reads `YYYY/MM/DD.json` from there and only goes online for missing dates. Individual `.json` files placed directly in those folders show up in the library.

For the **latest NYT puzzles** (requires subscription), use the community tool [`xword-dl`](https://github.com/thisisparker/xword-dl) to download as `.puz` and place in the `puzzles/` folder.

## Controls in Game Screen

- **Tap a cell** to move the cursor. Tap the same cell again to toggle direction (Across ↔ Down).
- **Clue banner** always shows the clue for the word under the cursor. **Tap the banner** to pop up the full clue when a long one is cut off.
- **D-pad** (to the right of the keyboard) moves the cursor one cell at a time (handy when most cells are filled in); the center button toggles direction.
- **On-screen keyboard** places letters and auto-advances within the current word.
- **Erase** clears the focused cell.
- **Prev / Next** step through clues in the current direction.
- **Clues** opens the full clues list; tap a clue to jump to it.
- **Menu** offers Check, Reveal, Reset, and more.

## File Formats

- `.puz` — Across Lite binary format (most free daily newspaper puzzles).
- `.ipuz` — Open crossword JSON format.

## Puzzle Generator

Pick a source:

- **Word list (TSV)** — plain text, one `word<TAB>clue` pair per line.
- **StarDict dictionary** — any `.ifo`/`.idx`/`.dict`(`.dz`) set under `data/dict/`.

Pick grid size (5×5 mini, 11×11, 15×15) and the generator will place words with a backtracking algorithm, using dictionary definitions as clues.

## Credits

Uses only free/open data sources. Bundles no copyrighted puzzles; `.puz` files you place in `puzzles/` remain subject to their own licenses.

This plugin was developed with the assistance of Windsurf AI.
