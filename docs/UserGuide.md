# Event Framework – User Guide

How to add the EventFramework library to a TwinCAT project and use it to raise alarms and messages.

---

## Contents

1. [What you need](#1-what-you-need)
2. [Adding the framework to a project](#2-adding-the-framework-to-a-project)
3. [Defining events](#3-defining-events)
4. [Alarms](#4-alarms)
5. [Messages](#5-messages)
6. [Arguments](#6-arguments)
7. [Languages](#7-languages)
8. [Updating to a new library version](#8-updating-to-a-new-library-version)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. What you need

- TwinCAT 3.1 XAE (4024 or 4026) installed on the engineering PC.
- A folder with the framework files:

| File | What it is |
|---|---|
| `EventFramework.library` | The library. |
| `EventFramework.tmc` | The event classes the library needs in the type system. |
| `GVL_EventTexts.TcGVL` | A starter text list for your events. |
| `Add-EventFramework.ps1` and `Add-EventFramework.cmd` | The setup script. |

The files can sit in subfolders. The script searches the whole folder.

---

## 2. Adding the framework to a project

### Run the script

1. **Close the solution in TwinCAT XAE**, or be ready to reload it.
2. Run the script with your solution and the folder holding the framework files:
   ```
   Add-EventFramework.cmd "D:\Projects\Machine\Machine.sln" "D:\Releases\EventFramework"
   ```
   Or double-click `Add-EventFramework.cmd` and enter the path to your solution when asked. The files are then taken from the script's own folder.
3. Open the solution, reload it if XAE asks, and build.

The script:
1. Installs the library on this PC.
2. Adds the event classes to the type system of your project.
3. Adds the `EventFramework` library reference to your PLC project.
4. Adds `GVL_EventTexts` to your PLC project, in the `GVLs` folder.

Before it changes anything, the script prints which files it is using. Running it again is safe: it only adds what is missing and **never overwrites an existing `GVL_EventTexts`**.

To see what the script would do without changing anything, add `-WhatIf`.

### Options

| Option | Use it to |
|---|---|
| `-PlcProject <name>` | Pick the PLC project, when the solution has more than one. |
| `-Version 1.0.0.1` | Use one fixed library version. The default `*` always uses the newest installed version. |
| `-GvlFolder <folder>` | Put `GVL_EventTexts` in another folder, for example `GVLs\Events`. |
| `-SkipGvl` | Leave out `GVL_EventTexts`, for example when you write your own. |
| `-SkipInstall` | Don't install the library, only change the project. |
| `-TmcMode AdditionalFile` | Add the event classes as a separate `.tmc` file under *Type System → Additional TMC files* instead of inside the project. Commit that `.tmc` file: the usual TwinCAT `.gitignore` excludes `*.tmc`. |
| `-LibraryPath`, `-TmcPath`, `-GvlTemplate` | Use one specific file instead of searching the folder. |
| `-WhatIf` | Show the changes without making them. |

Examples:
```
Add-EventFramework.cmd "D:\Projects\Machine" "D:\Releases\EventFramework" -PlcProject MainPlc
Add-EventFramework.cmd "D:\Projects\Machine\Machine.sln" "D:\Releases\EventFramework" -Version 1.0.0.1 -WhatIf
```

From PowerShell, call the script directly:
```
.\Add-EventFramework.ps1 -Project D:\Projects\Machine\Machine.sln -Source D:\Releases\EventFramework
```

### Installing on another PC

Every engineering PC that builds the project needs the library installed. Run the script on that PC too, or install the library by hand in XAE: *PLC → Library Repository → Install…* and select `EventFramework.library`.

---

## 3. Defining events

Every event is one line in `GVL_EventTexts`:

```iecst
{attribute 'qualified_only'}
VAR_GLOBAL CONSTANT
	MachineStarted   : ST_EventDefinition := (nId := 100, eSeverity := TcEventSeverity.Info,     asText := ['Machine {0} started']);
	MotorOverCurrent : ST_EventDefinition := (nId := 200, eSeverity := TcEventSeverity.Error,    asText := ['Motor {0}: over current ({1} A, limit {2} A)']);
	DoorOpen         : ST_EventDefinition := (nId := 300, eSeverity := TcEventSeverity.Critical, bWithConfirmation := TRUE, asText := ['Safety door {0} open']);
END_VAR
```

| Field | Meaning |
|---|---|
| `nId` | A unique number for the event. Keep it stable: it can be used to filter events in the HMI. |
| `eSeverity` | `Verbose`, `Info`, `Warning`, `Error` or `Critical`. |
| `bWithConfirmation` | Alarms only. The operator has to confirm the alarm. Leave it out for no confirmation. |
| `asText` | The text, up to 160 characters. `{0}` to `{9}` are replaced by the arguments. With several languages, one text per language (see [Languages](#7-languages)). |

Tips:
- Group the ids, for example 100–199 machine, 200–299 motors, 300–399 safety.
- The name of the constant is what you use in code, so give it a clear name. A misspelled name doesn't compile.

---

## 4. Alarms

An alarm stays active until it is cleared.

**Declare** it where you need it, with the event from the text list:
```iecst
VAR
	fbOverCurrent : FB_CatalogAlarm(stDefinition := GVL_EventTexts.MotorOverCurrent);
END_VAR
```

**Drive** it every cycle from a condition:
```iecst
fbOverCurrent.Arguments.Clear().AddString('Pump').AddLReal(fCurrent, 2).AddLReal(12, 1);
fbOverCurrent.SetActive(fCurrent > 12);
```

The alarm is raised when the condition becomes TRUE and cleared when it becomes FALSE. The logger shows *Motor Pump: over current (15.00 A, limit 12.0 A)*.

| Member | Description |
|---|---|
| `SetActive(bActive)` | Raises the alarm while `bActive` is TRUE, clears it when `bActive` goes FALSE. Usually all you need. |
| `Raise()` | Raises the alarm. Does nothing if it is already raised. |
| `Clear(bResetConfirmation)` | Clears the alarm. |
| `Confirm()` | Confirms an alarm that has `bWithConfirmation`. |
| `IsRaised` | TRUE while the alarm is raised. |
| `ConfirmationState` | The confirmation state of the alarm. |
| `LastResult` | Result of the last call. Look here when an alarm doesn't appear. |

### Alarms in reusable function blocks

Declare the alarms inside the function block. Every instance then has its own alarms, and they can all be active at the same time:

```iecst
FUNCTION_BLOCK FB_Motor
VAR_INPUT
	sName    : STRING;
	fCurrent : LREAL;
END_VAR
VAR
	fbOverCurrent : FB_CatalogAlarm(stDefinition := GVL_EventTexts.MotorOverCurrent);
END_VAR

fbOverCurrent.Arguments.Clear().AddString(sName).AddLReal(fCurrent, 2).AddLReal(12, 1);
fbOverCurrent.SetActive(fCurrent > 12);
```

The source of each alarm in the logger is the instance path, for example `MAIN.fbPump.fbOverCurrent`. To show a different source name, set `SourceName` before the alarm is raised for the first time.

---

## 5. Messages

A message is a one-time event, such as "machine started".

```iecst
VAR
	fbStarted : FB_CatalogMessage(stDefinition := GVL_EventTexts.MachineStarted);
	rtStart   : R_TRIG;
END_VAR

rtStart(CLK := bStart);
IF rtStart.Q THEN
	fbStarted.Arguments.Clear().AddString('Line 1');
	fbStarted.Send();
END_IF
```

Call `Send()` once per occurrence, for example on a rising edge. Calling it every cycle sends a message every cycle.

---

## 6. Arguments

Arguments fill in `{0}` to `{9}` in the text, in the order they are added:

| Method | Example | Shows |
|---|---|---|
| `AddString(s)` | `AddString('Pump')` | `Pump` |
| `AddDInt(n)` | `AddDInt(1250)` | `1250` |
| `AddLReal(f, decimals)` | `AddLReal(15.237, 2)` | `15.24` |
| `AddBool(b)` | `AddBool(TRUE)` | `TRUE` |

- Always start with `Clear()`, then chain the values: `Arguments.Clear().AddString(sName).AddDInt(nPos)`.
- Up to 10 arguments.
- The arguments are used at the moment an alarm is raised or a message is sent. A raised alarm keeps its text: if the value changes later, the text doesn't. Clear and raise again to show the new value.
- A placeholder without an argument stays visible as `{2}` in the text, so it's easy to spot.

---

## 7. Languages

### Translating texts

Put one text per language in `asText`, in this order: English, German.

```iecst
MotorOverCurrent : ST_EventDefinition := (nId := 200, eSeverity := TcEventSeverity.Error,
	asText := ['Motor {0}: over current ({1} A, limit {2} A)',         // English
	           'Motor {0}: Überstrom ({1} A, Grenze {2} A)']);         // German
```

- A missing translation shows the English text, so you can translate one line at a time.
- A translation can put the placeholders in a different order.

### Switching the language

```iecst
EventFramework.GVL_EventDefaults.fbLanguage.Current := EventFramework.E_Language.German;
```

The `EventFramework.` prefix is optional unless another library uses the same names.

- The whole PLC uses one language.
- The new language is used for events raised after the switch. Alarms that are already active keep their text.

### Needing another language

The available languages are part of the library. Ask for a library version that includes the language you need.

---

## 8. Updating to a new library version

1. Put the new `EventFramework.library` (and `EventFramework.tmc`) in your framework folder.
2. Run the script again on your project. It installs the new version and updates the event classes. Your `GVL_EventTexts` stays as it is.
3. Build.

With the default version `*`, the project uses the newest installed version automatically. If you fixed a version with `-Version`, run the script with the new version number.

---

## 9. Troubleshooting

| Problem | What to do |
|---|---|
| The script says *No .library found* (or .tmc, or GVL) | Check the folder you passed. Or pass the file directly with `-LibraryPath`, `-TmcPath` or `-GvlTemplate`. |
| The script says the solution has several PLC projects | Add `-PlcProject <name>`. |
| The script says *RepTool.exe not found* | TwinCAT XAE isn't installed on this PC. Install it, or use `-SkipInstall` and install the library by hand. |
| The script warns about a duplicate event class | The event classes are in the project twice. Remove the extra copy as the warning says. |
| XAE doesn't show the changes | Close and reopen the solution. |
| *Library EventFramework not found* when building | The library isn't installed on this PC. Run the script, or install it in the library repository. |
| `TC_EVENTS.GenericEvents` unknown when building | The event classes are missing. Run the script again. |
| `TcEventSeverity` unknown when building | Add the `Tc3_EventLogger` library reference to the PLC project. |
| An alarm doesn't appear in the logger | Check `LastResult` of the alarm. |
| The text shows `{2}` | The text has a placeholder without an argument. Add the argument or fix the text. |
| The text doesn't update while the alarm is active | That's intended: the text is fixed when the alarm is raised. |
| The text is in English after switching language | The translation is empty, or the alarm was raised before the switch. |
| `SourceName` has no effect | Set it before the alarm is raised or the message is sent for the first time. |
