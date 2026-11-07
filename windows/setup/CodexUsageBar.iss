[Setup]
#ifdef SmokeTest
AppId={{E5A19206-4889-4E19-B3E4-90F19EBC4E8A}
AppName=Codex UsageBar Smoke Test
#else
AppId={{4A84D3A6-4DF8-420C-AF13-0F99CA1629A8}
AppName=Codex UsageBar (Windows)
#endif
AppVersion={#AppVersion}
AppPublisher=Codex UsageBar
AppPublisherURL=https://github.com/1078302479/codex-usage-bar/tree/windows
AppSupportURL=https://github.com/1078302479/codex-usage-bar/issues
#ifdef SmokeTest
DefaultDirName={localappdata}\Programs\CodexUsageBar-SmokeTest
#else
DefaultDirName={localappdata}\Programs\CodexUsageBar
#endif
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
CloseApplications=no
WizardStyle=modern
Compression=lzma2/fast
SolidCompression=yes
OutputBaseFilename=CodexUsageBar-Windows-x64-Setup
#ifdef EnableSigning
SignTool=usagebar
SignedUninstaller=yes
#endif

[Messages]
WelcomeLabel2=Install the official Microsoft Store version of Codex first.%n%nSetup prepares a separate Codex client copy for the sidebar. Changing the copy invalidates its original executable signature. The installed Microsoft Store client keeps its original files.%n%nAfter setup, exit Codex and use the Codex UsageBar shortcut.

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"
Name: startmenuicon; Description: "Create a Start menu shortcut"

[Files]
Source: "{#PayloadDir}\CodexUsageBar.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "CodexUsageBar.exe"; Flags: recursesubdirs createallsubdirs ignoreversion

[InstallDelete]
Type: files; Name: "{app}\windows\Install-Sidebar.ps1"
Type: files; Name: "{app}\windows\patch\Open-SidebarClient.ps1"
Type: files; Name: "{app}\windows\patch\Start-SidebarTest.ps1"
Type: files; Name: "{app}\windows\patch\Resolve-SidebarNode.ps1"
Type: files; Name: "{app}\windows\patch\Check-SidebarUpdate.ps1"

#ifndef SmokeTest
[Icons]
Name: "{userdesktop}\Codex UsageBar"; Filename: "{app}\CodexUsageBar.exe"; WorkingDir: "{app}"; IconFilename: "{app}\.local\windows-sidebar-client\ChatGPT.exe"; Tasks: desktopicon
Name: "{userprograms}\Codex UsageBar"; Filename: "{app}\CodexUsageBar.exe"; WorkingDir: "{app}"; IconFilename: "{app}\.local\windows-sidebar-client\ChatGPT.exe"; Tasks: startmenuicon
Name: "{userprograms}\Codex UsageBar Settings"; Filename: "{app}\CodexUsageBar.exe"; Parameters: "settings"; WorkingDir: "{app}"; Tasks: startmenuicon
#endif

[Code]
var
  CopyPreparationFailed: Boolean;

function RunLauncher(const FileName, Args: String; var ExitCode: Integer): Boolean;
begin
  Result := Exec(FileName, Args, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
end;

function CheckClientClosed(const Launcher: String): Boolean;
var
  ExitCode: Integer;
begin
  Result := RunLauncher(Launcher, 'check-client "' + ExpandConstant('{app}') + '"', ExitCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Launcher: String;
begin
  Result := '';
  if not FileExists(ExpandConstant('{app}\.local\windows-sidebar-client\ChatGPT.exe')) then
    Exit;
  Launcher := ExpandConstant('{tmp}\CodexUsageBar.exe');
  if not FileExists(Launcher) then
    ExtractTemporaryFile('CodexUsageBar.exe');
  if not CheckClientClosed(Launcher) then
    Result := 'Exit Codex UsageBar and close its Settings window, then try again.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  LogPath: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  WizardForm.StatusLabel.Caption := 'Preparing and verifying the local Codex client copy...';
  #ifdef SmokeTest
  LogPath := ExpandConstant('{localappdata}\CodexUsageBar-smoke-setup.log');
  #else
  LogPath := ExpandConstant('{localappdata}\CodexUsageBar-setup.log');
  #endif
  CopyPreparationFailed := not RunLauncher(ExpandConstant('{app}\CodexUsageBar.exe'), 'install "' + LogPath + '"', ExitCode);
  if CopyPreparationFailed then
    RaiseException('Could not prepare the Codex client copy. Check the setup log at:' + #13#10 + LogPath);
  CopyPreparationFailed := not SaveStringToFile(
    ExpandConstant('{app}\.local\windows-sidebar-version.txt'), '{#AppVersion}', False);
  if CopyPreparationFailed then
    RaiseException('Could not record the installed version.');
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if CopyPreparationFailed then
    Result := 8;
end;

function InitializeUninstall: Boolean;
begin
  Result := CheckClientClosed(ExpandConstant('{app}\CodexUsageBar.exe'));
  if not Result then
    SuppressibleMsgBox('Exit Codex UsageBar and close its Settings window, then uninstall again.',
      mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ExitCode: Integer;
begin
  if (CurUninstallStep = usUninstall) and DirExists(ExpandConstant('{app}\.local')) and
    not RunLauncher(ExpandConstant('{app}\CodexUsageBar.exe'), 'remove', ExitCode) then
    RaiseException('Could not remove the local client copy. Close Codex UsageBar and try again.');
end;
