# 03 — Platform Capability Matrix

This matrix is a design baseline, not a blanket promise. Probe APIs and permissions at runtime and verify against supported OS versions.

| Data category | Android source | Android destination | iOS source | iOS destination |
|---|---|---|---|---|
| Photos/videos | MediaStore/Photo Picker and granted access | MediaStore/SAF/Photos import flow where supported | Photos framework, user authorization/selection | Photos framework import with user consent |
| Contacts | Contacts Provider permission/export | Contacts Provider import with permission; vCard fallback | Contacts framework with authorization | Contacts framework or vCard/document import flow |
| Documents/files | SAF/user-selected URI, app-owned files | SAF/MediaStore/app storage | Files/document picker, security-scoped URLs | App container/Files export/import; user-selected destinations |
| Audio | MediaStore/SAF permission | MediaStore/SAF | User-selected documents; no unrestricted filesystem | Files/document import |
| Calendar | Calendar Provider permission | Calendar Provider permission | EventKit authorization | EventKit authorization |
| Notes | App-specific export/API only | App-specific import/API only | Official export/API only | Official import/API only |
| Installed apps | Package visibility restrictions | Store links/authorized install flows | No general inventory/install API for third-party apps | App Store links; no silent arbitrary install |
| App private data | Not generally accessible to third-party apps | Not generally writable to other apps | Not accessible across app sandbox | Not writable into another app sandbox |
| Messages/call logs | Restricted/role/policy-specific | Restricted | No general third-party access | No general third-party restore |

## Required behavior
- Show "Supported", "Requires permission", "Official app flow", "Partial" or "Unavailable".
- Ask for permissions contextually, not all at launch.
- Explain what happens when permission is denied.
- Never claim that API presence means every device/OS/OEM behaves identically.
- Maintain tested OS/device matrix with exact build numbers.

## iOS engineering notes
- Use Photos, Contacts, EventKit, UniformTypeIdentifiers, FileImporter/DocumentPicker and Network APIs as appropriate.
- Handle limited Photos library access.
- Handle security-scoped URLs correctly.
- Respect background execution and local-network privacy prompts.
- Import destinations may require explicit user interaction.
- Validate on physical iPhones; simulator is supplementary.

## Android engineering notes
- Use MediaStore, Storage Access Framework, Contacts Provider and Calendar Provider only with appropriate permission.
- Respect scoped storage and Android version-specific permission behavior.
- Do not assume package visibility or broad file access.
- Handle OEM battery/network restrictions.
