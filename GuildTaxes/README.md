# Guild Taxes (WoW: Forever)

Keep your guild bank full. Guild Taxes sets aside a share of the gold you earn
and pays it into the guild bank the next time you open it.

This is a port of Guild Taxes for **WoW: Forever** (Interface 16001). It is
built on the LbH edition of the addon.

## How it works

- Each time your gold goes up, Guild Taxes adds your tax rate (10% by default)
  of that amount to your outstanding tax. Gold you take from the mailbox or
  the guild bank doesn't count, so auction house sales and withdrawals aren't
  taxed twice.
- When you open the guild bank, the outstanding tax is deposited
  automatically. If you turn autopay off, you can pay with the button in the
  main window, the link in chat or the small tax box.
- Guild members who have the addon share their tax rate, outstanding tax and
  payments with each other in the background. Syncing pauses in combat and
  whenever the game blocks addon messages.

## Main window

Type `/gt` to open the main window. It looks like the Professions window and
the other Forever windows.

- Your guild, your outstanding tax and your tax rate at the top.
- One row per guild member: name in class colour (grey when offline), rank,
  outstanding tax with rate, the payments of the last three months and the
  total. Values only show for members who have the addon.
- "Online only" filter and the number of members online.
- Pay button, which works while the guild bank is open.
- Drag the title bar to move the window and the bottom-right corner to resize
  it. Escape closes it.

There is also a small tax box on screen that shows what you owe. Click it to
pay while the guild bank is open, or to open the main window otherwise. Drag
it to move it.

## Commands

| Command | What it does |
| --- | --- |
| `/gt` | Open or close the main window |
| `/gt status` | Print your outstanding tax in chat |
| `/gt sync` | Ask all guild members for their current data |
| `/gt resetall` | Clear all history and counters of the guild (Guild Master only) |

## Options

Open them under *Options → AddOns → Guild Taxes*.

- **Tax rate**: the share of earned gold that goes to the guild bank
  (0–100%, per character).
- **Autopay**: pay automatically when the guild bank opens (on by default).
- **Show mini tax frame**: show the small tax box on screen.
- **Print transactions**: print the tax on each gold gain in chat (off by
  default).
- **Verbose output** and **Debug**: extra chat output for troubleshooting.

## Installation

1. Download this repository.
2. Copy the folder to
   `World of Warcraft\_forever_\Interface\AddOns\`.
3. Rename the folder to **`GuildTaxes`**. The folder name has to match
   `GuildTaxes.toc`, or the game won't load the addon.
4. Restart the game or type `/reload`.

Your settings and history are stored in `GuildTaxesDB` and carry over from
other versions of Guild Taxes.

## Languages

English, German, Portuguese (Brazil) and Russian.

## Changes in the Forever port

- Uses the modern (Midnight) API of WoW: Forever. It detects the guild bank and
  mailbox through the player interaction manager and only registers events
  the client knows.
- Main window rebuilt with the client's own window templates.
- Updated Ace3 libraries.
- The pay link in chat uses the client's addon link type.
- Fixed the check that stops a deposit from being counted twice.

The full list is in [CHANGELOG.txt](CHANGELOG.txt).

## Credits

- Original addon: Неогик@Галакронд
- WoW: Forever port: Snadjoev

Libraries: [Ace3](https://www.wowace.com/projects/ace3).

## License

BSD-style license, see [LICENSE.txt](LICENSE.txt).
