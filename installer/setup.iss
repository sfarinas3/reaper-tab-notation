; Inno Setup script for the Guitar Tab/Notation Viewer REAPER script.
;
; What this does: copies main.lua + src/*.lua into the current Windows
; user's REAPER Scripts folder (no admin rights needed - it's a per-user
; AppData install, same folder deploy.ps1 already targets for local dev).
; It does NOT install ReaPack/ReaImGui (REAPER's own dependency, and this
; installer runs outside REAPER so it can't call REAPER's action-
; registration API) and does NOT register the script as a REAPER action -
; POST_INSTALL.txt (shown on the last wizard page) tells the user the one
; manual step (Actions > Show Action List > New Action > Load ReaScript).
; See ..\DISTRIBUTION.md for the full packaging writeup, including what's
; deliberately deferred (license-key gating, Lua bytecode precompilation)
; and how to add each without restructuring this script.
;
; Build: install Inno Setup (https://jrsoftware.org/isinfo.php), then
;   ISCC installer\setup.iss
; produces dist\ReaperTabNotation-Setup.exe.

#define MyAppName "Guitar Tab/Notation Viewer"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Guitar Tab/Notation Viewer"

[Setup]
AppId={{B6C1B6B4-6C1A-4B7E-9C9A-8F3F6B2E9D11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
; Per-user install (REAPER's own Scripts folder lives under the user's
; AppData, not Program Files) - no UAC prompt, no admin rights required.
PrivilegesRequired=lowest
DefaultDirName={userappdata}\REAPER\Scripts\reaper-tab-notation
; Let the wizard show/allow editing this path - a portable REAPER install,
; or a REAPER resource path moved via REAPER's own preferences, won't
; match the {userappdata} default.
DisableDirPage=no
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputDir=..\dist
OutputBaseFilename=ReaperTabNotation-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
InfoAfterFile=POST_INSTALL.txt
; Nothing here yet - see DISTRIBUTION.md's "Adding a license-key prompt"
; section for where a custom wizard page would go (a [Code] section using
; CreateInputQueryPage, run from InitializeWizard, checked in
; NextButtonClick before the Install step is allowed to proceed).

[Files]
; Swapping this to ship precompiled bytecode instead of source later is a
; one-line change here (see DISTRIBUTION.md's "Precompiling to Lua
; bytecode" section) - point Source at the .luac build output instead of
; the repo's .lua files, everything else in this script stays the same.
Source: "..\main.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\*.lua"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs
