; Inno Setup script for the Guitar Tab/Notation Viewer REAPER script.
;
; What this does: copies main.lua + install_toolbar_button.lua + src/*.lua
; into the current Windows user's REAPER Scripts folder (no
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
; Registering the script as a REAPER action and adding its toolbar
; button (install_toolbar_button.lua) needs REAPER's own scripting API,
; which only exists while REAPER is running - this installer .exe can't
; call it directly. Instead, the [Run] section below launches REAPER
; itself with install_toolbar_button.lua as a command-line argument once
; Setup finishes (a real, working REAPER command-line feature: passing a
; .lua file runs it; -nonewinst hands it to an already-running instance
; instead of opening a second one) - REAPER's own install path is looked
; up via the registry (see GetReaperExePath below, verified against a
; real install: HKLM\SOFTWARE\REAPER's default value). This is
; best-effort: if REAPER's install path can't be found, that [Run] entry
; simply doesn't appear, and POST_INSTALL.txt's manual instructions
; (Load ReaScript for main.lua, then run install_toolbar_button.lua) are
; the fallback - always kept up to date even though the automatic path
; now covers the common case.
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
; ReaImGui/ReaPack extensions - see this file's header for why these are
; bundled DLL drops into UserPlugins rather than a ReaPack-mediated
; install. onlyifdoesntexist: never overwrite a copy the user (or
; ReaPack) already has - a friend who's already set these up shouldn't
; have their existing (possibly newer) version silently downgraded.
Source: "..\vendor\reaper_imgui64.dll"; DestDir: "{app}\..\..\UserPlugins"; Flags: onlyifdoesntexist
Source: "..\vendor\reaper_reapack64.dll"; DestDir: "{app}\..\..\UserPlugins"; Flags: onlyifdoesntexist

[Run]
; postinstall: shown as a checked-by-default checkbox on the finish page
; (labeled via Description below), not run unconditionally - a real
; side effect (opening REAPER) deserves to be visible/optional, same as
; any installer's "Launch the app now" checkbox. nowait: critical - if
; REAPER isn't already running, this LAUNCHES it (a real REAPER session
; that stays open), not a script that runs and exits; without nowait,
; Setup would sit frozen on the finish page until the user closes
; REAPER. skipifsilent: never launch REAPER during an unattended/silent
; install. Check: only offered at all if GetReaperExePath found a real
; reaper.exe - see the [Code] section below.
Filename: "{code:GetReaperExePath}"; Parameters: "-nonewinst ""{app}\install_toolbar_button.lua"""; Description: "Finish setup automatically (registers the script and adds its toolbar button - opens REAPER if it isn't already running)"; Flags: postinstall nowait skipifsilent; Check: ReaperExeFound

[Code]
var
  CachedReaperExe: String;
  CachedReaperExeChecked: Boolean;

// Locates reaper.exe. Tries the registry key REAPER's own installer
// writes first (HKLM\SOFTWARE\REAPER's default value = the install
// directory - confirmed against a real REAPER install during
// development), then HKCU for a per-user install, then a couple of
// common default paths as a last resort (e.g. a portable install
// someone copied into place by hand, with no registry entry at all).
// Returns '' if none of those pan out - callers must treat that as
// "couldn't find it," not a path to blindly use.
function FindReaperExe(): String;
var
  InstallDir: String;
begin
  Result := '';

  if RegQueryStringValue(HKLM, 'SOFTWARE\REAPER', '', InstallDir) then begin
    if FileExists(AddBackslash(InstallDir) + 'reaper.exe') then begin
      Result := AddBackslash(InstallDir) + 'reaper.exe';
      Exit;
    end;
  end;

  if RegQueryStringValue(HKCU, 'SOFTWARE\REAPER', '', InstallDir) then begin
    if FileExists(AddBackslash(InstallDir) + 'reaper.exe') then begin
      Result := AddBackslash(InstallDir) + 'reaper.exe';
      Exit;
    end;
  end;

  if FileExists(ExpandConstant('{pf}\REAPER (x64)\reaper.exe')) then begin
    Result := ExpandConstant('{pf}\REAPER (x64)\reaper.exe');
    Exit;
  end;
  if FileExists(ExpandConstant('{pf}\REAPER\reaper.exe')) then begin
    Result := ExpandConstant('{pf}\REAPER\reaper.exe');
    Exit;
  end;
  if FileExists(ExpandConstant('{pf32}\REAPER\reaper.exe')) then begin
    Result := ExpandConstant('{pf32}\REAPER\reaper.exe');
    Exit;
  end;
end;

// FindReaperExe does registry/filesystem lookups - cache the result so
// the [Run] entry's Filename (GetReaperExePath) and Check
// (ReaperExeFound) don't redo that work independently; Inno Setup can
// evaluate both during the same wizard pass.
function GetReaperExePath(Param: String): String;
begin
  if not CachedReaperExeChecked then begin
    CachedReaperExe := FindReaperExe();
    CachedReaperExeChecked := True;
  end;
  Result := CachedReaperExe;
end;

function ReaperExeFound(): Boolean;
begin
  Result := GetReaperExePath('') <> '';
end;
