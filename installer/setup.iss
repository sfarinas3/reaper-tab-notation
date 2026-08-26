; Inno Setup script for the Guitar Tab/Notation Viewer REAPER script.
;
; What this does: copies main.lua + install_toolbar_button.lua + src/*.lua
; + assets/* into the current Windows user's REAPER Scripts folder (no
; admin rights needed - it's a per-user AppData install, same folder
; deploy.ps1 already targets for local dev), AND drops pinned copies of
; the ReaImGui/ReaPack extension DLLs (vendor\*.dll) into REAPER's own
; UserPlugins folder - REAPER loads any DLL there exporting the right
; entry point regardless of filename or how it got there, so this is a
; real install, not a shortcut; ReaPack itself is normally how a user
; would get these, but our script only actually needs the ReaImGui
; extension loaded, so installing that DLL directly skips needing ReaPack
; as a dependency of a dependency. UserPlugins is derived as a sibling of
; {app} (..\..\UserPlugins) rather than hardcoded from {userappdata}, so
; it still lands in the right place if the wizard's dir page (below) is
; used to retarget a non-default REAPER resource path.
;
; The DLLs are bundled at fixed pinned versions (see vendor\VERSIONS.txt)
; rather than fetched live from GitHub at install time - keeps the
; installer fully offline/reliable for a friend with no dependency on
; GitHub being reachable or its release asset URLs never changing, at
; the cost of needing a manual refresh here for a newer version later.
;
; This does NOT register the script as a REAPER action or add its
; toolbar button - POST_INSTALL.txt (shown on the last wizard page) tells
; the user the one remaining manual one-time step (Load ReaScript for
; main.lua, then run install_toolbar_button.lua once - see that file's
; own header for why the toolbar button specifically can't be set up
; from here either, unlike the extensions above).
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
Source: "..\install_toolbar_button.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\*.lua"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs
Source: "..\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs
; ReaImGui/ReaPack extensions - see this file's header for why these are
; bundled DLL drops into UserPlugins rather than a ReaPack-mediated
; install. onlyifdoesntexist: never overwrite a copy the user (or
; ReaPack) already has - a friend who's already set these up shouldn't
; have their existing (possibly newer) version silently downgraded.
Source: "..\vendor\reaper_imgui64.dll"; DestDir: "{app}\..\..\UserPlugins"; Flags: onlyifdoesntexist
Source: "..\vendor\reaper_reapack64.dll"; DestDir: "{app}\..\..\UserPlugins"; Flags: onlyifdoesntexist
