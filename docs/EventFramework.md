# Text-List Driven Events for TwinCAT 3

This sample adds a small framework on top of Beckhoff's **Tc3_EventLogger** library. You raise alarms and messages without ever editing the TMC event classes. You define one generic event class once. Every event after that is a line in a PLC text list.

---

## Contents

1. [The problem with the classic approach](#1-the-problem-with-the-classic-approach)
2. [The idea](#2-the-idea)
3. [Benefits](#3-benefits)
4. [Quick start](#4-quick-start)
5. [Working with events](#5-working-with-events)
6. [Languages](#6-languages)
7. [Loading texts from CSV (future extension)](#7-loading-texts-from-csv-future-extension)
8. [Architecture](#8-architecture)
9. [Project structure](#9-project-structure)
10. [Trade-offs and limitations](#10-trade-offs-and-limitations)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. The problem with the classic approach

With plain Tc3_EventLogger, every distinct alarm text is its own event in a TMC event class:

```
Type System → Event Classes → MachineEvents
    MotorOverTemperature   "Motor {0}: over temperature"   Error
    MotorOverCurrent       "Motor {0}: over current"       Error
    DoorOpen               "Safety door {0} open"          Critical
    ... one entry per alarm, forever
```

Adding a single alarm means you:

1. Open the TMC editor in the system project and add the event, its text and its severity.
2. Build, so the PLC gets a new `TC_EVENTS.MachineEvents.X` constant.
3. Declare an `FB_TcAlarm`, call `CreateEx` with the right entry and source info, and manage `Raise` and `Clear`.

This causes several problems:
- **Texts and code live in different places.** The texts are in the system project XML, and the logic is in the PLC.
- **Version-control diffs are hard to review.** Event classes are stored as nested XML inside `.tsproj` and `.tmc` files.
- **You repeat the same setup code** (`CreateEx`, source info, edge handling) for every alarm.
- **Raising the same alarm for several units at once needs care.** The event logger identifies an alarm by its event class, event id and *source info*. If two instances share the same source info, they collide.

---

## 2. The idea

The TMC only describes **severities**. The PLC owns the **texts**.

```
 GVL_EventTexts (PLC)                         TMC: GenericEvents (defined once)
 ┌─────────────────────────────────────┐      ┌──────────────────────────────┐
 │ ConveyorJam:                        │      │ Verbose   "{0}"              │
 │   nId       = 203                   │      │ Info      "{0}"              │
 │   texts     = ['Conveyor {0} ...']  │      │ Warning   "{0}"              │
 │   severity  = Error ────────────────┼─────►│ Error     "{0}"   ◄── used   │
 └─────────────────────────────────────┘      │ Critical  "{0}"              │
                    │                         └──────────────────────────────┘
                    ▼                                        ▲
   FB_CatalogAlarm: picks the text in the current language,  │
   fills in {0}..{9} with the arguments, and passes the      │
   finished text as argument {0} of the generic event ───────┘
```

- The TMC has **one** event class, `GenericEvents`, with one event per severity. Each event's text is just `{0}`.
- Every real event is a **named constant** in `GVL_EventTexts`. It holds an id, a severity, an optional confirmation flag and its texts.
- `FB_CatalogAlarm` and `FB_CatalogMessage` look up the matching generic event by severity, build the text, and handle the event logger for you.
- Each instance owns its own **source info**, so many alarms can be active at once, even when they all map to `GenericEvents.Error`.

---

## 3. Benefits

### Faster to work with
| | Classic | This sample |
|---|---|---|
| Add an alarm | TMC editor, build, `FB_TcAlarm` setup code | One line in `GVL_EventTexts`, one declaration |
| Change a text | TMC editor | Edit a string in the PLC |
| Open the TMC | For every change | Never (after the first setup) |
| Raise or clear an alarm | `CreateEx`, `Raise`, `Clear` and your own edge logic | `fbAlarm.SetActive(bCondition)` |

### Safer
- **Mistakes show up at compile time.** `GVL_EventTexts.ConvyorJam` (misspelled) doesn't compile, and autocomplete lists every event.
- **Source info is unique automatically.** It defaults to the instance path of the alarm, so `MAIN.fbConveyor.fbOverTemperature` and `MAIN.fbPump.fbOverTemperature` never collide.
- **Lazy creation.** `CreateEx` runs on first use, never in `FB_init`, so the order in which things are initialized doesn't matter.
- **Text formatting is bounded.** Placeholders are filled in a single pass with length limits, so long or odd arguments can't overflow the text.

### Easier to maintain
- **All texts are in one readable file.** `GVL_EventTexts` is plain Structured Text, so diffs are clean and easy to review.
- **Translations sit next to the original text**, on the same line.
- **Ready to become a library.** Everything in `EventFramework/` is independent of the application and can be packaged as a `.library`.

### Easy to extend
- New behaviour plugs in through interfaces, for example a CSV text source, another formatter or a different TMC mapping.
- The wiring lives in one place, the composition root `GVL_Events`. Alarm declarations and machine code don't change.

---

## 4. Quick start

**1. Define the event** in `GVLs/GVL_EventTexts`:
```iecst
ConveyorJam : ST_EventDefinition := (nId := 203, eSeverity := TcEventSeverity.Error,
                                     asText := ['Conveyor {0} jammed at {1} mm']);
```

**2. Declare an alarm** where you need it:
```iecst
VAR
    fbJam : FB_CatalogAlarm(ipContext := GVL_Events.fbContext, stDefinition := GVL_EventTexts.ConveyorJam);
END_VAR
```

**3. Drive it** in the cyclic code:
```iecst
fbJam.Arguments.Clear().AddString('Infeed').AddDInt(nPosition);
fbJam.SetActive(bJamDetected);
```

That's all. The event logger shows `Conveyor Infeed jammed at 1250 mm` with severity Error, and the source is the instance path of `fbJam`.

---

## 5. Working with events

### ST_EventDefinition

| Field | Meaning |
|---|---|
| `nId` | Unique, stable number. It is used as the source info id, can be used to filter in the HMI, and is the key for external (CSV) texts. |
| `eSeverity` | `Verbose`, `Info`, `Warning`, `Error` or `Critical`. Selects the generic TMC event. |
| `bWithConfirmation` | Alarms only. The operator has to confirm the alarm. |
| `asText` | One text per language (`E_Language`). `{0}` to `{9}` are replaced by the arguments. Up to 160 characters. |

### Alarms – `FB_CatalogAlarm` (`I_Alarm`)

An alarm is an event that stays active until it is cleared.

| Member | Description |
|---|---|
| `SetActive(bActive)` | Driven by the current state of a condition: raises the alarm while `bActive` is TRUE and clears it when `bActive` goes FALSE. This is usually all you need. |
| `Raise()` | Raises the alarm. Does nothing if it is already raised, which keeps the original text and timestamp. |
| `Clear(bResetConfirmation)` | Clears the alarm. |
| `Confirm()` | Confirms the alarm, for alarms with `bWithConfirmation`. |
| `IsRaised` | Whether the alarm is currently raised. |
| `ConfirmationState` | The event logger's confirmation state. |

### Messages – `FB_CatalogMessage` (`I_Message`)

A message is a one-time event, such as "machine started" or a trace.

```iecst
fbStarted : FB_CatalogMessage(ipContext := GVL_Events.fbContext, stDefinition := GVL_EventTexts.MachineStarted);
...
IF rtStart.Q THEN
    fbStarted.Arguments.Clear().AddString('Line 1').AddString('Operator');
    fbStarted.Send();
END_IF
```

### Shared members (`I_CatalogEvent`)

| Member | Description |
|---|---|
| `Arguments` | Fluent builder: `Clear()`, `AddString`, `AddDInt`, `AddLReal(value, decimals)`, `AddBool`. Up to 10 arguments, `{0}` to `{9}`. |
| `Severity` | The severity from the definition. |
| `LastResult` | HRESULT of the last event logger call. Use it for diagnostics. |
| `SourceName` | Optional override of the source name. The default is the instance path. Only takes effect before the first raise or send. |

### Arguments are taken over when the event is raised

You can refresh arguments every cycle. They are only used at the moment the alarm is raised or the message is sent. A raised alarm keeps the text it was raised with.

```iecst
fbOverTemp.Arguments.Clear().AddString(sName).AddLReal(fTemperature, 1).AddLReal(85, 0);
fbOverTemp.SetActive(fTemperature > 85);
```

### Simultaneous alarms

Each instance has its own `FB_TcSourceInfo`:
- **name** = instance path, for example `MAIN.fbPump.fbOverTemperature`
- **id** = the definition's `nId`

Because of this, any number of instances can be active at the same time, even for the same definition and the same generic TMC event. For reusable components, declare the alarms inside the component FB, as `FB_Motor` does. Each instance of the component then brings its own alarms.

---

## 6. Languages

Each line in the text list holds one text per language, in the order of `E_Language`.

**Adding a language:**

1. Add a value to `E_Language`:
   ```iecst
   ( English := 0, German := 1 ) USINT;
   ```
2. Raise `GVL_EventFramework.cLanguageCount` to `2`.
3. Add the translation to each line:
   ```iecst
   MotorOverTemperature : ST_EventDefinition := (nId := 201, eSeverity := TcEventSeverity.Error,
       asText := ['Motor {0}: over temperature ({1} degC, limit {2} degC)',     // English
                  'Motor {0}: Übertemperatur ({1} °C, Grenze {2} °C)']);        // German
   ```

**Switching language at runtime:**
```iecst
GVL_Events.fbLanguage.Current := E_Language.German;
```

How the language rules work:
- A missing translation falls back to the first language, so you can translate one line at a time.
- `{n}` always refers to the n-th argument, so a translation can reorder the placeholders.
- A language change affects events raised after the change. Alarms that are already active keep their text.
- Characters like `ü`, `ß` and `°` fit in `STRING`. Check how the HMI displays them. Alphabets such as Chinese or Russian would need `WSTRING` throughout the framework.

---

## 7. Loading texts from CSV (future extension)

Texts reach the alarms through the `I_TextProvider` interface. The default, `FB_DefinitionTextProvider`, reads them from the definition. A file-based provider can sit in front of it and fall back to it, which is the *decorator* pattern:

```iecst
FUNCTION_BLOCK FB_CsvTextProvider IMPLEMENTS I_TextProvider
// FB_init(ipFallback : I_TextProvider)
// Body:        read the CSV once (FB_FileOpen / FB_FileGets or Tc2_Utilities.FB_CSVMemBufferReader)
//              into a table of  nId ; language ; text
// GetTemplate: look up (stDefinition.nId, eLanguage) in the table,
//              otherwise RETURN ipFallback.GetTemplate(eLanguage, stDefinition)
```

Example file:
```csv
nId;Language;Text
201;0;Motor {0}: over temperature ({1} degC, limit {2} degC)
201;1;Motor {0}: Übertemperatur ({1} °C, Grenze {2} °C)
203;1;Förderband {0} blockiert bei {1} mm
```

Turning it on changes only the composition root:
```iecst
// GVL_Events
fbCsvTexts : FB_CsvTextProvider(ipFallback := fbDefinitionTexts);
fbContext  : FB_EventContext(ipTexts := fbCsvTexts, ipLanguage := fbLanguage,
                             ipFormatter := fbFormatter, ipEventEntries := fbEventClass);
```
Call `GVL_Events.fbCsvTexts()` every cycle so the file loading can make progress. Until the file has loaded, and for any id the file doesn't contain, the texts compiled into `GVL_EventTexts` are used. The machine keeps working even if the file is missing.

---

## 8. Architecture

### Class diagram

```
                       «interface» I_CatalogEvent
                       Arguments, Severity, LastResult, SourceName
                          ▲                        ▲
            «interface» I_Alarm            «interface» I_Message
            Raise, Clear, Confirm,         Send
            SetActive, IsRaised
                  ▲                                ▲
                  │                                │
          FB_CatalogAlarm ──extends──► FB_CatalogEventBase ◄──extends── FB_CatalogMessage
          (owns FB_TcAlarm)            (abstract)                       (owns FB_TcMessage)
                                       - ST_EventDefinition
                                       - FB_TcSourceInfo
                                       - FB_EventArgs
                                       - EnsureCreated / BuildText
                                       - CreateEvent (overridden)
                                             │ uses
                                             ▼
                                   «interface» I_EventContext
              ┌───────────────┬──────────────┴───────────┬────────────────────┐
              ▼               ▼                          ▼                    ▼
       I_TextProvider  I_LanguageProvider        I_TextFormatter     I_EventEntryProvider
              ▲               ▲                          ▲                    ▲
 FB_DefinitionTextProvider  FB_LanguageSelector  FB_PlaceholderFormatter  FB_GenericEventClass
 (future: FB_CsvTextProvider)                                             (only block that knows the TMC)
```

### What happens when an alarm is raised

1. `SetActive(TRUE)` calls `Raise()`.
2. On first use, `EnsureCreated()`:
   - sets the source info (name = instance path, id = `nId`)
   - asks `I_EventEntryProvider` for the TMC entry matching the severity
   - calls `FB_TcAlarm.CreateEx(entry, bWithConfirmation, sourceInfo)`
3. `BuildText()`:
   - gets the current language from `I_LanguageProvider`
   - gets the text for that language from `I_TextProvider`
   - fills in the arguments with `I_TextFormatter`
4. The finished text is passed as argument `{0}`, then `FB_TcAlarm.Raise(0)` is called.

### How the design follows SOLID

| Principle | Where |
|---|---|
| **S**ingle responsibility | Each block has one job: text provider supplies the text, the language selector holds the language, the formatter formats, the entry provider maps to the TMC, the alarm and message handle the event logger. |
| **O**pen/closed | New events are data. New text sources, formatters or mappings are new blocks, and existing code doesn't change. |
| **L**iskov substitution | Alarms and messages can be used anywhere an `I_CatalogEvent` is expected. Any `I_TextProvider` can replace another. |
| **I**nterface segregation | Arguments have a write side (`I_ArgumentBuilder`) for application code and a read side (`I_ArgumentSource`) for the formatter. |
| **D**ependency inversion | Events depend only on interfaces. `GVL_Events` is the one place that wires concrete blocks together. |

---

## 9. Project structure

```
EventLoggerSample (PLC)
├── EventFramework/                  reusable part, could become a library
│   ├── GVL_EventFramework           constants: max arguments, language count, HRESULTs
│   ├── DUTs/
│   │   ├── E_Language
│   │   └── ST_EventDefinition
│   ├── Interfaces/
│   │   ├── I_Alarm, I_Message, I_CatalogEvent
│   │   ├── I_ArgumentBuilder, I_ArgumentSource
│   │   ├── I_TextProvider, I_LanguageProvider, I_TextFormatter
│   │   └── I_EventEntryProvider, I_EventContext
│   └── POUs/
│       ├── FB_CatalogEventBase      abstract base
│       ├── FB_CatalogAlarm
│       ├── FB_CatalogMessage
│       ├── FB_EventArgs
│       ├── FB_PlaceholderFormatter
│       ├── FB_DefinitionTextProvider
│       ├── FB_LanguageSelector
│       ├── FB_GenericEventClass     maps severity → TC_EVENTS.GenericEvents.*
│       └── FB_EventContext
├── GVLs/
│   ├── GVL_EventTexts               ← the text list: the only place to add events
│   └── GVL_Events                   composition root (wiring)
└── POUs/
    ├── FB_Motor                     example component with three alarms
    └── MAIN                         demo: two motors, a door alarm, messages

System project (.tsproj)
└── Type System → Event Classes → GenericEvents   (Verbose/Info/Warning/Error/Critical, text "{0}")
```

### Trying the demo

Go online and change the variables in `MAIN`:

| Variable | Result |
|---|---|
| `fConveyorTemperature := 75` | Warning: *Motor Conveyor: temperature high (75.0 degC, limit 70 degC)* |
| `fConveyorTemperature := 90` and `fPumpTemperature := 90` | Two Error alarms on the same TMC event, active at the same time |
| `fPumpCurrent := 15` | Error: *Motor Pump: over current (15.00 A, limit 12.0 A)* |
| `bDoorOpen := TRUE`, then `bConfirmDoor` | Critical alarm that needs confirming |
| `bStart` / `bStop` / `bTrace` | Info and Verbose messages |

---

## 10. Trade-offs and limitations

| Topic | Details |
|---|---|
| Language per HMI client | The text is built in the PLC when the event is raised. The whole PLC uses one language, and an active alarm keeps the language it was raised in. TwinCAT's native TMC translation, which works per HMI client, doesn't apply to these events. |
| Filtering in the HMI | All events share the class `GenericEvents`, so filter by severity, source name or source id (`nId`), not by event class or event id. |
| Text length | Up to 160 characters per template and 255 after formatting. Up to 10 arguments (`{0}` to `{9}`). |
| Unique `nId` | Nothing checks that ids are unique. Duplicates still work for alarms, because source names differ, but a CSV override would apply to both. |
| Character set | `STRING`. Non-Latin alphabets need `WSTRING`. |
| Memory | Each instance keeps a copy of its definition, which is roughly 160 bytes per language. This is negligible on an IPC. |

---

## 11. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `TC_EVENTS.GenericEvents` unknown at build | The event class is missing. Check *Type System → Event Classes* and make sure the names are `Verbose`, `Info`, `Warning`, `Error` and `Critical`. |
| Nothing appears in the logger | Check `fbAlarm.LastResult`. `HR_NO_CONTEXT` (`16#80004003`) means `ipContext` wasn't passed in. |
| The text shows a raw `{2}` | The text uses a placeholder with no argument. Add the argument, or fix the text. |
| A text appears in English despite a language switch | The translation is empty, or the alarm was raised before the switch. |
| The alarm text doesn't update while raised | This is intentional. Arguments are taken over when the alarm is raised. Clear and raise again to refresh the text. |
| `SourceName` override has no effect | Set it before the first `Raise`, `SetActive` or `Send`. |
