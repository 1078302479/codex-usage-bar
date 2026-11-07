[Setup]
AppId={{4A84D3A6-4DF8-420C-AF13-0F99CA1629A8}
AppName=Codex UsageBar (Windows)
AppVersion={#AppVersion}
AppPublisher=Codex UsageBar
AppPublisherURL=https://github.com/1078302479/codex-usage-bar/tree/windows
AppSupportURL=https://github.com/1078302479/codex-usage-bar/issues
DefaultDirName={localappdata}\Programs\CodexUsageBar
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

[Messages]
WelcomeLabel2=This wizard installs Codex UsageBar for Windows.%n%nInstall the official Microsoft Store version of Codex first. Setup will prepare a local client copy. After setup, exit the official Codex client and use the Codex UsageBar shortcut.

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"
Name: startmenuicon; Description: "Create a Start menu shortcut"

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{userdesktop}\Codex UsageBar"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\windows\patch\Open-SidebarClient.ps1"" -ShowErrors"; WorkingDir: "{app}"; IconFilename: "{app}\.local\windows-sidebar-client\ChatGPT.exe"; Tasks: desktopicon
Name: "{userprograms}\Codex UsageBar"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\windows\patch\Open-SidebarClient.ps1"" -ShowErrors"; WorkingDir: "{app}"; IconFilename: "{app}\.local\windows-sidebar-client\ChatGPT.exe"; Tasks: startmenuicon

[Code]
var
  CopyPreparationFailed: Boolean;

function RunInstallerScript(const Args: String; var ExitCode: Integer): Boolean;
begin
  Result := Exec(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\windows\Install-Sidebar.ps1') + '" ' + Args,
    ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
end;

function CheckClientClosed: Boolean;
var
  ExitCode: Integer;
begin
  Result := not FileExists(ExpandConstant('{app}\windows\Install-Sidebar.ps1')) or
    RunInstallerScript('-CheckClientClosed', ExitCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not CheckClientClosed then
    Result := 'Exit Codex UsageBar from the File menu or system tray, then try again.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  LogPath: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  WizardForm.StatusLabel.Caption := 'Preparing and verifying the local Codex client copy...';
  LogPath := ExpandConstant('{localappdata}\CodexUsageBar-setup.log');
  CopyPreparationFailed := not RunInstallerScript('-SkipShortcut -ReplaceExisting -LogPath "' + LogPath + '"', ExitCode);
  if CopyPreparationFailed then
    RaiseException('Could not prepare the Codex client copy. Check the setup log at:' + #13#10 + LogPath);
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if CopyPreparationFailed then
    Result := 8;
end;

function InitializeUninstall: Boolean;
begin
  Result := CheckClientClosed;
  if not Result then
    SuppressibleMsgBox('Exit Codex UsageBar from the File menu or system tray, then uninstall again.',
      mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ExitCode: Integer;
begin
  if (CurUninstallStep = usUninstall) and DirExists(ExpandConstant('{app}\.local')) and
    not RunInstallerScript('-RemoveClient', ExitCode) then
    RaiseException('Could not remove the local client copy. Close Codex UsageBar and try again.');
end;
