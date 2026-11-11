#ifndef MyAppVersion
  #error MyAppVersion must be supplied from the repository VERSION file
#endif

#define MyAppName "牛马电子功德"
#define MyAppPublisher "牛马电子功德"
#define MyAppURL "https://gongde.zqscreen.cn/"
#define MyAppExeName "niuma-merit.exe"

[Setup]
AppId={{D1B9D81E-13A1-45E2-9B8F-33C9C7A06F27}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}contact.html
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\NiumaMerit
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=no
DisableFinishedPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=niuma-merit-windows-{#MyAppVersion}-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Windows 安装程序
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

ShowLanguageDialog=no
LanguageDetectionMethod=uilanguage
UsePreviousLanguage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "chinesetraditional"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "thai"; MessagesFile: "compiler:Default.isl"

[LangOptions]
chinesetraditional.LanguageID=$0404
chinesetraditional.LanguageName=中文
korean.LanguageID=$0412
korean.LanguageName=한국어
french.LanguageID=$040c
french.LanguageName=Français
german.LanguageID=$0407
german.LanguageName=Deutsch
spanish.LanguageID=$0c0a
spanish.LanguageName=Español
thai.LanguageID=$041e
thai.LanguageName=ไทย

[CustomMessages]
chinesesimp.LaunchApp=启动%1
english.LaunchApp=Launch %1
korean.LaunchApp=%1 열기
french.LaunchApp=Lancer %1
german.LaunchApp=%1 starten
spanish.LaunchApp=Abrir %1
thai.LaunchApp=เปิด %1

[Files]
Source: "..\..\dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Flags: nowait skipifsilent

#include "startup-choice.iss"
