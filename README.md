# ClipJump-Ultra
Clipboard Tool with several smart functions.

A fork of [Clipjump-plus](https://github.com/telppa/Clipjump-plus) (based on Clipjump v12.5), AutoHotkey v1, 64-bit only.

## Additions in this fork
- Windows 11 (Fluent) design for paste mode, toasts, action mode and dialogs, light/dark theme
- Password clips: detected via the password-manager clipboard markers, masked in previews,
  DPAPI-encrypted on disk, deleted after a configurable lifetime, never exported, edited or sent out
- Read aloud with ElevenLabs (Action Mode/Paste Mode `R`)
- Correct (`W`) and translate (`T`) text with a local OpenAI-compatible LLM
- Paste an image clip as Base64 / data URI (Paste Mode `B`)
- Search box integrated into the paste mode panel (Paste Mode `Ctrl+F`)
- "Clip Actions" window (formerly Common Formats) with translate / correct / read aloud
- Copy File Data / Copy Folder Path working with Windows 11 Explorer tabs
- Export as plain text, edit clip with external editors (e.g. Notepad++)

Settings live in `settings.ini` (not part of the repository). Secrets are read from environment
variables (`ELEVENLABS_API_KEY`, `LOCAL_LLM_URL`).

## Build
Compile `Clipjump.ahk` with Ahk2Exe (`Unicode 64-bit.bin`, icon `icons\icon.ico`), then set the
version info with `tools\Set-VersionInfo.ps1 -Exe Clipjump.exe -Version 12.7`.

---

## Clipjump-Ultra readme
[Download](https://github.com/magomic/Clipjump-Ultra/releases)  
<!-- [Online Manual](http://clipjump.sourceforge.net/docs/) -->
  
Clipjump is a Multiple-Clipboard management utility for Windows.
It was built to make working with multiple clipboards super fast and super easy.
The program records changes in the system clipboard, stores them without any limits and provides innovative ways to work with them.  


## Compare with Clipjump
0. base on clipjump v12.5.
1. new chinese translation.
2. use btt() to display all tips (that means fixed all the bugs of tooltip).
3. fixed wrong control position in history GUI.
4. fixed highlighting failure in history GUI.
5. fixed wrong picture preview position in paste mode.
6. fixed a copy failure in excel.
7. align text in action mode for all languages.
8. only x64 version.


## Building the Docs
Docs can be compiled using Jekyll and then Microsoft's HHC. First build the website folder using Jekyll and then compile the jekyll-processed files using HHC.


## Adding Plugins
Please add your plugins to the [clipjump-addons](https://github.com/aviaryan/clipjump-addons) repository. This repo only contains plugins distributed with official Clipjump release. 
If I realise your plugin is useful for the community, I will distribute it officially and hence it will be added to this repository. See [#68](https://github.com/aviaryan/Clipjump/issues/68)

